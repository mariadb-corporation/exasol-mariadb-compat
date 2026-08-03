SELECT JSON_MERGE_PRESERVE('{}', '{"a":1}'), JSON_MERGE_PRESERVE('[]', '[1]'),
       JSON_MERGE_PRESERVE('{"a":[]}', '{"a":[1]}')
