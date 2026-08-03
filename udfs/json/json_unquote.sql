CREATE OR REPLACE LUA SCALAR SCRIPT UTIL.JSON_UNQUOTE(
    val VARCHAR(2000000)
) RETURNS VARCHAR(2000000) AS

-- MariaDB JSON_UNQUOTE semantics:
--   NULL                 -> NULL
--   '"hello"'            -> 'hello'             (JSON string -> unescaped text)
--   '"a\\nb"'            -> 'a' + LF + 'b'      (JSON escapes resolved)
--   anything else        -> input unchanged     (numbers, objects, arrays,
--                                                already-unquoted text, garbage)
--
-- MariaDB does NOT run a strict JSON parse here -- it runs a lenient scan of a
-- single leading string token. The rules below were derived by probing MariaDB
-- 11.8 directly, because the differences from a strict parse are not documented
-- and are not reproducible with cjson (which rejects trailing garbage and
-- unknown escapes that MariaDB accepts). Hence the hand-rolled scanner:
--
--   skip leading whitespace         ' "a"'        -> 'a'
--   ignore ALL trailing content     '"a" junk'    -> 'a'   ('""x' -> '')
--   first non-space not '"'         'x"a"'        -> unchanged (no attempt)
--   unknown escape drops backslash  '"a\qb"'      -> 'aqb'
--   \uXXXX, case-insensitive hex    '"café"' -> 'café'
--   surrogate pairs combine         '"😀"' -> the astral character
--
-- The scan FAILS (returning the input unchanged) on any of:
--   no closing quote                '"unterminated', '"a\"'
--   raw control byte < 0x20 inside  '"a' + TAB + 'b"'  (also when escaped:
--                                   backslash + raw TAB fails identically)
--   \u not followed by 4 hex digits '"a\u00zzb"', '"a\u041"'
--   an unpaired surrogate           '"\ud83d"', '"\ude00"'
-- 0x7F (DEL) is NOT a failure -- MariaDB permits it raw inside the quotes.

local SIMPLE = {
    ['"']  = '"',
    ['\\'] = '\\',
    ['/']  = '/',
    ['b']  = '\b',
    ['f']  = '\f',
    ['n']  = '\n',
    ['r']  = '\r',
    ['t']  = '\t',
}

-- Codepoint from the 4 hex digits at s[i..i+3], or nil if they aren't 4 hex.
local function hex4(s, i)
    local h = string.sub(s, i, i + 3)
    if #h < 4 or not string.match(h, '^%x%x%x%x$') then
        return nil
    end
    return tonumber(h, 16)
end

-- Scan the JSON string token that starts at s[i] (known to be '"').
-- Returns the decoded text, or nil if the token is malformed.
local function scan(s, i)
    local out = {}
    i = i + 1
    while true do
        -- Jump straight to the next byte that needs handling and copy the run of
        -- ordinary characters before it in one piece. Iterating per character
        -- instead costs ~5x on strings that contain escapes.
        local j = string.find(s, '["\\\0-\31]', i)
        if not j then
            return nil                                -- ran out before the closing quote
        end
        if j > i then
            out[#out + 1] = string.sub(s, i, j - 1)
        end
        i = j
        local c = string.sub(s, i, i)
        if c == '"' then
            return table.concat(out)                  -- trailing content ignored
        elseif string.byte(c) < 32 then
            return nil                                -- raw control byte
        else                                          -- c == '\\'
            local e = string.sub(s, i + 1, i + 1)
            if e == '' then
                return nil                            -- trailing lone backslash
            elseif e == 'u' then
                local cp = hex4(s, i + 2)
                if not cp then
                    return nil
                end
                i = i + 6
                if cp >= 0xD800 and cp <= 0xDBFF then
                    -- high surrogate: require a following low surrogate
                    if string.sub(s, i, i + 1) ~= '\\u' then
                        return nil
                    end
                    local lo = hex4(s, i + 2)
                    if not lo or lo < 0xDC00 or lo > 0xDFFF then
                        return nil
                    end
                    cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                    i = i + 6
                elseif cp >= 0xDC00 and cp <= 0xDFFF then
                    return nil                        -- unpaired low surrogate
                end
                out[#out + 1] = utf8.char(cp)
            elseif string.byte(e) < 32 then
                return nil                            -- escaping a raw control byte fails too
            else
                out[#out + 1] = SIMPLE[e] or e        -- unknown escape: drop the backslash
                i = i + 2
            end
        end
    end
end

function run(ctx)
    local s = ctx.val
    if s == null then
        return null
    end

    local i = 1
    while i <= #s and string.find(string.sub(s, i, i), '^[ \t\n\r]') do
        i = i + 1
    end
    if string.sub(s, i, i) ~= '"' then
        return s
    end

    -- Fast path: with no backslash anywhere there are no escapes to resolve, so
    -- the token is just the span to the next quote. Avoids the per-character
    -- loop for the overwhelmingly common case of ordinary quoted text.
    if not string.find(s, '\\', i, true) then
        local j = string.find(s, '"', i + 1, true)
        if not j then
            return s
        end
        local body = string.sub(s, i + 1, j - 1)
        if string.find(body, '[\0-\31]') then
            return s
        end
        return body
    end

    local v = scan(s, i)
    if v == nil then
        return s
    end
    return v
end
