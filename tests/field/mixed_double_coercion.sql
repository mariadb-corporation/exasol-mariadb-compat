-- Mixed args compare as double: 'x' has no numeric prefix so it becomes 0 and
-- matches the 0 at position 1. Looks surprising, but it is what MariaDB answers.
SELECT FIELD('x', 0, 'y')
