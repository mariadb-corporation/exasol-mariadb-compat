-- MariaDB INFORMATION_SCHEMA.KEY_COLUMN_USAGE over Exasol's
-- SYS.EXA_ALL_CONSTRAINT_COLUMNS. See tables.sql for why this is a view.
--
-- Exasol names primary-key constraints with a generated identifier
-- (SYS_1327...), where MariaDB always calls them 'PRIMARY'. Clients identify
-- the primary key by that name, so PRIMARY KEY rows are renamed; UNIQUE and
-- FOREIGN KEY constraints keep the name Exasol reports.
--
-- Exasol's REFERENCED_* columns are NULL for non-foreign-key constraints, which
-- matches MariaDB, so the usual `REFERENCED_TABLE_NAME IS NULL` filter for
-- "primary/unique keys only" works unchanged.
CREATE OR REPLACE VIEW INFORMATION_SCHEMA.KEY_COLUMN_USAGE AS
SELECT
    'def'                                   AS "CONSTRAINT_CATALOG",
    cc.CONSTRAINT_SCHEMA                    AS "CONSTRAINT_SCHEMA",
    CASE WHEN cc.CONSTRAINT_TYPE = 'PRIMARY KEY' THEN 'PRIMARY'
         ELSE cc.CONSTRAINT_NAME END        AS "CONSTRAINT_NAME",
    'def'                                   AS "TABLE_CATALOG",
    cc.CONSTRAINT_SCHEMA                    AS "TABLE_SCHEMA",
    cc.CONSTRAINT_TABLE                     AS "TABLE_NAME",
    cc.COLUMN_NAME                          AS "COLUMN_NAME",
    cc.ORDINAL_POSITION                     AS "ORDINAL_POSITION",
    CASE WHEN cc.REFERENCED_TABLE IS NOT NULL THEN cc.ORDINAL_POSITION END
                                            AS "POSITION_IN_UNIQUE_CONSTRAINT",
    cc.REFERENCED_SCHEMA                    AS "REFERENCED_TABLE_SCHEMA",
    cc.REFERENCED_TABLE                     AS "REFERENCED_TABLE_NAME",
    cc.REFERENCED_COLUMN                    AS "REFERENCED_COLUMN_NAME"
FROM SYS.EXA_ALL_CONSTRAINT_COLUMNS cc
-- Exasol also records NOT NULL as a constraint (with a generated name and a NULL
-- ordinal); MariaDB's KEY_COLUMN_USAGE covers key constraints only.
WHERE cc.CONSTRAINT_TYPE IN ('PRIMARY KEY', 'UNIQUE', 'FOREIGN KEY')
