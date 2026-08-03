-- MariaDB's merge parses the first value per argument and ignores what follows --
-- unlike its own JSON_EXTRACT/JSON_VALID, which reject the same input. The Python
-- UDF returned NULL for all of these.
SELECT JSON_MERGE_PRESERVE('{"a":1} x', '{"b":2}'),
       JSON_MERGE_PRESERVE('{"a":1} {"c":9}', '{"b":2}'),
       JSON_MERGE_PRESERVE('[1] [2]', '[3]'),
       JSON_MERGE_PRESERVE('1 2', '3')
