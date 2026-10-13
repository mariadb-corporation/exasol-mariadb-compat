-- MariaDB INFORMATION_SCHEMA.TABLES over Exasol's SYS.EXA_ALL_TABLES.
--
-- Clients query information_schema with arbitrary column lists, predicates and
-- joins, so this is a real view rather than a transpiler rewrite: any shape of
-- SQL works against it, and the MariaDB -> Exasol name mapping lives in one place.
-- The unquoted reference `information_schema.TABLES` reaches this view because
-- Exasol is installed with SQL_IDENTIFIER_COMPARISON = 'IGNORE CASE'.
--
-- Columns are listed in MariaDB's order so that clients selecting * and indexing
-- positionally see what they expect. Exasol has no equivalent for the storage-engine
-- columns; they are constant or NULL.
CREATE OR REPLACE VIEW INFORMATION_SCHEMA.TABLES AS
SELECT
    'def'                                   AS "TABLE_CATALOG",
    t.TABLE_SCHEMA                          AS "TABLE_SCHEMA",
    t.TABLE_NAME                            AS "TABLE_NAME",
    'BASE TABLE'                            AS "TABLE_TYPE",
    'EXASOL'                                AS "ENGINE",
    CAST(10 AS DECIMAL(18, 0))              AS "VERSION",
    CAST(NULL AS VARCHAR(10))               AS "ROW_FORMAT",
    t.TABLE_ROW_COUNT                       AS "TABLE_ROWS",
    CAST(NULL AS DECIMAL(18, 0))            AS "AVG_ROW_LENGTH",
    CAST(NULL AS DECIMAL(18, 0))            AS "DATA_LENGTH",
    CAST(NULL AS DECIMAL(18, 0))            AS "MAX_DATA_LENGTH",
    CAST(NULL AS DECIMAL(18, 0))            AS "INDEX_LENGTH",
    CAST(NULL AS DECIMAL(18, 0))            AS "DATA_FREE",
    CAST(NULL AS DECIMAL(18, 0))            AS "AUTO_INCREMENT",
    CAST(NULL AS TIMESTAMP)                 AS "CREATE_TIME",
    CAST(NULL AS TIMESTAMP)                 AS "UPDATE_TIME",
    CAST(NULL AS TIMESTAMP)                 AS "CHECK_TIME",
    'utf8mb4_general_ci'                    AS "TABLE_COLLATION",
    CAST(NULL AS DECIMAL(18, 0))            AS "CHECKSUM",
    CAST('' AS VARCHAR(255))                AS "CREATE_OPTIONS",
    NVL(t.TABLE_COMMENT, '')                AS "TABLE_COMMENT"
FROM SYS.EXA_ALL_TABLES t
