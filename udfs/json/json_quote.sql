CREATE OR REPLACE LUA SCALAR SCRIPT UTIL.JSON_QUOTE(
    val VARCHAR(2000000)
) RETURNS VARCHAR(2000000) AS

-- MariaDB JSON_QUOTE semantics: wrap the argument as a JSON string literal,
-- escaping interior quotes and control characters.
--   NULL          -> NULL
--   'hello'       -> '"hello"'
--   'a"b'         -> '"a\"b"'           (interior " escaped)
--   'a' + LF +'b' -> '"a\nb"'           (control chars escaped)
--   'null'        -> '"null"'           (no JSON parsing; always a string)
-- Inverse of UTIL.JSON_UNQUOTE for string inputs.
--
-- Exasol quirk: VARCHAR '' is indistinguishable from NULL at the UDF boundary
-- (Exasol treats '' IS NULL as TRUE), so JSON_QUOTE('') returns NULL on Exasol
-- even though MariaDB returns '""'. This is a platform-level limitation, not a
-- UDF bug -- the run() body would otherwise produce '""' on a literal ''.
--
-- The escape table is hand-rolled rather than delegated to cjson.encode:
-- cjson escapes '/' as '\/' (MariaDB leaves it bare) and gives no control over
-- \u letter case. The set below is byte-exact with MariaDB 11.8:
--   " \ BS TAB LF FF CR  -> two-char short forms
--   other 0x00-0x1F      -> \uXXXX with UPPERCASE hex digits
--   0x7F (DEL)           -> passed through raw (MariaDB does not escape it)
--   non-ASCII            -> passed through raw as UTF-8 (no \u escaping)
-- Only ASCII bytes are matched, so UTF-8 continuation bytes (>= 0x80) are
-- never touched and multi-byte characters survive intact.

local SHORT = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

local function escape(c)
    return SHORT[c] or string.format('\\u%04X', string.byte(c))
end

function run(ctx)
    local s = ctx.val
    if s == null then
        return null
    end
    local body = string.gsub(s, '[\0-\31"\\]', escape)
    return '"' .. body .. '"'
end
