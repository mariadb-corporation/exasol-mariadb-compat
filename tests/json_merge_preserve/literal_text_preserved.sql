-- MariaDB echoes each scalar's original text. The Python UDF round-tripped every
-- number through a float, so 1e2 came back as 100.0 and 1.50 as 1.5.
SELECT JSON_MERGE_PRESERVE('{"a": 1e2}', '{"b": 2}'),
       JSON_MERGE_PRESERVE('{"a": 1.50}', '{"b": 2}')
