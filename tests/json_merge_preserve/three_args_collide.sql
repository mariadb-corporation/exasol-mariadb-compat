-- Folds left, so a key colliding in all three accumulates one flat array.
SELECT JSON_MERGE_PRESERVE('{"a":1}', '{"a":2}', '{"a":3}')
