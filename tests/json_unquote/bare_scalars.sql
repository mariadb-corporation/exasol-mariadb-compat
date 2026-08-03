-- Bare JSON scalars are not strings, so they pass through as their original
-- text rather than being decoded to a boolean/null value.
SELECT JSON_UNQUOTE('true'), JSON_UNQUOTE('false'), JSON_UNQUOTE('null')
