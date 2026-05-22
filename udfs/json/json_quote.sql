CREATE OR REPLACE PYTHON3 SCALAR SCRIPT UTIL.JSON_QUOTE(
    val VARCHAR(2000000)
) RETURNS VARCHAR(2000000) AS
import json

# MariaDB JSON_QUOTE semantics: wrap the argument as a JSON string literal,
# escaping interior quotes and control characters.
#   NULL          -> NULL
#   'hello'       -> '"hello"'
#   'a"b'         -> '"a\"b"'           (interior " escaped)
#   'a' + LF +'b' -> '"a\nb"'           (control chars escaped)
#   'null'        -> '"null"'           (no JSON parsing; always a string)
# Inverse of UTIL.JSON_UNQUOTE for string inputs.
#
# Exasol quirk: VARCHAR '' is indistinguishable from NULL at the UDF boundary
# (Exasol treats '' IS NULL as TRUE), so JSON_QUOTE('') returns NULL on Exasol
# even though MariaDB returns '""'. This is a platform-level limitation, not a
# UDF bug — the run() body would otherwise produce '""' on a literal ''.


def run(ctx):
    s = ctx.val
    if s is None:
        return None
    return json.dumps(s)
