-- Object vs array on the same key autowraps the object as one element.
SELECT JSON_MERGE_PRESERVE('{"a": {"x":1}}', '{"a": [9]}')
