-- NULL is skipped in mixed mode too; 'x' -> 0 then matches the 0 at position 2.
SELECT FIELD('x', NULL, 0)
