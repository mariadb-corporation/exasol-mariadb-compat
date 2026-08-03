CREATE OR REPLACE LUA SCALAR SCRIPT UTIL.JSON_EXTRACT(
    doc   VARCHAR(2000000),
    paths VARCHAR(2000000)
) RETURNS VARCHAR(2000000) AS

-- MariaDB JSON_EXTRACT semantics:
--   - one path  -> that match as JSON text (strings quoted, numbers bare,
--                  objects/arrays preserved)
--   - multi     -> JSON array of found values, missing paths silently skipped
--   - all miss  -> NULL
-- Path grammar: "$", "$.key", "$[idx]", combinations. Wildcards are not supported
-- and behave as "missing". NB MariaDB does NOT error on them as an earlier version
-- of this comment claimed -- it implements them, so JSON_EXTRACT('{"a":1}', '$.*')
-- is [1] on MariaDB 11.8 and NULL here. Returning NULL keeps that a visible
-- absence rather than a wrong answer; implementing $.* / $[*] / $** is the
-- outstanding gap in this UDF.
--
-- `paths` is always a JSON array of path strings, packed by the preprocessor's
-- JSONExtract branch (json.dumps of the path list) -- even a single path arrives
-- as ["$.a"]. A bare JSON string is also accepted.
--
-- WHY THIS SCANS TEXT INSTEAD OF DECODING: MariaDB re-serializes the matched value with
-- normalized separators (", " and ": ") but keeps every scalar's ORIGINAL text
-- and the document's key ORDER. Verified against MariaDB 11.8:
--     JSON_EXTRACT('{"b":2,"a":1}', '$')            -> {"b": 2, "a": 1}  (not sorted)
--     JSON_EXTRACT('{"a":1e2}', '$.a')              -> 1e2               (not 100.0)
--     JSON_EXTRACT('{"a":123456789012345678901}', '$.a')
--                                                   -> 123456789012345678901
--     JSON_EXTRACT('{"a":"café"}', '$.a')           -> "café"           (raw UTF-8)
-- A decode/re-encode round trip cannot do this in Lua: cjson has no key order,
-- turns every number into a double (so the 21-digit integer above is corrupted
-- and 1e2 becomes 100), and escapes '/' as '\/'. So this scans the source text
-- and re-emits the matched span verbatim except for separator whitespace.
--
-- PERFORMANCE SHAPE (why the code is written the way it is): a JSON parser written
-- in C does its work at C speed, so a naive interpreted Lua scanner LOSES on bulk
-- throughput -- measured 0.5x per row on nested paths in the first draft of this
-- UDF -- while still winning ~9x on per-statement latency, because a LUA script
-- skips the PYTHON3 UDF container startup (+5 ms vs +72 ms). Two structural choices
-- claw the throughput back:
--   1. VALIDATION IS DELEGATED TO C. cjson.decode parses the document purely to
--      confirm it is well-formed and the result is discarded. Validating in
--      interpreted Lua was the single largest cost in the first draft. cjson's
--      acceptance is slightly loose, notably allowing NaN/Infinity.
--   2. NAVIGATION NEVER READS BYTE BY BYTE. Because validation already proved the
--      document well-formed, skipping a value only has to find its extent, not
--      re-verify it: string.find jumps to the next structural character in C, and
--      a skipped object/array is consumed by bracket-depth counting rather than by
--      recursive descent. Single-character reads use string.byte, never
--      string.sub, which allocates a one-character string per read.
-- Key comparison likewise avoids allocating: the candidate key's length is checked
-- against the target first, then string.find(plain) confirms it in place, so no
-- substring is materialized for keys that do not match.
--
-- Known limitations, all confined to loosely-formed inputs or to what the path
-- grammar cannot express:
--   - object keys are matched by their raw text, so a path cannot reach a key
--     written with escapes ({"a": 1} is not found by $.a). The path grammar
--     only admits [A-Za-z_][A-Za-z_0-9]* keys, so such keys are unreachable anyway.
--   - JSON's no-leading-zero rule is not enforced: cjson accepts '01', so such a
--     document extracts here instead of yielding NULL.
--   - cjson's default nesting limit (1000) applies to validation, so a document
--     nested deeper than that yields NULL.

local cjson = require('cjson')
local byte, find, sub, match = string.byte, string.find, string.sub, string.match

local QUOTE, LBRACE, LBRACKET, RBRACE, RBRACKET = 34, 123, 91, 125, 93
local COLON, COMMA, DOLLAR, LOWER_U = 58, 44, 36, 117
local SPACE, TAB, LF, CR = 32, 9, 10, 13

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

-- Value start for `key` inside the object at i, or nil when absent.
local function find_key(s, i, key)
    local keylen = #key
    local j = skip_ws(s, i + 1)
    if byte(s, j) == RBRACE then
        return nil
    end
    while true do
        local kend = scan_string(s, j)
        if not kend then
            return nil
        end
        -- length first, then an in-place compare: no substring is allocated
        local hit = (kend - j - 2 == keylen) and find(s, key, j + 1, true) == j + 1
        local v = skip_ws(s, skip_ws(s, kend) + 1)
        if hit then
            return v
        end
        local e = skip_value(s, v)
        if not e then
            return nil
        end
        j = skip_ws(s, e)
        if byte(s, j) ~= COMMA then
            return nil
        end
        j = skip_ws(s, j + 1)
    end
end

-- Value start for 0-based `want` inside the array at i, or nil when out of range.
local function find_index(s, i, want)
    local j = skip_ws(s, i + 1)
    if byte(s, j) == RBRACKET then
        return nil
    end
    for _ = 1, want do
        local e = skip_value(s, j)
        if not e then
            return nil
        end
        j = skip_ws(s, e)
        if byte(s, j) ~= COMMA then
            return nil
        end
        j = skip_ws(s, j + 1)
    end
    return j
end

-- Re-emit the value at i with MariaDB's separators, every scalar token verbatim.
local function emit(s, i, out)
    local c = byte(s, i)
    if c ~= LBRACE and c ~= LBRACKET then
        local e = skip_value(s, i)
        out[#out + 1] = sub(s, i, e - 1)
        return e
    end
    local is_obj = (c == LBRACE)
    local close = is_obj and RBRACE or RBRACKET
    out[#out + 1] = is_obj and '{' or '['
    local j = skip_ws(s, i + 1)
    if byte(s, j) ~= close then
        local first = true
        while true do
            if first then
                first = false
            else
                out[#out + 1] = ', '
            end
            if is_obj then
                local kend = scan_string(s, j)
                out[#out + 1] = sub(s, j, kend - 1)
                out[#out + 1] = ': '
                j = skip_ws(s, skip_ws(s, kend) + 1)
            end
            j = skip_ws(s, emit(s, j, out))
            if byte(s, j) == close then
                break
            end
            j = skip_ws(s, j + 1)
        end
    end
    out[#out + 1] = is_obj and '}' or ']'
    return j + 1
end

-- Start index of the value `path` selects, or nil when unsupported or missing.
local function locate(s, path)
    if type(path) ~= 'string' or byte(path, 1) ~= DOLLAR then
        return nil
    end
    local rest = sub(path, 2)
    if find(rest, '%*') or find(rest, '?', 1, true) or find(rest, '(', 1, true) then
        return nil
    end
    local at = skip_ws(s, 1)
    local pos = 1
    local len = #rest
    while pos <= len do
        local key, nxt = match(rest, '^%.([%a_][%w_]*)()', pos)
        if key then
            if byte(s, at) ~= LBRACE then
                return nil
            end
            at = find_key(s, at, key)
            pos = nxt
        else
            local idx
            idx, nxt = match(rest, '^%[(%d+)%]()', pos)
            if not idx then
                return nil
            end
            local want = tonumber(idx)
            if byte(s, at) ~= LBRACKET then
                -- MariaDB treats any non-array value as a one-element array, so
                -- $[0] resolves to the value itself and every higher index
                -- misses (verified on 11.8: JSON_EXTRACT('{"a":1}', '$[0]') is
                -- {"a": 1}, '$[1]' is NULL, and '5' with '$[0]' is 5). Staying at
                -- the same position composes correctly, so $[0].a and $[0][0] work.
                if want ~= 0 then
                    return nil
                end
            else
                at = find_index(s, at, want)
            end
            pos = nxt
        end
        if not at then
            return nil
        end
    end
    return at
end

function run(ctx)
    if ctx.doc == null or ctx.paths == null then
        return null
    end
    local doc = ctx.doc
    -- Validate in C and discard the result; everything below assumes well-formed
    -- input, which is what makes the interpreted navigation cheap.
    if not pcall(cjson.decode, doc) then
        return null
    end

    local ok, path_list = pcall(cjson.decode, ctx.paths)
    if not ok then
        return null
    end
    if type(path_list) ~= 'table' then
        path_list = {path_list}
    end

    local found = {}
    for _, p in ipairs(path_list) do
        local at = locate(doc, p)
        if at then
            local out = {}
            emit(doc, at, out)
            found[#found + 1] = table.concat(out)
        end
    end

    if #found == 0 then
        return null
    end
    if #path_list == 1 then
        return found[1]
    end
    return '[' .. table.concat(found, ', ') .. ']'
end
