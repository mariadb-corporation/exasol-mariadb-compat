-- A valid value followed by garbage is not a valid document.
SELECT JSON_EXTRACT('{"a": 1} oops', '$.a')
