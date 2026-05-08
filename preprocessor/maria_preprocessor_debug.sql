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
from sqlglot import exp


def adapter_call(request):
    return _transpile(request)


def _transpile(request):
    tree = sqlglot.parse_one(request, read="mysql")
    if tree is None:
        return request
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
        # MariaDB connectors emit `SET NAMES <charset> [COLLATE <c>]` as a
        # connection-init handshake (client/server text encoding negotiation).
        # Exasol has no equivalent — it stores everything as UTF-8 internally,
        # and rejects standalone `SET <var>` / `SET ENCODING` via the WebSocket
        # protocol with "syntax error, unexpected IDENTIFIER_PART_". Rewrite
        # to a comment-only statement (Exasol parses comments as no-ops with
        # result_type=rowCount), so the handshake silently succeeds.
        items = node.expressions or []
        if (len(items) == 1
                and isinstance(items[0], exp.SetItem)
                and items[0].args.get("kind") == "NAMES"):
            return exp.Command(
                this="--",
                expression=exp.Literal.string(
                    " mariadb SET NAMES is a no-op on Exasol"),
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
        args = []
        for kv in node.expressions:
            args.append(kv.this)
            args.append(kv.expression)
        return exp.Anonymous(this="UTIL.JSON_OBJECT", expressions=args)

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
