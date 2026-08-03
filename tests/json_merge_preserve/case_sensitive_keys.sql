-- Keys are matched byte-exactly, so "a" and "A" do not collide.
SELECT JSON_MERGE_PRESERVE('{"a":1}', '{"A":2}')
