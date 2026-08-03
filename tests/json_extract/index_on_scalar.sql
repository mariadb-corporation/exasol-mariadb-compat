-- Same rule applied to a scalar leaf: '$.a[0]' resolves to the string itself.
SELECT JSON_EXTRACT('{"a": "x"}', '$.a[0]')
