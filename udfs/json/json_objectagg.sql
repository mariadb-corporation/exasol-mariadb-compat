CREATE OR REPLACE LUA SCALAR SCRIPT UTIL.JSON_OBJECTAGG(s VARCHAR(2000000))
RETURNS VARCHAR(2000000) AS

-- MariaDB JSON_OBJECTAGG(key, value) aggregates rows into a single JSON object.
-- Exasol implements user-defined aggregates as SET SCRIPTs, but emitting SET
-- SCRIPTs cannot appear inside any expression context (scalar subqueries,
-- argument positions, CTE referenced from an outer expression -- all rejected
-- with "emitting function in expression"). MariaDB JSON_OBJECTAGG routinely
-- appears inside JSON_OBJECT(...) or as a scalar subquery, so a SET SCRIPT
-- wouldn't cover real workloads.
--
-- Workaround: the preprocessor rewrites MariaDB-form JSON_OBJECTAGG(k, v) into
--   UTIL.JSON_OBJECTAGG(LISTAGG(UTIL.JSON_OBJECT(k, v), ','))
-- LISTAGG is a standard SQL aggregate (expression-safe). It concatenates each
-- row's mini JSON object -- produced by UTIL.JSON_OBJECT, which handles type
-- coercion, JSON nesting, and NULL-key errors -- into one comma-joined string.
-- This UDF then wraps that string in [...] to make a JSON array and merges the
-- per-row objects into one.
--
-- Semantics:
--   - Empty group -> LISTAGG returns NULL -> return NULL. Matches MariaDB.
--   - NULL key -> UTIL.JSON_OBJECT raises -> error propagates. Matches MariaDB.
--   - NULL value -> embedded as JSON `null`. Matches MariaDB.
--   - Duplicate keys -> last value wins, at the FIRST key's position. Matches
--     MariaDB's "rows processed in unspecified order, later one wins" behavior.
--   - Aggregation order is whatever LISTAGG produces (no WITHIN GROUP ORDER BY
--     added by the preprocessor, so unspecified); same as MariaDB.
--
-- SEPARATORS follow MariaDB, which is inconsistent between its own JSON functions.
-- Verified on MariaDB 11.8:
--     JSON_OBJECT('a',1,'b','x')  -> {"a": 1, "b": "x"}    colon + space
--     JSON_EXTRACT('{"b":2}','$') -> {"b": 2}              colon + space
--     JSON_OBJECTAGG(k,v)         -> {"a":1, "b":2}        colon, NO space
-- So this UDF emits '":"' with no space, but still ', ' between pairs.
--
-- Values are embedded VERBATIM, which is also what MariaDB does -- it does not
-- re-format a nested document, so a nested object keeps whatever spacing the
-- function that produced it used:
--     JSON_OBJECTAGG(k, JSON_OBJECT('n',1))  -> {"alpha":{"n": 1}}
-- Embedding verbatim additionally preserves each scalar's original spelling, so
-- 1e2 stays 1e2 and integers wider than a double keep their digits, rather than
-- being round-tripped through a float.
--
-- There is NO DATE/TIMESTAMP limitation here: this script is fixed-arity with a
-- single declared VARCHAR parameter, so it never sees a date-typed argument. The
-- restriction that applies to LUA scripts lands on UTIL.JSON_OBJECT instead, one
-- level down in the rewrite -- see the KNOWN LIMITATION block in
-- udfs/json/json_object.sql, and note the CAST it requires must therefore be
-- applied to JSON_OBJECTAGG's own value argument.
--
-- WHY THIS SCANS TEXT INSTEAD OF DECODING (same reasoning as
-- udfs/json/json_extract.sql): cjson has no key order, turns every number into a
-- double, and escapes '/' as '\/', so a decode/re-encode round trip cannot
-- reproduce the input's key order or scalar spelling. Instead cjson.decode
-- validates the document and its result is discarded, then the source text is
-- scanned and each merged value copied out as is.
--
-- Lua/Exasol boundary notes:
--   - SQL NULL is the `null` userdata, not nil -- test `== null`, never `== nil`.
--   - RETURNS VARCHAR, so a Lua string returns directly.
--
-- Known limitations, both from scanning raw text and both shared with
-- udfs/json/json_extract.sql:
--   - keys are compared by their raw source text, so two keys that differ in
--     spelling but denote the same string ("a" and "a") are treated as
--     distinct. UTIL.JSON_OBJECT never emits \u escapes in a key unless the key
--     genuinely contains a control character, so this cannot arise from the
--     preprocessor's own rewrite.
--   - cjson's acceptance allows NaN/Infinity and leading zeros, and it enforces a
--     1000-level nesting limit.

local cjson = require('cjson')
local byte, find, sub, concat = string.byte, string.find, string.sub, table.concat

local QUOTE, LBRACE, LBRACKET, RBRACE, RBRACKET = 34, 123, 91, 125, 93
local SPACE, TAB, LF, CR = 32, 9, 10, 13
local LOWER_U = 117

local function skip_ws(s, i)
    local c = byte(s, i)
    while c == SPACE or c == TAB or c == LF or c == CR do
        i = i + 1
        c = byte(s, i)
    end
    return i
end

-- Index just past the closing quote of the string starting at i. Jumps quote to
-- quote in C; only a backslash forces a per-escape step.
local function scan_string(s, i)
    local j = i + 1
    while true do
        local k = find(s, '["\\]', j)
        if not k then
            return nil
        end
        if byte(s, k) == QUOTE then
            return k + 1
        end
        j = (byte(s, k + 1) == LOWER_U) and k + 6 or k + 2
    end
end

-- Index just past the value starting at i (which must be non-whitespace). Assumes
-- the document already validated, so this only measures extent.
local function skip_value(s, i)
    local c = byte(s, i)
    if c == QUOTE then
        return scan_string(s, i)
    end
    if c == LBRACE or c == LBRACKET then
        local depth = 0
        local j = i
        while true do
            local k = find(s, '[%[%]{}"]', j)
            if not k then
                return nil
            end
            local ch = byte(s, k)
            if ch == QUOTE then
                j = scan_string(s, k)
                if not j then
                    return nil
                end
            else
                if ch == LBRACE or ch == LBRACKET then
                    depth = depth + 1
                else
                    depth = depth - 1
                    if depth == 0 then
                        return k + 1
                    end
                end
                j = k + 1
            end
        end
    end
    -- Scalar: numbers and true/false/null contain no structural character, so the
    -- value ends at the next one (or at end of document for a bare scalar).
    local k = find(s, '[,%]}]', i)
    local e = (k or #s + 1) - 1
    local b = byte(s, e)
    while b == SPACE or b == TAB or b == LF or b == CR do
        e = e - 1
        b = byte(s, e)
    end
    return e + 1
end

-- Merge the object starting at i (byte(s, i) == '{') into the ordered accumulator.
-- Returns the index just past the object's closing brace.
local function merge_object(s, i, keys, vals, pos)
    local j = skip_ws(s, i + 1)
    if byte(s, j) == RBRACE then
        return j + 1
    end
    while true do
        local kend = scan_string(s, j)
        local key = sub(s, j, kend - 1)          -- raw text, quotes included
        j = skip_ws(s, skip_ws(s, kend) + 1)     -- step over the ':'
        local vend = skip_value(s, j)
        local at = pos[key]
        if not at then
            at = #keys + 1
            keys[at] = key
            pos[key] = at
        end
        vals[at] = sub(s, j, vend - 1)
        j = skip_ws(s, vend)
        if byte(s, j) == RBRACE then
            return j + 1
        end
        j = skip_ws(s, j + 1)
    end
end

function run(ctx)
    local s = ctx.s
    if s == null then
        return null
    end

    -- Bracket LISTAGG's comma-joined objects into one JSON array. Validation is
    -- cjson's job and its result is discarded.
    local doc = '[' .. s .. ']'
    if not pcall(cjson.decode, doc) then
        error('JSON_OBJECTAGG could not parse the aggregated JSON objects')
    end

    local keys, vals, pos = {}, {}, {}
    local i = skip_ws(doc, 2)
    if byte(doc, i) ~= RBRACKET then
        while true do
            if byte(doc, i) ~= LBRACE then
                error('JSON_OBJECTAGG expects each aggregated element to be a JSON object')
            end
            i = skip_ws(doc, merge_object(doc, i, keys, vals, pos))
            if byte(doc, i) == RBRACKET then
                break
            end
            i = skip_ws(doc, i + 1)
        end
    end

    local out = {}
    for n = 1, #keys do
        out[n] = keys[n] .. ':' .. vals[n]
    end
    return '{' .. concat(out, ', ') .. '}'
end
