-- 21 digits: exceeds a double, so any decode/re-encode would corrupt it.
SELECT JSON_EXTRACT('{"a": 123456789012345678901}', '$.a')
