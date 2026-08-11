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
import re
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
_PREPROCESSOR_VERSION = "2026.8.0"
_PREPROCESSOR_BUILD = "7449a11-dirty"


def adapter_call(request):
    return _transpile(request)


_SYSVAR_VALUES = {
    "max_allowed_packet": "16777216",
    "auto_increment_increment": "1",
    "system_time_zone": "UTC",
    "time_zone": "+00:00",
    # 2 = names stored as written, compared case-insensitively, which is what
    # Exasol does under SQL_IDENTIFIER_COMPARISON = 'IGNORE CASE'. Reporting 0
    # would tell clients identifiers are case-sensitive, making them quote names
    # in whatever case they guessed.
    "lower_case_table_names": "2",
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


# DbVisualizer (and other MariaDB clients) prepend a per-statement hint
# wrapper: `SET STATEMENT SQL_SELECT_LIMIT=20000 FOR SELECT ...`. sqlglot has
# no parse rule for the form, so parse_one degrades the WHOLE statement to a
# generic exp.Command and it reaches Exasol verbatim — which rejects it with
# "syntax error, unexpected STATEMENT_". Note the exp.Set no-op branch in
# _rewrite_to_util does NOT catch this: that fires on exp.Set, this is Command.
#
# Exasol has no session-hint equivalent, so the variables are dropped outright
# and only <stmt> is transpiled. Notably SQL_SELECT_LIMIT is discarded rather
# than translated into a LIMIT: injecting one would change result semantics for
# statements that already carry a LIMIT/FETCH FIRST, and the client still stops
# reading at its own row cap. The cost is that Exasol computes the full result
# set rather than stopping early.
#
# The scan can't be a plain regex up to /FOR/ because the var list may contain
# string literals ("SET STATEMENT x='a FOR b' FOR SELECT ..."), so track quote
# state ('/"/backtick, with doubled- and backslash-escapes) and paren depth and
# split on the first FOR keyword at depth 0 outside any quote.
#
# It also has to understand comments, in BOTH positions: JDBC tooling routinely
# prepends "/* app */" before the statement (which defeats an anchored ^\s*SET
# match, so the wrapper survives and Exasol rejects it exactly as before the
# fix), and a comment inside the var list would otherwise be scanned as if it
# were SQL — "SET STATEMENT a=1 /* FOR */ FOR ..." split on the commented-out
# FOR and produced the garbage "*/ FOR SELECT 1".
#
# We deliberately do NOT use sqlglot.tokenize() here, even though it handles all
# of this correctly. Measured on the deployed 30.11.0: tokenizing a 20-line
# DbVisualizer query costs ~600us against a ~895us parse+generate budget (+67%
# latency), because it lexes the whole statement. This scanner stops at the
# first FOR, so it is O(var-list prefix) — ~5us on the same query, ~0.3us to
# reject a non-wrapper. Correctness here is worth ten lines, not 120x.
def _sql_string(value):
    return "'" + value.replace("'", "''") + "'"


def _rewrite_show_variables(tree):
    # Exasol has no SHOW VARIABLES, and sqlglot's Exasol generator emits nothing
    # for it, so answer from _SYSVAR_VALUES -- the same table behind SELECT @@var,
    # so the two spellings cannot drift apart. Column names are the ones MariaDB
    # returns and clients look for, hence quoted and mixed case.
    if not isinstance(tree, exp.Show) or tree.name != "VARIABLES":
        return None
    if tree.args.get("where") is not None:
        # SHOW VARIABLES WHERE ... would need its predicate rewritten against
        # these column names -- rare, so fall through to the normal path
        return None

    rows = ", ".join(
        "(" + _sql_string(name) + ", " + _sql_string(value) + ")"
        for name, value in sorted(_SYSVAR_VALUES.items()))
    sql = ('SELECT * FROM (VALUES ' + rows
           + ') AS t("Variable_name", "Value")')

    like = tree.args.get("like")
    if like is not None:
        # MariaDB matches variable names case-insensitively, Exasol LIKE does not
        sql += ' WHERE UPPER("Variable_name") LIKE UPPER(' + _sql_string(like.name) + ')'
    return sql


_CHARSETS = (
    ("ascii", "US ASCII", "ascii_general_ci", 1),
    ("utf8mb4", "UTF-8 Unicode", "utf8mb4_general_ci", 4),
)


def _rewrite_show_charset(tree):
    # Exasol columns are either ASCII or UTF8, so those two are the whole truth
    # here -- reporting MariaDB's full list of 40 charsets would offer clients
    # (and their CREATE TABLE dropdowns) encodings Exasol cannot store. The
    # default collation matches what the information_schema views claim.
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
    # SHOW PROCESSLIST has no Exasol equivalent. Serve it from the
    # INFORMATION_SCHEMA.PROCESSLIST view so both spellings agree, relabelling
    # to the mixed-case names SHOW returns and clients match on. MariaDB
    # truncates Info to 100 chars without FULL -- not reproduced, since Exasol
    # gives us the current activity rather than query text anyway.
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
    # SHOW TABLE STATUS is INFORMATION_SCHEMA.TABLES under different column
    # names, so serve it from that view rather than duplicating the mapping.
    # The schema and LIKE comparisons are case-insensitive to match how Exasol
    # resolves identifiers under SQL_IDENTIFIER_COMPARISON = 'IGNORE CASE'.
    # Every storage-engine number the view reports as NULL stays NULL here --
    # clients display them, they do not compute with them.
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
    # Advance past any run of whitespace and comments, returning the new index.
    # Handles MariaDB's three comment forms: `# ...`, `-- ...` (both to EOL) and
    # `/* ... */`. An unterminated comment swallows the rest of the string.
    # NB: /*! ... */ executable comments are treated as plain comments — they
    # only ever appear in the discarded prefix, and Exasol wouldn't honour a
    # MySQL versioned hint anyway.
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


# MariaDB applies sql_select_limit to the outermost result of a SELECT, and it
# is the ONLY variable in the SET STATEMENT list with an Exasol equivalent, so
# it is the only one translated — the rest are dropped. That is not laziness:
# max_statement_time maps to Exasol QUERY_TIMEOUT but only via a separate
# ALTER SESSION statement, and the preprocessor is strictly one-statement-in /
# one-statement-out; foreign_key_checks and sql_mode have no analogue at all.
#
# Dropping it outright (the original behaviour) is not viable: the router
# fetches the WHOLE result set before anything downstream can stop reading, so
# "SET STATEMENT SQL_SELECT_LIMIT=10 FOR SELECT * FROM orders" became an
# unbounded scan — measured at 272s for 100k rows versus 1ms on MariaDB, on
# every DbVisualizer preview.
#
# Values are recovered from `seen`, which accumulates only the UNQUOTED,
# UNCOMMENTED characters of the variable list, so a string value that happens to
# contain "sql_select_limit=5" cannot be misread as the real setting. The regex
# requires a digit, so `sql_select_limit=DEFAULT` (MariaDB's reset-to-unlimited)
# correctly yields no limit. The last assignment wins, matching MariaDB.
_SQL_SELECT_LIMIT_RE = re.compile(
    r"(?:^|,)\s*(?:@@)?(?:(?:session|local)\.)?sql_select_limit\s*=\s*(\d+)",
    re.IGNORECASE)


def _strip_set_statement(sql):
    # Returns (inner_statement, sql_select_limit_or_None).
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
            seen.append(" ")       # blank out quoted values, see above
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
                # lstrip() only, not _skip_ws_comments: a comment that belongs
                # to the payload ("FOR /*hint*/ SELECT") is the user's, and
                # sqlglot parses it fine — don't silently eat it.
                return sql[i + 3:].lstrip(), _select_limit_of("".join(seen))
        else:
            seen.append(ch)
        delim = False
        i += 1
    # Malformed / no FOR keyword: leave untouched and let it fail naturally
    # rather than silently mangling the statement.
    return sql, None


def _select_limit_of(vars_text):
    m = None
    for m in _SQL_SELECT_LIMIT_RE.finditer(vars_text):
        pass
    return int(m.group(1)) if m else None


# exp.SetOperation is the base of Union/Except/Intersect. MariaDB caps the
# combined result of a set operation, and those parse to SetOperation, NOT
# exp.Select — an isinstance(tree, exp.Select) check alone would skip them and
# let the unbounded scan straight back in. Guarded with getattr for older
# sqlglot builds that only expose exp.Union.
_SET_OPERATION = getattr(exp, "SetOperation", exp.Union)


def _is_zero_literal(node):
    return isinstance(node, exp.Literal) and node.is_int and int(node.this) == 0


def _order_by_offsets(tree):
    # Exasol rejects OFFSET without ORDER BY. MariaDB allows it but guarantees
    # no particular order, so ordering by the first column is a conformant
    # reading -- and it is what a paging client wants, since without a stable
    # order successive pages can repeat or skip rows. Costs a sort, so only do
    # it where Exasol would otherwise refuse the query: an OFFSET of 0 changes
    # nothing, so drop it outright rather than sort for it. MySQL clients paging
    # from the start send `LIMIT 0, n`, which arrives in exactly that shape.
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
    procs = _rewrite_show_processlist(tree)
    if procs is not None:
        return procs
    status = _rewrite_show_table_status(tree)
    if status is not None:
        return status
    tree = tree.transform(_rewrite_to_util)
    # An explicit LIMIT in the statement WINS over sql_select_limit in MariaDB,
    # even when it is larger (verified: sql_select_limit=3 with LIMIT 7 returns
    # 7 rows). So this must never overwrite an existing limit — tree.limit()
    # would silently replace it and return the wrong rows, not merely more of
    # them. SHOW/INSERT/DDL have no .limit() and fall through untouched; MariaDB
    # does cap SHOW, so that stays a known, accepted divergence.
    if (select_limit is not None
            and isinstance(tree, (exp.Select, _SET_OPERATION))
            and not tree.args.get("limit")):
        tree = tree.limit(select_limit)
    tree = _order_by_offsets(tree)
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
