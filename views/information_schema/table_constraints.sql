-- MariaDB INFORMATION_SCHEMA.TABLE_CONSTRAINTS over Exasol's
-- SYS.EXA_ALL_CONSTRAINTS. See tables.sql for why this is a view.
--
-- Primary keys are renamed to 'PRIMARY' and NOT NULL constraints are excluded,
-- matching KEY_COLUMN_USAGE — the two are routinely joined on CONSTRAINT_NAME,
-- so they must agree on both.
CREATE OR REPLACE VIEW INFORMATION_SCHEMA.TABLE_CONSTRAINTS AS
SELECT
    'def'                                   AS "CONSTRAINT_CATALOG",
    ct.CONSTRAINT_SCHEMA                    AS "CONSTRAINT_SCHEMA",
    CASE WHEN ct.CONSTRAINT_TYPE = 'PRIMARY KEY' THEN 'PRIMARY'
         ELSE ct.CONSTRAINT_NAME END        AS "CONSTRAINT_NAME",
    ct.CONSTRAINT_SCHEMA                    AS "TABLE_SCHEMA",
    ct.CONSTRAINT_TABLE                     AS "TABLE_NAME",
    ct.CONSTRAINT_TYPE                      AS "CONSTRAINT_TYPE"
FROM SYS.EXA_ALL_CONSTRAINTS ct
WHERE ct.CONSTRAINT_TYPE IN ('PRIMARY KEY', 'UNIQUE', 'FOREIGN KEY')
