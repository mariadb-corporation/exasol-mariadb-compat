-- Leading whitespace is skipped before the opening quote is looked for.
-- A non-space, non-quote first character means no attempt is made at all.
SELECT JSON_UNQUOTE('  "a"'), JSON_UNQUOTE('x"a"')
