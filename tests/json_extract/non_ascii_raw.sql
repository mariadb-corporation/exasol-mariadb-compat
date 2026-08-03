-- Raw UTF-8 passes through; the Python UDF emitted "café" (ensure_ascii).
SELECT JSON_EXTRACT('{"a": "café"}', '$.a')
