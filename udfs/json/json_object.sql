CREATE OR REPLACE LUA SCALAR SCRIPT UTIL.JSON_OBJECT(...)
RETURNS VARCHAR(2000000) AS

-- MariaDB JSON_OBJECT(key, value[, key, value ...]) semantics:
--   - builds a JSON object from key/value pairs, in argument order.
--   - odd number of arguments -> error (matches MariaDB's syntax requirement).
--   - no arguments            -> '{}'.
--   - NULL key                -> error.
--   - NULL value              -> JSON null.
--   - duplicate keys          -> last value wins, at the FIRST key's position.
--
-- Separators are ', ' and ': ', matching MariaDB 11.8. Note MariaDB is
-- inconsistent between its own JSON functions and uses a bare ':' for
-- JSON_OBJECTAGG; see the separator block in udfs/json/json_objectagg.sql.
--
-- KNOWN LIMITATION (Lua-only): DATE and TIMESTAMP arguments are rejected by Exasol
-- before run() is ever entered -- "Feature not supported: Lua script input type not
-- supported DATE". Verified against Exasol 2025.1.8: this is not specific to the
-- variadic `(...)` signature as the note in udfs/string/field.sql suggests; a
-- fixed-arity LUA script with a declared `d DATE` parameter is rejected
-- identically. A VARCHAR-declared parameter *does* accept a DATE argument by
-- implicit cast, but a variadic script declares no types, so no implicit cast
-- happens. Callers therefore need CAST(d AS VARCHAR(30)) at the call site. Note
-- the implicit cast would not have been transparent either: Exasol renders a
-- TIMESTAMP as '2026-04-24 16:20:00.000000'. Same trade-off ELT and FIELD accepted.
--
-- Scalar rendering (same reasoning as udfs/json/json_extract.sql):
--   - DECIMAL arrives as userdata whose tostring() is its exact decimal text, so
--     it is emitted verbatim and values wider than a double keep their precision.
--     Lua's decimal text drops trailing zeros, so DECIMAL(5,2) 3.10 emits 3.1.
--   - control characters in strings are escaped \uXXXX with UPPERCASE hex, matching
--     MariaDB 11.8 and udfs/json/json_quote.sql.
--   - non-ASCII passes through raw as UTF-8, never \u-escaped.
--
-- Nested JSON: a string value whose first character is '{' or '[' and which parses
-- as JSON is embedded as JSON rather than re-quoted as a string, so a nested
-- UTIL.JSON_OBJECT / JSON_EXTRACT / JSON_MERGE_PRESERVE / JSON_OBJECTAGG composes
-- instead of producing escaped text. Bare literals ('true', 'null', '123') are NOT
-- parsed -- that would change the meaning of user-supplied scalar strings. A caller
-- who genuinely supplies a '{'-leading string of valid JSON will see it treated as
-- JSON, which matches MariaDB's implicit JSON typing.
-- The nested document is embedded VERBATIM, which is what MariaDB does -- it does
-- not re-format a document produced by an inner function, so the inner function's
-- own spacing survives:
--     JSON_OBJECT('x', (SELECT JSON_OBJECTAGG(k,v) FROM d))
--         -> {"x": {"alpha":"2026-01-15", "beta":"2026-02-20"}}
-- Verbatim embedding also preserves each nested scalar's original spelling, so 1e2
-- stays 1e2 and wide integers keep their digits. It is why this UDF needs no JSON
-- scanner: cjson establishes that the candidate is well-formed and the source text
-- is then used as is.
--
-- Lua/Exasol boundary notes:
--   - ctx is 1-BASED, so pairs are (ctx[1], ctx[2]), (ctx[3], ctx[4]), ...
--   - SQL NULL is the `null` userdata, not nil -- test `== null`, never `== nil`.
--   - Arg types map to Lua as: DECIMAL/INT -> userdata (tonumber(v) is nil,
--     tostring(v) gives the decimal text), DOUBLE -> number, VARCHAR/CHAR ->
--     string, BOOLEAN -> boolean.
--   - RETURNS VARCHAR, so a Lua string returns directly; none of the decimal(n)
--     wrapping udfs/string/field.sql needs applies here.
--
-- cjson's acceptance when validating a nested candidate allows NaN/Infinity and
-- leading zeros, and it enforces a 1000-level nesting limit, so a document nested
-- deeper than that is treated as a plain string.

local cjson = require('cjson')
local byte, find, format, gsub, concat =
    string.byte, string.find, string.format, string.gsub, table.concat

local LBRACE, LBRACKET = 123, 91

local SHORT = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

local function escape_char(c)
    return SHORT[c] or format('\\u%04X', byte(c))
end

-- Quote as a JSON string literal. Only ASCII control characters, '"' and '\' are
-- matched, so UTF-8 continuation bytes (>= 0x80) survive intact.
local function quote(s)
    return '"' .. gsub(s, '[\0-\31"\\]', escape_char) .. '"'
end

-- Shortest text that reads back as the same double. Lua's own tostring uses %.14g,
-- which loses round-trip fidelity (1/3 would emit as 0.33333333333333).
local function double_text(v)
    if v ~= v then
        return 'NaN'
    elseif v == math.huge then
        return 'Infinity'
    elseif v == -math.huge then
        return '-Infinity'
    end
    for p = 14, 17 do
        local t = format('%.' .. p .. 'g', v)
        if tonumber(t) == v then
            -- An integral double renders with a trailing '.0'; %g omits it.
            if not find(t, '[%.eE]') then
                t = t .. '.0'
            end
            return t
        end
    end
end

local function value_text(v)
    if v == null then
        return 'null'
    end
    local t = type(v)
    if t == 'boolean' then
        return v and 'true' or 'false'
    elseif t == 'number' then
        return double_text(v)
    elseif t == 'string' then
        local c = byte(v, 1)
        if (c == LBRACE or c == LBRACKET) and pcall(cjson.decode, v) then
            return v
        end
        return quote(v)
    end
    -- DECIMAL and every other numeric userdata: exact decimal text, emitted as is.
    return tostring(v)
end

function run(ctx)
    local n = exa.meta.input_column_count
    if n % 2 ~= 0 then
        error('JSON_OBJECT requires an even number of arguments (key-value pairs)')
    end

    -- Ordered key list plus a position index, so a repeated key overwrites in place
    -- instead of appending.
    local keys, vals, pos = {}, {}, {}
    for i = 1, n, 2 do
        local k = ctx[i]
        if k == null then
            error('JSON_OBJECT key must not be NULL')
        end
        k = (type(k) == 'string') and k or tostring(k)
        local at = pos[k]
        if not at then
            at = #keys + 1
            keys[at] = k
            pos[k] = at
        end
        vals[at] = value_text(ctx[i + 1])
    end

    local out = {}
    for i = 1, #keys do
        out[i] = quote(keys[i]) .. ': ' .. vals[i]
    end
    return '{' .. concat(out, ', ') .. '}'
end
