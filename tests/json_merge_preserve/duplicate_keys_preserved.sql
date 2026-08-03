-- MariaDB keeps duplicate keys; json.loads collapsed them to the last one, so the
-- Python UDF answered {"a": 2, "b": 3} here.
SELECT JSON_MERGE_PRESERVE('{"a":1,"a":2}', '{"b":3}')
