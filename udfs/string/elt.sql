CREATE OR REPLACE LUA SCALAR SCRIPT UTIL.ELT(...)
RETURNS VARCHAR(2000000) AS

-- MariaDB ELT(N, str1[, str2, ...]) semantics:
--   - 1-based pick: ELT(1, 'a', 'b', 'c') -> 'a', ELT(2, ...) -> 'b'.
--   - N is NULL          -> NULL.
--   - N < 1 or N > count -> NULL.
--   - Selected element itself NULL -> NULL.
--   - Fractional N follows MariaDB's INT-conversion rules, which differ by the
--     argument's declared type (verified against MariaDB 11.8):
--       numeric N (DECIMAL/DOUBLE) rounds half away from zero
--                              -> ELT(2.7, 'a','b','c') = 'c', ELT(2.5, ...) = 'c'
--       string N               truncates toward zero
--                              -> ELT('2.9', 'a','b','c') = 'b', ELT('0.9', ...) = NULL
--   - Non-numeric N (e.g. an arbitrary string) -> NULL conservatively.
-- Requires at least 2 args (one index + one string); fewer raises (matches MariaDB syntax).
--
-- KNOWN LIMITATION (Lua-only): Exasol rejects DATE and TIMESTAMP inputs to a LUA
-- script declared with a variadic `(...)` signature -- "Feature not supported: Lua
-- script input type not supported DATE". A parameter declared with a type gets an
-- implicit cast to it, so a VARCHAR-declared parameter accepts a DATE argument
-- (UTIL.JSON_QUOTE takes a DATE fine), but `(...)` declares no type to cast to.
-- Note that declaring the DATE type itself does not help either: a fixed-arity LUA
-- script with a `d DATE` parameter is rejected identically. So
-- ELT(1, DATE '2020-01-01') raises. Accepted deliberately: ELT picks among string
-- arguments, so date args are a corner case, and the failure is a loud error rather
-- than a wrong answer -- CAST(d AS VARCHAR(...)) at the call site is the
-- workaround. BOOLEAN args are unaffected. UTIL.JSON_OBJECT hit the same wall and
-- accepted the same trade-off; see the KNOWN LIMITATION block there.
--
-- Lua/Exasol boundary notes:
--   - ctx is 1-BASED, so the index is ctx[1] and strn is ctx[n + 1].
--   - DECIMAL args arrive as userdata, not Lua numbers: tonumber(v) yields nil
--     and math.floor(v) raises. tostring(v) gives the decimal text, so the
--     coercion below round-trips through tostring for every non-string type.
--     (DOUBLE args do arrive as Lua numbers; the same path handles them.)
--   - SQL NULL is the `null` userdata, not nil, and tostring(null) is an
--     address string -- so `== null` must be tested before any coercion.

function run(ctx)
    local n_args = exa.meta.input_column_count
    if n_args < 2 then
        error('ELT requires at least 2 arguments (index and one string)')
    end
    local raw = ctx[1]
    if raw == null then
        return null
    end
    -- Lua's own type distinguishes the two rounding rules: only a VARCHAR/CHAR
    -- arg arrives as a Lua string, so `type(raw) == 'string'` is exactly
    -- MariaDB's "string operand" case (truncate); DECIMAL userdata and DOUBLE
    -- numbers both take the round-half-away-from-zero path.
    local n = tonumber(tostring(raw))
    if n == nil then
        return null
    end
    if type(raw) == 'string' then
        n = n >= 0 and math.floor(n) or math.ceil(n)
    else
        n = n >= 0 and math.floor(n + 0.5) or math.ceil(n - 0.5)
    end
    local string_count = n_args - 1
    if n < 1 or n > string_count then
        return null
    end
    local val = ctx[n + 1]
    if val == null then
        return null
    end
    return tostring(val)
end
