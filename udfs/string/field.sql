CREATE OR REPLACE LUA SCALAR SCRIPT UTIL.FIELD(...)
RETURNS INT AS

-- MariaDB FIELD(str, str1[, str2, ...]) semantics:
--   - 1-based search: returns the index of `str` in the list, or 0 if not found.
--   - str is NULL          -> 0 (NULL never equals NULL, so it's never "found").
--   - List element NULL    -> skipped, never matches.
--   - Only `str` provided (no list) -> 0.
-- Comparison mode follows MySQL/MariaDB's documented three-way rule, verified
-- against MariaDB 11.8:
--   - all args are strings  -> compare as strings, NO numeric coercion, so
--                              FIELD('1', '01') = 0.
--   - all args are numbers  -> compare as numbers (BOOLEAN counts as a number:
--                              FIELD(1, TRUE) = 1).
--   - anything mixed        -> compare EVERY arg as a double. A string's value is
--                              its leading numeric prefix and 0 when there is
--                              none, which is why FIELD('x', 0, 'y') = 1 and
--                              FIELD('12abc', 12) = 1.
-- The mixed rule produces matches that look surprising in isolation -- an earlier
-- version of this UDF deliberately refused to implement it and used string
-- comparison throughout -- but it is what MariaDB does, so transpiled queries
-- need it to agree.
--
-- Exasol quirk (platform-level, same as the one noted in udfs/json/json_quote.sql):
-- VARCHAR '' is indistinguishable from NULL at the UDF boundary because Exasol
-- treats '' IS NULL as TRUE. So FIELD('', 0) returns 0 here where MariaDB coerces
-- '' to 0 and answers 1 -- the empty string never reaches run() as a string. Not
-- fixable inside the UDF.
--
-- KNOWN DIVERGENCE: the all-strings path compares case-SENSITIVELY. MariaDB's
-- answer there depends on collation (the default utf8mb4_general_ci makes
-- FIELD('a', 'A') = 1; a _bin or _cs collation makes it 0), and a UDF cannot see
-- the collation of its arguments, so there is no single correct behaviour to copy.
-- Case-sensitive matches Exasol's own default comparison semantics.
--
-- KNOWN LIMITATION (Lua-only): Exasol rejects DATE and TIMESTAMP inputs to a LUA
-- script declared with a variadic `(...)` signature -- "Feature not supported: Lua
-- script input type not supported DATE". See the same block in udfs/string/elt.sql
-- for the full reasoning; CAST(d AS VARCHAR(...)) at the call site is the
-- workaround.
--
-- Lua/Exasol boundary notes:
--   - ctx is 1-BASED, so the needle is ctx[1] and the list is ctx[2..n].
--   - SQL NULL is the `null` userdata, not nil -- test `== null`, never `== nil`.
--   - Arg types map to Lua as: DECIMAL -> userdata (tonumber(v) is nil, but
--     tostring(v) gives the decimal text), DOUBLE -> number, VARCHAR/CHAR ->
--     string, BOOLEAN -> boolean. `type(v) == 'string'` is therefore the mode
--     test: it distinguishes a SQL string arg from every numeric arg.
--   - Lua's decimal text drops trailing zeros (DECIMAL(4,2) 2.00 -> '2'). Harmless
--     here because a decimal only ever meets a string in mixed mode, which compares
--     numerically, never as text.
--   - RETURNS INT must be satisfied with decimal(n), not a plain Lua number:
--     `return 0` fails at runtime with "bad argument (decimal expected, got
--     number)", and a string is rejected the same way. UTIL.ELT needed none of
--     this because it returns VARCHAR, where Lua strings pass straight through.

-- MySQL's string-to-double conversion keeps the longest leading numeric prefix
-- and yields 0 when there is none: '12abc' -> 12, ' 3 ' -> 3, '1e2' -> 100,
-- '.5' -> 0.5, '+2' -> 2, '0x10' -> 0 (no hex parsing), '' -> 0. Lua's tonumber
-- rejects all of the prefixed forms outright, so match the prefix explicitly.
-- Ordered longest-form first: exponent forms before plain digits, so '1e2' does
-- not stop at '1'.
local NUM_PREFIX = {
    '^%s*[-+]?%d+%.?%d*[eE][-+]?%d+',
    '^%s*[-+]?%.%d+[eE][-+]?%d+',
    '^%s*[-+]?%d+%.?%d*',
    '^%s*[-+]?%.%d+',
}

local function str2double(s)
    for _, pat in ipairs(NUM_PREFIX) do
        local m = string.match(s, pat)
        if m then
            local n = tonumber(m)
            if n then
                return n
            end
        end
    end
    return 0
end

local function numval(v)
    if type(v) == 'boolean' then
        return v and 1 or 0
    end
    if type(v) == 'string' then
        return str2double(v)
    end
    return tonumber(tostring(v))
end

function run(ctx)
    local n_args = exa.meta.input_column_count
    if n_args < 1 then
        error('FIELD requires at least 1 argument (the search value)')
    end
    local needle = ctx[1]
    if needle == null then
        return decimal(0)
    end
    if n_args == 1 then
        return decimal(0)
    end

    -- NULLs never match, so they also never influence the mode choice.
    local all_strings = type(needle) == 'string'
    if all_strings then
        for i = 2, n_args do
            local v = ctx[i]
            if v ~= null and type(v) ~= 'string' then
                all_strings = false
                break
            end
        end
    end

    if all_strings then
        for i = 2, n_args do
            local v = ctx[i]
            if v ~= null and v == needle then
                return decimal(i - 1)
            end
        end
        return decimal(0)
    end

    local n = numval(needle)
    for i = 2, n_args do
        local v = ctx[i]
        if v ~= null and numval(v) == n then
            return decimal(i - 1)
        end
    end
    return decimal(0)
end
