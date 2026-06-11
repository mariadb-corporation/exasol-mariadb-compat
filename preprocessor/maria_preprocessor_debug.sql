CREATE OR REPLACE PYTHON3 PREPROCESSOR SCRIPT UTIL.MARIA_PREPROCESSOR_DEBUG AS

# DEBUG variant of UTIL.MARIA_PREPROCESSOR — same rewrite rules, but errors
# raise instead of falling back to the original statement. Use during
# development to surface sqlglot ParseErrors and transform bugs as immediate
# query failures with full tracebacks.
#
# Toggle on with:
#   ALTER SESSION SET sql_preprocessor_script=UTIL.MARIA_PREPROCESSOR_DEBUG
#
# Switch back for production with:
#   ALTER SESSION SET sql_preprocessor_script=UTIL.MARIA_PREPROCESSOR
#
# The rewrite logic below MUST stay byte-identical to the safe variant — only
# adapter_call differs. If you change rules in one, change them in the other.

import json
import sqlglot
from sqlglot import expressions as exp


# Version of the preprocessor REWRITE LOGIC — bump on every behavioural change.
# Independent of the bundled sqlglot version (UTIL.GET_GLOT_VERSION): the
# preprocessor source changes on its own cadence, so it carries its own number.
# build.sh substitutes the "dev" build tag with the git describe string at
# bundle time, and the SLC-installed copy and the MaxScale-mounted copy each
# report their own value, so a version mismatch between two live deployments is
# immediately visible. Read it from any MariaDB client (incl. through MaxScale)
# with `SELECT @@maria_preprocessor_version` — the branch in
# _rewrite_session_var_select below answers it with a canned SELECT.
# NB: production maria_preprocessor.sql keeps these same statements but with NO
# comments — the documentation lives here in the debug variant only.
_PREPROCESSOR_VERSION = "2026.6.0"
_PREPROCESSOR_BUILD = "8b1f4b4"


def adapter_call(request):
    return _transpile(request)


_SYSVAR_VALUES = {
    "max_allowed_packet": "16777216",
    "auto_increment_increment": "1",
    "system_time_zone": "UTC",
    "time_zone": "+00:00",
}


def _rewrite_session_var_select(tree):
    # MariaDB Connector/C++ and /J load session state at connect with
    # `SELECT @@max_allowed_packet, @@system_time_zone, @@time_zone,
    # @@auto_increment_increment` and abort if it fails — but Exasol has no
    # @@-variables. The connector reads the columns by position, so answer with
    # canned constants to let the handshake complete. Returns rewritten SQL, or
    # None if this isn't an all-@@-variable SELECT.
    if not isinstance(tree, exp.Select):
        return None
    projs = tree.expressions
    if not projs or not all(isinstance(e, exp.SessionParameter) for e in projs):
        return None
    # `SELECT @@maria_preprocessor_version` -> the canned version string. Lets
    # any client read which preprocessor build is live, independent of sqlglot.
    if len(projs) == 1 and projs[0].sql(dialect="mysql").lstrip("@").lower() == "maria_preprocessor_version":
        ver = _PREPROCESSOR_VERSION + "_" + _PREPROCESSOR_BUILD
        return "SELECT '" + ver.replace("'", "''") + "'"
    cols = []
    for sp in projs:
        key = sp.sql(dialect="mysql").lstrip("@").lower()
        val = _SYSVAR_VALUES.get(key)
        if val is None:
            cols.append("NULL")
        elif val.isdigit():
            cols.append(val)
        else:
            cols.append("'" + val.replace("'", "''") + "'")
    return "SELECT " + ", ".join(cols)


def _transpile(request):
    tree = sqlglot.parse_one(request, read="mysql")
    if tree is None:
        return request
    sysvars = _rewrite_session_var_select(tree)
    if sysvars is not None:
        return sysvars
    tree = tree.transform(_rewrite_to_util)
    return tree.sql(dialect="exasol", identify=True)


def _rewrite_to_util(node):
    if (isinstance(node, exp.Column)
            and node.table == ""
            and node.name
            and node.name.upper() in _EXASOL_BARE_KEYWORDS):
        # sqlglot parses bare `CURRENT_SESSION` / `CURRENT_STATEMENT` /
        # `CURRENT_SCHEMA` as generic Columns (no typed node like
        # exp.CurrentUser / exp.CurrentDate), so the Exasol generator quotes
        # them as identifiers — `SELECT "CURRENT_SESSION"` — and Exasol then
        # can't resolve the pseudo-column. MaxScale's mariadb_smartrouter
        # emits `SELECT CURRENT_SESSION` as a backend probe, so an unfixed
        # preprocessor breaks every connector through MaxScale + ExasolRouter.
        # exp.Var emits the bare unquoted name.
        return exp.Var(this=node.name)

    if isinstance(node, exp.Set):
        # MariaDB connectors emit connection-init / session-config SETs as part
        # of the handshake: `SET NAMES <charset> [COLLATE <c>]`, `SET CHARACTER
        # SET <c>`, and `SET [SESSION|GLOBAL] <var> = <value>` (autocommit,
        # sql_mode, time_zone, character_set_*, ...). Exasol has no equivalent —
        # its only SQL `SET` is `ALTER SESSION SET`, and a bare `SET <var>` is
        # rejected over the wire with "syntax error, unexpected IDENTIFIER_PART_"
        # (verified: every form of `SET AUTOCOMMIT`, quoted or not, ON/OFF/0,
        # fails). Rewrite the whole statement to a comment-only no-op (Exasol
        # parses comments with result_type=rowCount) so the handshake silently
        # succeeds. `SET TRANSACTION` (kind='TRANSACTION', no assignment) and
        # `SET PASSWORD`/`SET ROLE` (parse as Command) don't match and pass
        # through unchanged.
        items = node.expressions or []
        if items and all(
                isinstance(it, exp.SetItem)
                and (it.args.get("kind") in ("NAMES", "CHARACTER SET")
                     or isinstance(it.this, exp.EQ))
                for it in items):
            return exp.Command(
                this="--",
                expression=exp.Literal.string(
                    " mariadb session SET is a no-op on Exasol"),
            )

    if isinstance(node, exp.CTE):
        # Exasol requires every CTE projection to have a name (alias or column
        # reference) — MariaDB happily accepts bare literals/expressions and
        # synthesizes a display name. For each projection inside the CTE body
        # — including each branch of a UNION/INTERSECT/EXCEPT chain — that has
        # no implicit name, inject AS _col<i>. An explicit outer column list
        # (WITH t(a,b) AS ...) still wins, so this is at worst verbose, never
        # wrong.
        inner = node.this
        if isinstance(inner, exp.Select):
            _alias_unaliased_select(inner)
        elif isinstance(inner, exp.Union):
            for sub in inner.find_all(exp.Select):
                _alias_unaliased_select(sub)
        return node

    if isinstance(node, exp.JSONExtract) and not node.args.get("emits"):
        paths = []
        if node.expression is not None:
            paths.append(_strip_sql_quotes(node.expression.sql()))
        paths.extend(_strip_sql_quotes(p.sql()) for p in node.expressions)
        return exp.Anonymous(
            this="UTIL.JSON_EXTRACT",
            expressions=[node.this, exp.Literal.string(json.dumps(paths))],
        )

    if isinstance(node, exp.JSONObject):
        # Same transform-doesn't-recurse-into-replacements hazard as JSON_UNQUOTE
        # below — recurse explicitly into each key/value so nested
        # JSON_OBJECT(...) (and JSON_EXTRACT, ELT, ...) calls inside the args
        # still get rewritten to their UTIL.* form. Without this, only the
        # outermost JSONObject is rewritten and inner ones leak `key: value`
        # colon syntax that Exasol's parser rejects with "unexpected ':'".
        args = []
        for kv in node.expressions:
            k = kv.this
            v = kv.expression
            if isinstance(k, exp.Expression):
                k = k.transform(_rewrite_to_util)
            if isinstance(v, exp.Expression):
                v = v.transform(_rewrite_to_util)
            args.append(k)
            args.append(v)
        return exp.Anonymous(this="UTIL.JSON_OBJECT", expressions=args)

    if (isinstance(node, exp.Anonymous)
            and isinstance(node.this, str)
            and node.this.upper() == "JSON_OBJECTAGG"):
        # The SLC's older sqlglot may parse JSON_OBJECTAGG as Anonymous; the
        # typed variant is handled by the JSONObjectAgg branch right below.
        # Same recursion rule as JSON_UNQUOTE.
        new_exprs = [e.transform(_rewrite_to_util) if isinstance(e, exp.Expression) else e
                     for e in node.expressions]
        return _wrap_json_objectagg(new_exprs)

    # Newer sqlglot exposes a typed exp.JSONObjectAgg node wrapping a single
    # exp.JSONKeyValue. Guarded with getattr so the preprocessor doesn't crash
    # on an SLC that ships an older sqlglot without this class.
    _JSONObjectAgg = getattr(exp, "JSONObjectAgg", None)
    if _JSONObjectAgg is not None and isinstance(node, _JSONObjectAgg):
        args = []
        for kv in node.expressions:
            k = kv.this
            v = kv.expression
            if isinstance(k, exp.Expression):
                k = k.transform(_rewrite_to_util)
            if isinstance(v, exp.Expression):
                v = v.transform(_rewrite_to_util)
            args.append(k)
            args.append(v)
        return _wrap_json_objectagg(args)

    if (isinstance(node, exp.Anonymous)
            and isinstance(node.this, str)
            and node.this.upper() == "JSON_UNQUOTE"):
        # sqlglot.transform does not recurse into a replaced node's children,
        # so apply _rewrite to inner args here — otherwise JSON_UNQUOTE(JSON_EXTRACT(...))
        # would leave the inner JSON_EXTRACT untransformed and unresolvable on Exasol.
        new_exprs = [e.transform(_rewrite_to_util) if isinstance(e, exp.Expression) else e
                     for e in node.expressions]
        return exp.Anonymous(this="UTIL.JSON_UNQUOTE", expressions=new_exprs)

    if (isinstance(node, exp.Anonymous)
            and isinstance(node.this, str)
            and node.this.upper() == "JSON_QUOTE"):
        # Inverse of JSON_UNQUOTE — wraps a string as a JSON string literal.
        # Same recursion concern: descend into args so e.g.
        # JSON_QUOTE(JSON_UNQUOTE(JSON_EXTRACT(doc,'$.a'))) still rewrites all
        # three layers.
        new_exprs = [e.transform(_rewrite_to_util) if isinstance(e, exp.Expression) else e
                     for e in node.expressions]
        return exp.Anonymous(this="UTIL.JSON_QUOTE", expressions=new_exprs)

    if (isinstance(node, exp.Anonymous)
            and isinstance(node.this, str)
            and node.this.upper() in ("JSON_MERGE_PRESERVE", "JSON_MERGE")):
        # JSON_MERGE is the deprecated MariaDB alias of JSON_MERGE_PRESERVE.
        # Same recursion concern as JSON_UNQUOTE above — descend into args
        # so e.g. JSON_MERGE_PRESERVE(JSON_EXTRACT(doc, '$.a'), ...) still rewrites.
        new_exprs = [e.transform(_rewrite_to_util) if isinstance(e, exp.Expression) else e
                     for e in node.expressions]
        return exp.Anonymous(this="UTIL.JSON_MERGE_PRESERVE", expressions=new_exprs)

    if (isinstance(node, exp.Anonymous)
            and isinstance(node.this, str)
            and node.this.upper() == "ELT"):
        # The SLC's bundled sqlglot (currently 27.6.0) parses ELT as Anonymous —
        # this branch is what fires today. Same recursion rule as JSON_UNQUOTE.
        new_exprs = [e.transform(_rewrite_to_util) if isinstance(e, exp.Expression) else e
                     for e in node.expressions]
        return exp.Anonymous(this="UTIL.ELT", expressions=new_exprs)

    # Newer sqlglot exposes a typed exp.Elt node (this=N, expressions=[strs...]).
    # Guarded with getattr so the preprocessor doesn't crash on the older SLC.
    _Elt = getattr(exp, "Elt", None)
    if _Elt is not None and isinstance(node, _Elt):
        args = [node.this, *node.expressions]
        new_args = [a.transform(_rewrite_to_util) if isinstance(a, exp.Expression) else a
                    for a in args]
        return exp.Anonymous(this="UTIL.ELT", expressions=new_args)

    if (isinstance(node, exp.Anonymous)
            and isinstance(node.this, str)
            and node.this.upper() == "FIELD"):
        # FIELD is the complement of ELT: index of `str` in the trailing list.
        # sqlglot has no typed node for it (in 27.x or 30.x), so Anonymous is
        # the only shape we need to handle. Same recursion rule as JSON_UNQUOTE.
        new_exprs = [e.transform(_rewrite_to_util) if isinstance(e, exp.Expression) else e
                     for e in node.expressions]
        return exp.Anonymous(this="UTIL.FIELD", expressions=new_exprs)

    return node


def _wrap_json_objectagg(args):
    # Build UTIL.JSON_OBJECTAGG(LISTAGG(UTIL.JSON_OBJECT(k, v), ',')).
    # Exasol disallows SET SCRIPTs (emitting UDFs) in any expression context —
    # including scalar subqueries and CTE projections referenced by outer
    # expressions — so a "real" aggregate UDF can't model MariaDB JSON_OBJECTAGG.
    # LISTAGG is a built-in aggregate (expression-safe); pairing it with the
    # scalar UTIL.JSON_OBJECT per-row stringifier and a scalar UTIL.JSON_OBJECTAGG
    # merge keeps the whole rewrite expression-safe.
    if len(args) == 2:
        per_row = exp.Anonymous(this="UTIL.JSON_OBJECT", expressions=list(args))
        listagg = exp.Anonymous(
            this="LISTAGG",
            expressions=[per_row, exp.Literal.string(",")],
        )
        return exp.Anonymous(this="UTIL.JSON_OBJECTAGG", expressions=[listagg])
    return exp.Anonymous(this="UTIL.JSON_OBJECTAGG", expressions=args)


def _strip_sql_quotes(rendered):
    if len(rendered) >= 2 and rendered[0] == "'" and rendered[-1] == "'":
        return rendered[1:-1].replace("''", "'")
    return rendered


_EXASOL_BARE_KEYWORDS = frozenset({
    "CURRENT_SESSION",
    "CURRENT_STATEMENT",
    "CURRENT_SCHEMA",
})


def _alias_unaliased_select(select):
    new_projs = []
    for i, proj in enumerate(select.expressions):
        if isinstance(proj, (exp.Alias, exp.Column, exp.Star)):
            new_projs.append(proj)
        else:
            new_projs.append(exp.alias_(proj, f"_col{i}"))
    select.set("expressions", new_projs)
