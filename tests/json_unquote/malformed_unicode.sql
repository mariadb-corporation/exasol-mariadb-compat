-- Well-formed "..." wrapper but a malformed \u escape inside, so the JSON
-- parse fails and the input passes through unchanged. This is the only case
-- that reaches the parser's error path: inputs that merely start with '"'
-- (e.g. '"unterminated') are short-circuited by the trailing-quote guard and
-- never parsed at all. Without the parse being guarded, this input aborts the
-- whole query instead of returning a row.
SELECT JSON_UNQUOTE('"a\\u00zzb"')
