-- MariaDB echoes the scalar's original text; the Python UDF's JSON round trip
-- turned 1e2 into 100.0. The Lua scanner slices the source instead.
SELECT JSON_EXTRACT('{"a": 1e2}', '$.a'), JSON_EXTRACT('{"a": -1.5E-3}', '$.a')
