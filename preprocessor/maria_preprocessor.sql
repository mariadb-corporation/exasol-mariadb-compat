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
