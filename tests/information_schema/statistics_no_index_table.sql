-- is_test declares no index. Each engine must report its own truth: STATISTICS
-- has to agree with KEY_COLUMN_USAGE (no FKs here) for the table, whatever that
-- is. MariaDB has none (0 = 0); under --compare-with-cdc the CDC consumer adds a
-- synthetic PRIMARY KEY on Exasol, so both views show it (n = n). Either way: 1.
SELECT CASE WHEN
  (SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = 'MARIADB_COMPAT_TEST' AND TABLE_NAME = 'is_test')
  =
  (SELECT COUNT(*) FROM information_schema.KEY_COLUMN_USAGE
    WHERE TABLE_SCHEMA = 'MARIADB_COMPAT_TEST' AND TABLE_NAME = 'is_test')
THEN 1 ELSE 0 END
