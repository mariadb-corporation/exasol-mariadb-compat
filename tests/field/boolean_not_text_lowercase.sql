-- 'true' must NOT match TRUE: MariaDB coerces to double, so 'true' -> 0 vs 1.
-- Comparing Lua's tostring(true) = 'true' as text would wrongly answer 1.
SELECT FIELD('true', TRUE)
