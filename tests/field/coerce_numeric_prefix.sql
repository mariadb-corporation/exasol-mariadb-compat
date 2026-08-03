-- MySQL string->double keeps the leading numeric prefix: '12abc' -> 12.
SELECT FIELD('12abc', 12)
