CREATE OR REPLACE LUA SCALAR SCRIPT UTIL.JSON_MERGE_PRESERVE(...)
RETURNS VARCHAR(2000000) AS

-- MariaDB JSON_MERGE_PRESERVE semantics:
--   - Requires >= 2 args.
--   - Any NULL arg -> NULL.
--   - Adjacent objects: union by key; if a key collides, values are combined
--     (recursively merged: two objects -> nested merge; everything else -> autowrap
--     each side to an array and concatenate).
--   - Adjacent arrays: concatenate.
--   - Mixed object/array or scalars: autowrap each side to an array and concatenate.
-- JSON_MERGE is a deprecated MariaDB alias and shares the same semantics; the
-- preprocessor maps both names to this UDF.
-- Invalid JSON in any arg -> NULL (MariaDB raises; we return NULL conservatively
-- rather than aborting the whole statement).
--
-- COMPOSES TEXT, NEVER DECODES (same reasoning as udfs/json/json_extract.sql, and it
-- matters more here). MariaDB normalizes separators to ", " and ": " but keeps every
-- scalar's original text, the document's key order, AND duplicate keys. Verified on
-- MariaDB 11.8:
--     ('{"a": 1e2}', '{"b": 2}')      -> {"a": 1e2, "b": 2}
--     ('{"a": 1.50}', '{"b": 2}')     -> {"a": 1.50, "b": 2}
--     ('{"a":1,"a":2}', '{"b":3}')    -> {"a": 1, "a": 2, "b": 3}
-- A decode/re-encode round trip can express none of these: any JSON parser that
-- returns a map collapses duplicate keys to the last one, and cjson normalizes every
-- number through a double. Slicing the source text preserves all three for free: a
-- value that is not involved in a collision is copied out verbatim, and only
-- genuinely colliding values are rebuilt.
--
-- Performance shape (see the longer note in json_extract.sql): validation is handed
-- to cjson.decode so the C parser does the well-formedness work, and everything
-- after that only measures extents -- string.find jumps between structural
-- characters, skipped containers are consumed by bracket-depth counting, and single
-- characters are read with string.byte rather than allocating via string.sub.
--
-- Multi-arg folds left, and each intermediate result is itself normalized JSON text,
-- so the next merge simply treats it as another document. Intermediates are not
-- re-validated: this UDF produced them.
--
-- KNOWN LIMITATION (Lua-only): Exasol rejects DATE and TIMESTAMP inputs to a LUA
-- script declared with a variadic `(...)` signature. See the same block in
-- udfs/string/elt.sql. Academic here --
-- the arguments are JSON documents -- but it is the same boundary.

local cjson = require('cjson')
local byte, find, sub = string.byte, string.find, string.sub

local QUOTE, LBRACE, LBRACKET, RBRACE, RBRACKET = 34, 123, 91, 125, 93
local COMMA, LOWER_U = 44, 117
local SPACE, TAB, LF, CR = 32, 9, 10, 13

local function skip_ws(s, i)
    local c = byte(s, i)
    while c == SPACE or c == TAB or c == LF or c == CR do
        i = i + 1
        c = byte(s, i)
    end
    return i
end

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

-- Index just past the value starting at i. Assumes validated input, so this only
-- measures extent rather than re-checking the grammar.
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
    local k = find(s, '[,%]}]', i)
    local e = (k or #s + 1) - 1
    local b = byte(s, e)
    while b == SPACE or b == TAB or b == LF or b == CR do
        e = e - 1
        b = byte(s, e)
    end
    return e + 1
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

-- Append the elements of the array at i to an open list, continuing it when
-- `first` is false. Returns the updated `first`.
local function emit_elements(out, s, i, first)
    local j = skip_ws(s, i + 1)
    if byte(s, j) == RBRACKET then
        return first
    end
    while true do
        if first then
            first = false
        else
            out[#out + 1] = ', '
        end
        j = skip_ws(s, emit(s, j, out))
        if byte(s, j) == RBRACKET then
            return first
        end
        j = skip_ws(s, j + 1)
    end
end

-- One side of an autowrap concatenation: an array spreads its elements, anything
-- else contributes itself as a single element.
local function emit_side(out, s, i, first)
    if byte(s, i) == LBRACKET then
        return emit_elements(out, s, i, first)
    end
    if first then
        first = false
    else
        out[#out + 1] = ', '
    end
    emit(s, i, out)
    return first
end

-- Object merges index the right-hand side ONCE into a hash (key -> value start)
-- plus parallel arrays holding its members in document order. The obvious shape --
-- re-scanning the other document to look up each key -- is O(n*m) and re-slices
-- every key twice; on a 7-key merge that alone cost 2x (22.0 -> 11.0 us/row once
-- indexed). The member walks are inlined
-- rather than driven by a callback, so no closure is allocated per merge.
-- First-wins insertion into `bindex` matches MariaDB's handling of a duplicate key
-- within one document: the first occurrence is the one a collision merges against.
-- MariaDB's merge parses the FIRST complete value in each argument and ignores
-- whatever follows, which is NOT how its own JSON_EXTRACT or JSON_VALID behave
-- (both reject trailing content). Verified on 11.8:
--     JSON_MERGE_PRESERVE('{"a":1} x', '{"b":2}')      -> {"a": 1, "b": 2}
--     JSON_MERGE_PRESERVE('{"a":1} {"c":9}', '{"b":2}') -> {"a": 1, "b": 2}
--     JSON_MERGE_PRESERVE('[1] [2]', '[3]')            -> [1, 3]
--     JSON_MERGE_PRESERVE('x {"a":1}', '{"b":2}')      -> NULL  (leading garbage)
--     JSON_MERGE_PRESERVE('{"a":1', '{"b":2}')         -> NULL  (truncated)
-- while JSON_VALID('{"a":1} x') is 0 and JSON_EXTRACT rejects the same input. This
-- runs only after cjson has already refused the whole argument, so the well-formed
-- path pays nothing for it.
local function first_value(s)
    local i = skip_ws(s, 1)
    local c = byte(s, i)
    local e
    if c == LBRACE or c == LBRACKET or c == QUOTE then
        e = skip_value(s, i)
    else
        -- A bare scalar ends at the first delimiter or space: skip_value assumes
        -- well-formed input and would swallow the trailing junk in '1 2'.
        local _, last = find(s, '^[^ \t\n\r,%]}]+', i)
        e = last and last + 1
    end
    if not e then
        return nil
    end
    return sub(s, i, e - 1)
end

local function merge_into(out, sa, ia, sb, ib)
    if byte(sa, ia) ~= LBRACE or byte(sb, ib) ~= LBRACE then
        -- Anything else concatenates as an array: two arrays join, and a non-array
        -- side is autowrapped into one element.
        out[#out + 1] = '['
        local first = emit_side(out, sa, ia, true)
        emit_side(out, sb, ib, first)
        out[#out + 1] = ']'
        return
    end

    local bindex, bkey, bkf, bkt, bvf = {}, {}, {}, {}, {}
    local m = 0
    local j = skip_ws(sb, ib + 1)
    if byte(sb, j) ~= RBRACE then
        while true do
            local kend = scan_string(sb, j)
            if not kend then
                break
            end
            local v = skip_ws(sb, skip_ws(sb, kend) + 1)
            local key = sub(sb, j + 1, kend - 2)
            m = m + 1
            bkey[m], bkf[m], bkt[m], bvf[m] = key, j, kend, v
            if bindex[key] == nil then
                bindex[key] = v
            end
            local e = skip_value(sb, v)
            if not e then
                break
            end
            j = skip_ws(sb, e)
            if byte(sb, j) ~= COMMA then
                break
            end
            j = skip_ws(sb, j + 1)
        end
    end

    out[#out + 1] = '{'
    local first = true
    local seen = {}
    j = skip_ws(sa, ia + 1)
    if byte(sa, j) ~= RBRACE then
        while true do
            local kend = scan_string(sa, j)
            if not kend then
                break
            end
            local v = skip_ws(sa, skip_ws(sa, kend) + 1)
            local key = sub(sa, j + 1, kend - 2)
            seen[key] = true
            if first then
                first = false
            else
                out[#out + 1] = ', '
            end
            out[#out + 1] = sub(sa, j, kend - 1)
            out[#out + 1] = ': '
            local bv = bindex[key]
            local vend
            if bv then
                merge_into(out, sa, v, sb, bv)
                vend = skip_value(sa, v)
            else
                -- emit already measured the value, so don't skip it a second time
                vend = emit(sa, v, out)
            end
            if not vend then
                break
            end
            j = skip_ws(sa, vend)
            if byte(sa, j) ~= COMMA then
                break
            end
            j = skip_ws(sa, j + 1)
        end
    end

    for i = 1, m do
        if not seen[bkey[i]] then
            if first then
                first = false
            else
                out[#out + 1] = ', '
            end
            out[#out + 1] = sub(sb, bkf[i], bkt[i] - 1)
            out[#out + 1] = ': '
            emit(sb, bvf[i], out)
        end
    end
    out[#out + 1] = '}'
end

function run(ctx)
    local n = exa.meta.input_column_count
    if n < 2 then
        error('JSON_MERGE_PRESERVE requires at least 2 arguments')
    end
    local args = {}
    for i = 1, n do
        local s = ctx[i]
        -- A non-string argument is not a JSON document, so it merges to NULL.
        if s == null or type(s) ~= 'string' then
            return null
        end
        if not pcall(cjson.decode, s) then
            -- Retry against just the first value, matching MariaDB's leniency
            -- documented at first_value().
            s = first_value(s)
            if s == nil or not pcall(cjson.decode, s) then
                return null
            end
        end
        args[i] = s
    end

    local acc = args[1]
    for i = 2, n do
        local out = {}
        merge_into(out, acc, skip_ws(acc, 1), args[i], skip_ws(args[i], 1))
        acc = table.concat(out)
    end
    -- A single-document "merge" never happens (n >= 2), so acc is always the
    -- normalized output of at least one merge_into.
    return acc
end
