-- Leading garbage, a truncated value, or a broken prefix still yields NULL rather
-- than aborting the statement. Contrast trailing_content_tolerated.
SELECT JSON_MERGE_PRESERVE('{bad', '{"a":1}'),
       JSON_MERGE_PRESERVE('x {"a":1}', '{"b":2}'),
       JSON_MERGE_PRESERVE('{"a":1,}', '{"b":2}')
