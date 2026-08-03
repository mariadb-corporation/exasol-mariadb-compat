-- No hex parsing: '0x10' -> 0, so it misses 16 and matches the 0.
SELECT FIELD('0x10', 16, 0)
