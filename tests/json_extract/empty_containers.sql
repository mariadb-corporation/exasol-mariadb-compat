SELECT JSON_EXTRACT('{"a": []}', '$.a'), JSON_EXTRACT('{"a": {}}', '$.a')
