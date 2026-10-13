-- MariaDB INFORMATION_SCHEMA.SCHEMATA over Exasol's SYS.EXA_SCHEMAS.
-- See tables.sql for why this is a view.
--
-- Exasol has no per-schema character set or collation, so those are reported as
-- the utf8mb4 defaults the rest of these views assume.
CREATE OR REPLACE VIEW INFORMATION_SCHEMA.SCHEMATA AS
SELECT
    'def'                                   AS "CATALOG_NAME",
    s.SCHEMA_NAME                           AS "SCHEMA_NAME",
    'utf8mb4'                               AS "DEFAULT_CHARACTER_SET_NAME",
    'utf8mb4_general_ci'                    AS "DEFAULT_COLLATION_NAME",
    CAST(NULL AS VARCHAR(512))              AS "SQL_PATH",
    NVL(s.SCHEMA_COMMENT, '')               AS "SCHEMA_COMMENT"
FROM SYS.EXA_SCHEMAS s
