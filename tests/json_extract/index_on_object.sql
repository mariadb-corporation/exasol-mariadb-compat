-- MariaDB treats a non-array as a one-element array: $[0] is the value itself.
SELECT JSON_EXTRACT('{"a": 1}', '$[0]')
