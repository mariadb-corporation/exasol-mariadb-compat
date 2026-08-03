-- An unrecognised escape drops the backslash and keeps the character, so
-- '"a\qb"' yields 'aqb'. A strict JSON parser would reject this outright.
SELECT JSON_UNQUOTE('"a\\qb"'), JSON_UNQUOTE('"a\\1b"')
