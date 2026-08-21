-- MariaDB INFORMATION_SCHEMA.STATISTICS over Exasol's
-- SYS.EXA_ALL_CONSTRAINT_COLUMNS. See tables.sql for why this is a view.
--
-- Clients read STATISTICS to discover a table's indexes and, more importantly,
-- to resolve its primary key — DBeaver's table editor issues
--   SELECT * FROM information_schema.STATISTICS
--   WHERE TABLE_SCHEMA=? AND TABLE_NAME=? ORDER BY TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX
-- on every table open, and without this view that query errors out.
--
-- Source is the constraint catalog, not SYS.EXA_ALL_INDICES. Exasol's indices
-- are auto-created physical join structures (LOCAL/GLOBAL, dropped and rebuilt
-- by the engine, present on staging tables too) and expose their columns only
-- inside a REMARKS string like 'LOCAL INDEX (id)'. Reporting those as MariaDB
-- indexes would name structures the user never created and cannot drop, so
-- only the key constraints Exasol actually enforces are listed.
--
-- Divergences from MariaDB:
--   * PRIMARY KEY and UNIQUE constraints only. InnoDB also auto-creates an
--     index behind every FOREIGN KEY and lists it here; Exasol does not, so
--     those rows are absent.
--   * CARDINALITY is NULL — Exasol keeps no per-index row estimate. A client
--     that sorts or filters on cardinality gets no useful ordering.
--   * Primary keys are renamed to 'PRIMARY', matching TABLE_CONSTRAINTS and
--     KEY_COLUMN_USAGE; the three are routinely joined and must agree.
--   * Exasol has no empty string — '' is NULL — so COMMENT and INDEX_COMMENT
--     come back NULL where MariaDB reports ''. Same caveat as columns.sql.
CREATE OR REPLACE VIEW INFORMATION_SCHEMA.STATISTICS AS
SELECT
    'def'                                   AS "TABLE_CATALOG",
    cc.CONSTRAINT_SCHEMA                    AS "TABLE_SCHEMA",
    cc.CONSTRAINT_TABLE                     AS "TABLE_NAME",
    0                                       AS "NON_UNIQUE",
    cc.CONSTRAINT_SCHEMA                    AS "INDEX_SCHEMA",
    CASE WHEN cc.CONSTRAINT_TYPE = 'PRIMARY KEY' THEN 'PRIMARY'
         ELSE cc.CONSTRAINT_NAME END        AS "INDEX_NAME",
    cc.ORDINAL_POSITION                     AS "SEQ_IN_INDEX",
    cc.COLUMN_NAME                          AS "COLUMN_NAME",
    'A'                                     AS "COLLATION",
    CAST(NULL AS DECIMAL(18, 0))            AS "CARDINALITY",
    -- Exasol has no prefix indexes and no PACK_KEYS equivalent.
    CAST(NULL AS DECIMAL(18, 0))            AS "SUB_PART",
    CAST(NULL AS VARCHAR(10))               AS "PACKED",
    CASE WHEN c.COLUMN_IS_NULLABLE THEN 'YES' ELSE '' END
                                            AS "NULLABLE",
    'BTREE'                                 AS "INDEX_TYPE",
    CAST('' AS VARCHAR(16))                 AS "COMMENT",
    CAST('' AS VARCHAR(1024))               AS "INDEX_COMMENT",
    'NO'                                    AS "IGNORED"
FROM SYS.EXA_ALL_CONSTRAINT_COLUMNS cc
LEFT JOIN SYS.EXA_ALL_COLUMNS c
       ON c.COLUMN_SCHEMA = cc.CONSTRAINT_SCHEMA
      AND c.COLUMN_TABLE  = cc.CONSTRAINT_TABLE
      AND c.COLUMN_NAME   = cc.COLUMN_NAME
WHERE cc.CONSTRAINT_TYPE IN ('PRIMARY KEY', 'UNIQUE')
