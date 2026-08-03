-- Wildcards are not implemented: MariaDB answers [1] here, this UDF returns NULL
-- so the gap shows up as an absence rather than a wrong value.
SELECT JSON_EXTRACT('{"a": 1}', '$.*')
