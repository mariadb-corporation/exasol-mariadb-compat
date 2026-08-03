SELECT JSON_MERGE_PRESERVE('{"a": [1]}', '{"a": 2}'),
       JSON_MERGE_PRESERVE('{"a": null}', '{"a": 1}')
