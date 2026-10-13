-- MariaDB INFORMATION_SCHEMA.COLUMNS over Exasol's SYS.EXA_ALL_COLUMNS.
-- See tables.sql for why this is a view rather than a transpiler rewrite.
--
-- Exasol reports one COLUMN_TYPE string ('VARCHAR(100) UTF8', 'DECIMAL(10,2)'),
-- where MariaDB splits the base name (DATA_TYPE) from the full declaration
-- (COLUMN_TYPE) and the size/precision columns. The base name is the leading
-- run of letters, which also keeps multi-word types intact ('TIMESTAMP WITH
-- LOCAL TIME ZONE', 'DOUBLE PRECISION').
--
-- Exasol has no empty string — '' is NULL — so the columns MariaDB reports as ''
-- (COLUMN_KEY, EXTRA, COLUMN_COMMENT) come back NULL here. A client that tests
-- `EXTRA = ''` rather than checking for a value will not match.
CREATE OR REPLACE VIEW INFORMATION_SCHEMA.COLUMNS AS
SELECT
    'def'                                   AS "TABLE_CATALOG",
    c.COLUMN_SCHEMA                         AS "TABLE_SCHEMA",
    c.COLUMN_TABLE                          AS "TABLE_NAME",
    c.COLUMN_NAME                           AS "COLUMN_NAME",
    c.COLUMN_ORDINAL_POSITION               AS "ORDINAL_POSITION",
    c.COLUMN_DEFAULT                        AS "COLUMN_DEFAULT",
    CASE WHEN c.COLUMN_IS_NULLABLE THEN 'YES' ELSE 'NO' END
                                            AS "IS_NULLABLE",
    LOWER(TRIM(REGEXP_SUBSTR(c.COLUMN_TYPE, '^[A-Za-z][A-Za-z ]*')))
                                            AS "DATA_TYPE",
    CASE WHEN TRIM(REGEXP_SUBSTR(c.COLUMN_TYPE, '^[A-Za-z][A-Za-z ]*')) IN ('VARCHAR', 'CHAR')
         THEN c.COLUMN_MAXSIZE END          AS "CHARACTER_MAXIMUM_LENGTH",
    CASE WHEN TRIM(REGEXP_SUBSTR(c.COLUMN_TYPE, '^[A-Za-z][A-Za-z ]*')) IN ('VARCHAR', 'CHAR')
         THEN CAST(c.COLUMN_MAXSIZE * 4 AS DECIMAL(18, 0)) END
                                            AS "CHARACTER_OCTET_LENGTH",
    CASE WHEN c.COLUMN_NUM_SCALE IS NOT NULL THEN c.COLUMN_NUM_PREC END
                                            AS "NUMERIC_PRECISION",
    c.COLUMN_NUM_SCALE                      AS "NUMERIC_SCALE",
    -- Exasol reports fractional-second precision in COLUMN_NUM_PREC for
    -- TIMESTAMP, where COLUMN_NUM_SCALE is NULL.
    CASE WHEN c.COLUMN_NUM_SCALE IS NULL THEN c.COLUMN_NUM_PREC END
                                            AS "DATETIME_PRECISION",
    CASE WHEN TRIM(REGEXP_SUBSTR(c.COLUMN_TYPE, '^[A-Za-z][A-Za-z ]*')) IN ('VARCHAR', 'CHAR')
         THEN 'utf8mb4' END                 AS "CHARACTER_SET_NAME",
    CASE WHEN TRIM(REGEXP_SUBSTR(c.COLUMN_TYPE, '^[A-Za-z][A-Za-z ]*')) IN ('VARCHAR', 'CHAR')
         THEN 'utf8mb4_general_ci' END      AS "COLLATION_NAME",
    LOWER(REPLACE(c.COLUMN_TYPE, ' UTF8', ''))
                                            AS "COLUMN_TYPE",
    CAST('' AS VARCHAR(3))                  AS "COLUMN_KEY",
    CASE WHEN c.COLUMN_IDENTITY IS NOT NULL THEN 'auto_increment' ELSE '' END
                                            AS "EXTRA",
    'select,insert,update,references'       AS "PRIVILEGES",
    NVL(c.COLUMN_COMMENT, '')               AS "COLUMN_COMMENT",
    'NEVER'                                 AS "IS_GENERATED",
    CAST(NULL AS VARCHAR(2000000))          AS "GENERATION_EXPRESSION"
FROM SYS.EXA_ALL_COLUMNS c
WHERE c.COLUMN_OBJECT_TYPE = 'TABLE'
