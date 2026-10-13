CREATE OR REPLACE PYTHON3 PREPROCESSOR SCRIPT UTIL.MARIA_PREPROCESSOR AS

import json
import re
import sqlglot
from sqlglot import expressions as exp


_PREPROCESSOR_VERSION = "2026.8.0"
_PREPROCESSOR_BUILD = "773baaa-dirty"


def adapter_call(request):
    try:
        return _transpile(request)
    except Exception:
        return request


_SYSVAR_VALUES = {
    "max_allowed_packet": "16777216",
    "auto_increment_increment": "1",
    "system_time_zone": "UTC",
    "time_zone": "+00:00",
    "lower_case_table_names": "2",
    "sql_mode": "STRICT_TRANS_TABLES",
}

_VERSION_VAR = "maria_preprocessor_version"


def _sysvar_key(sp):
    return sp.name.lstrip("@").lower()


def _sysvar_value(key):
    if key == _VERSION_VAR:
        return _PREPROCESSOR_VERSION + "_" + _PREPROCESSOR_BUILD
    return _SYSVAR_VALUES.get(key)


def _rewrite_session_var_select(tree):
    if not isinstance(tree, exp.Select):
        return None
    projs = tree.expressions
    if not projs or not all(isinstance(e, exp.SessionParameter) for e in projs):
        return None
    cols = []
    for sp in projs:
        val = _sysvar_value(_sysvar_key(sp))
        if val is None:
            lit = "NULL"
        elif val.isdigit():
            lit = val
        else:
            lit = "'" + val.replace("'", "''") + "'"
        alias = sp.sql(dialect="mysql").replace('"', '""')
        cols.append(lit + ' AS "' + alias + '"')
    return "SELECT " + ", ".join(cols)


def _sql_string(value):
    return "'" + value.replace("'", "''") + "'"


def _rewrite_show_variables(tree):
    if not isinstance(tree, exp.Show) or tree.name != "VARIABLES":
        return None
    if tree.args.get("where") is not None:
        return None

    rows = ", ".join(
        "(" + _sql_string(name) + ", " + _sql_string(value) + ")"
        for name, value in sorted(_SYSVAR_VALUES.items()))
    sql = ('SELECT * FROM (VALUES ' + rows
           + ') AS t("Variable_name", "Value")')

    like = tree.args.get("like")
    if like is not None:
        sql += ' WHERE UPPER("Variable_name") LIKE UPPER(' + _sql_string(like.name) + ')'
    return sql


_CHARSETS = (
    ("ascii", "US ASCII", "ascii_general_ci", 1),
    ("utf8mb4", "UTF-8 Unicode", "utf8mb4_general_ci", 4),
)


def _rewrite_show_charset(tree):
    if not isinstance(tree, exp.Show) or tree.name != "CHARACTER SET":
        return None
    if tree.args.get("where") is not None:
        return None

    rows = ", ".join(
        "(" + _sql_string(name) + ", " + _sql_string(desc) + ", "
        + _sql_string(collation) + ", " + str(maxlen) + ")"
        for name, desc, collation, maxlen in _CHARSETS)
    sql = ('SELECT * FROM (VALUES ' + rows
           + ') AS t("Charset", "Description", "Default collation", "Maxlen")')

    like = tree.args.get("like")
    if like is not None:
        sql += ' WHERE UPPER("Charset") LIKE UPPER(' + _sql_string(like.name) + ')'
    return sql


def _rewrite_show_create_table(tree):
    if not isinstance(tree, exp.Show) or tree.name != "CREATE TABLE":
        return None
    target = tree.args.get("target")
    if target is None:
        return None
    db = tree.args.get("db")
    schema = (' AND UPPER("TABLE_SCHEMA") = ' + _sql_string(db.name.upper())
              if db is not None
              else ' AND UPPER("TABLE_SCHEMA") = UPPER(CURRENT_SCHEMA)')
    return ('SELECT "TABLE_NAME" AS "Table", "DDL" AS "Create Table"'
            + ' FROM "UTIL"."SHOW_CREATE_TABLE"'
            + ' WHERE UPPER("TABLE_NAME") = ' + _sql_string(target.name.upper())
            + schema)


def _rewrite_show_engines(tree):
    if not isinstance(tree, exp.Show) or tree.name != "ENGINES":
        return None
    return ("SELECT * FROM (VALUES ("
            + _sql_string("EXASOL") + ", " + _sql_string("DEFAULT") + ", "
            + _sql_string("Exasol analytic database") + ", "
            + _sql_string("YES") + ", " + _sql_string("NO") + ", "
            + _sql_string("NO") + ")) AS t("
            + '"Engine", "Support", "Comment", "Transactions", "XA", "Savepoints")')


def _rewrite_show_plugins(tree):
    if not isinstance(tree, exp.Show) or tree.name != "PLUGINS":
        return None
    return ("SELECT * FROM (VALUES ("
            + _sql_string("EXASOL") + ", " + _sql_string("ACTIVE") + ", "
            + _sql_string("STORAGE ENGINE") + ", CAST(NULL AS VARCHAR(64)), "
            + _sql_string("PROPRIETARY") + ")) AS t("
            + '"Name", "Status", "Type", "Library", "License")')


_COLLATIONS = (
    ("ascii_general_ci", "ascii", 11, "Yes"),
    ("utf8mb4_general_ci", "utf8mb4", 45, "Yes"),
)


def _rewrite_show_collation(tree):
    if not isinstance(tree, exp.Show) or tree.name != "COLLATION":
        return None
    if tree.args.get("where") is not None:
        return None

    rows = ", ".join(
        "(" + _sql_string(name) + ", " + _sql_string(charset) + ", "
        + str(ident) + ", " + _sql_string(default) + ", 'Yes', 1)"
        for name, charset, ident, default in _COLLATIONS)
    sql = ('SELECT * FROM (VALUES ' + rows
           + ') AS t("Collation", "Charset", "Id", "Default", "Compiled", "Sortlen")')

    like = tree.args.get("like")
    if like is not None:
        sql += ' WHERE UPPER("Collation") LIKE UPPER(' + _sql_string(like.name) + ')'
    return sql


_PROCESSLIST_COLUMNS = (
    ("ID", "Id"),
    ("USER", "User"),
    ("HOST", "Host"),
    ("DB", "db"),
    ("COMMAND", "Command"),
    ("TIME", "Time"),
    ("STATE", "State"),
    ("INFO", "Info"),
    ("PROGRESS", "Progress"),
)


def _rewrite_show_processlist(tree):
    if not isinstance(tree, exp.Show) or tree.name != "PROCESSLIST":
        return None
    cols = ", ".join('"' + src + '" AS "' + label + '"'
                     for src, label in _PROCESSLIST_COLUMNS)
    return ("SELECT " + cols
            + ' FROM "INFORMATION_SCHEMA"."PROCESSLIST"')



_TABLE_STATUS_COLUMNS = (
    ("TABLE_NAME", "Name"),
    ("ENGINE", "Engine"),
    ("VERSION", "Version"),
    ("ROW_FORMAT", "Row_format"),
    ("TABLE_ROWS", "Rows"),
    ("AVG_ROW_LENGTH", "Avg_row_length"),
    ("DATA_LENGTH", "Data_length"),
    ("MAX_DATA_LENGTH", "Max_data_length"),
    ("INDEX_LENGTH", "Index_length"),
    ("DATA_FREE", "Data_free"),
    ("AUTO_INCREMENT", "Auto_increment"),
    ("CREATE_TIME", "Create_time"),
    ("UPDATE_TIME", "Update_time"),
    ("CHECK_TIME", "Check_time"),
    ("TABLE_COLLATION", "Collation"),
    ("CHECKSUM", "Checksum"),
    ("CREATE_OPTIONS", "Create_options"),
    ("TABLE_COMMENT", "Comment"),
)


def _rewrite_show_table_status(tree):
    if not isinstance(tree, exp.Show) or tree.name != "TABLE STATUS":
        return None
    if tree.args.get("where") is not None:
        return None

    cols = ", ".join('"' + src + '" AS "' + label + '"'
                     for src, label in _TABLE_STATUS_COLUMNS)
    db = tree.args.get("db")
    schema = (_sql_string(db.name.upper()) if db is not None
              else 'UPPER(CURRENT_SCHEMA)')
    sql = ("SELECT " + cols
           + ' FROM "INFORMATION_SCHEMA"."TABLES"'
           + ' WHERE UPPER("TABLE_SCHEMA") = ' + schema)

    like = tree.args.get("like")
    if like is not None:
        sql += ' AND UPPER("TABLE_NAME") LIKE UPPER(' + _sql_string(like.name) + ')'
    return sql


_SET_STATEMENT_RE = re.compile(r"\s*SET\s+STATEMENT\s+", re.IGNORECASE)


def _skip_ws_comments(sql, i):
    n = len(sql)
    while i < n:
        ch = sql[i]
        if ch.isspace():
            i += 1
        elif ch == "#" or sql.startswith("--", i):
            j = sql.find("\n", i)
            i = n if j < 0 else j + 1
        elif sql.startswith("/*", i):
            j = sql.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            break
    return i


_SQL_SELECT_LIMIT_RE = re.compile(
    r"(?:^|,)\s*(?:@@)?(?:(?:session|local)\.)?sql_select_limit\s*=\s*(\d+)",
    re.IGNORECASE)


def _strip_set_statement(sql):
    m = _SET_STATEMENT_RE.match(sql, _skip_ws_comments(sql, 0))
    if not m:
        return sql, None
    i = m.end()
    n = len(sql)
    depth = 0
    quote = ""
    delim = True
    seen = []
    while i < n:
        ch = sql[i]
        if quote:
            if ch == "\\" and quote != "`":
                i += 1
            elif ch == quote:
                if i + 1 < n and sql[i + 1] == quote:
                    i += 1          # doubled quote -> escaped, stay in string
                else:
                    quote = ""
            i += 1
            continue
        j = _skip_ws_comments(sql, i)
        if j > i:
            i = j
            delim = True
            seen.append(" ")
            continue
        if ch in ("'", '"', "`"):
            quote = ch
            seen.append(" ")
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch in ",=":
            delim = True
            seen.append(ch)
            i += 1
            continue
        elif depth == 0 and delim and sql[i:i + 3].upper() == "FOR":
            after = sql[i + 3:i + 4]
            if not (after.isalnum() or after == "_"):
                return sql[i + 3:].lstrip(), _select_limit_of("".join(seen))
        else:
            seen.append(ch)
        delim = False
        i += 1
    return sql, None


def _select_limit_of(vars_text):
    m = None
    for m in _SQL_SELECT_LIMIT_RE.finditer(vars_text):
        pass
    return int(m.group(1)) if m else None


_SET_OPERATION = getattr(exp, "SetOperation", exp.Union)


def _is_zero_literal(node):
    return isinstance(node, exp.Literal) and node.is_int and int(node.this) == 0


def _order_by_offsets(tree):
    for node in tree.find_all(exp.Select, _SET_OPERATION):
        offset = node.args.get("offset")
        if offset is None or node.args.get("order") is not None:
            continue
        if _is_zero_literal(offset.expression):
            node.set("offset", None)
            continue
        node.set("order", exp.Order(expressions=[
            exp.Ordered(this=exp.Literal.number(1))]))
    return tree


def _transpile(request):
    request, select_limit = _strip_set_statement(request)
    tree = sqlglot.parse_one(request, read="mysql")
    if tree is None:
        return request
    sysvars = _rewrite_session_var_select(tree)
    if sysvars is not None:
        return sysvars
    showvars = _rewrite_show_variables(tree)
    if showvars is not None:
        return showvars
    charset = _rewrite_show_charset(tree)
    if charset is not None:
        return charset
    collation = _rewrite_show_collation(tree)
    if collation is not None:
        return collation
    create_table = _rewrite_show_create_table(tree)
    if create_table is not None:
        return create_table
    engines = _rewrite_show_engines(tree)
    if engines is not None:
        return engines
    plugins = _rewrite_show_plugins(tree)
    if plugins is not None:
        return plugins
    procs = _rewrite_show_processlist(tree)
    if procs is not None:
        return procs
    status = _rewrite_show_table_status(tree)
    if status is not None:
        return status
    tree = tree.transform(_rewrite_to_util)
    if (select_limit is not None
            and isinstance(tree, (exp.Select, _SET_OPERATION))
            and not tree.args.get("limit")):
        tree = tree.limit(select_limit)
    tree = _order_by_offsets(tree)
    return tree.sql(dialect="exasol", identify=True)


def _rewrite_to_util(node):
    if isinstance(node, exp.SessionParameter):
        val = _sysvar_value(_sysvar_key(node))
        if val is None:
            return exp.Null()
        if val.isdigit():
            return exp.Literal.number(val)
        return exp.Literal.string(val)

    if (isinstance(node, exp.Column)
            and node.table == ""
            and node.name
            and node.name.upper() in _EXASOL_BARE_KEYWORDS):
        return exp.Var(this=node.name)

    if isinstance(node, exp.Set):
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
