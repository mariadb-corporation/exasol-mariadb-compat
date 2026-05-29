CREATE OR REPLACE PYTHON3 PREPROCESSOR SCRIPT UTIL.MARIA_PREPROCESSOR AS

import json
import sqlglot
from sqlglot import expressions as exp


def adapter_call(request):
    try:
        return _transpile(request)
    except Exception:
        return request


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
        return exp.Var(this=node.name)

    if isinstance(node, exp.Set):
        # MariaDB connection-handshake / session-config SETs (SET NAMES,
        # SET CHARACTER SET, SET [SESSION|GLOBAL] <var> = <value> such as
        # autocommit / sql_mode / time_zone) have no Exasol equivalent and are
        # rejected over the wire; rewrite to a comment no-op (Exasol parses
        # comments with result_type=rowCount). SET TRANSACTION / SET PASSWORD
        # don't match (no assignment / parse as Command) and pass through.
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
        new_exprs = [e.transform(_rewrite_to_util) if isinstance(e, exp.Expression) else e
                     for e in node.expressions]
        return _wrap_json_objectagg(new_exprs)

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
        new_exprs = [e.transform(_rewrite_to_util) if isinstance(e, exp.Expression) else e
                     for e in node.expressions]
        return exp.Anonymous(this="UTIL.JSON_UNQUOTE", expressions=new_exprs)

    if (isinstance(node, exp.Anonymous)
            and isinstance(node.this, str)
            and node.this.upper() == "JSON_QUOTE"):
        new_exprs = [e.transform(_rewrite_to_util) if isinstance(e, exp.Expression) else e
                     for e in node.expressions]
        return exp.Anonymous(this="UTIL.JSON_QUOTE", expressions=new_exprs)

    if (isinstance(node, exp.Anonymous)
            and isinstance(node.this, str)
            and node.this.upper() in ("JSON_MERGE_PRESERVE", "JSON_MERGE")):
        new_exprs = [e.transform(_rewrite_to_util) if isinstance(e, exp.Expression) else e
                     for e in node.expressions]
        return exp.Anonymous(this="UTIL.JSON_MERGE_PRESERVE", expressions=new_exprs)

    if (isinstance(node, exp.Anonymous)
            and isinstance(node.this, str)
            and node.this.upper() == "ELT"):
        new_exprs = [e.transform(_rewrite_to_util) if isinstance(e, exp.Expression) else e
                     for e in node.expressions]
        return exp.Anonymous(this="UTIL.ELT", expressions=new_exprs)

    _Elt = getattr(exp, "Elt", None)
    if _Elt is not None and isinstance(node, _Elt):
        args = [node.this, *node.expressions]
        new_args = [a.transform(_rewrite_to_util) if isinstance(a, exp.Expression) else a
                    for a in args]
        return exp.Anonymous(this="UTIL.ELT", expressions=new_args)

    if (isinstance(node, exp.Anonymous)
            and isinstance(node.this, str)
            and node.this.upper() == "FIELD"):
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
