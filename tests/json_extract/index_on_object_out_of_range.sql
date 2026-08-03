-- ...but any index above 0 misses on a non-array.
SELECT JSON_EXTRACT('{"a": 1}', '$[1]')
