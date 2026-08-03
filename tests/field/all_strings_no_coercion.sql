-- All args are strings, so no numeric coercion happens and '1' != '01'.
SELECT FIELD('1', '01')
