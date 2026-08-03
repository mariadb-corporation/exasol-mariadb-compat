-- 21 digits: exceeds a double, so it must never pass through a numeric decode.
SELECT JSON_MERGE_PRESERVE('{"a": 123456789012345678901}', '{"b": 2}')
