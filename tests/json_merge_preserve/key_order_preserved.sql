-- Left document's order first, then right document's new keys; colliding keys stay
-- in their left-hand position.
SELECT JSON_MERGE_PRESERVE('{"b": 1}', '{"a": 2}'),
       JSON_MERGE_PRESERVE('{"a":1,"b":2}', '{"b":3,"a":4}')
