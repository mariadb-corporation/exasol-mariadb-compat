-- MariaDB coerces both sides to double: '1' -> 1 matches TRUE -> 1.
-- The Python UDF answered 0 here (it compared str(True) = 'True' as text).
SELECT FIELD('1', TRUE)
