-- A raw control byte inside the quotes makes the scan fail, so the input
-- passes through. DEL (0x7F) is not a control byte for this purpose and is
-- accepted, matching MariaDB.
SELECT JSON_UNQUOTE(CONCAT('"a', CHAR(9), 'b"')), JSON_UNQUOTE(CONCAT('"a', CHAR(127), 'b"'))
