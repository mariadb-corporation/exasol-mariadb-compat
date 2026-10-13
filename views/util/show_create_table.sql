-- Reconstructs a MariaDB-shaped CREATE TABLE statement per table, for the
-- preprocessor to serve SHOW CREATE TABLE from. Exasol stores no DDL text --
-- there is nothing to fetch -- so this is assembled from the catalog with
-- GROUP_CONCAT, one row per table.
--
-- It therefore describes the table Exasol HAS, not the statement that created
-- it. For CDC-replicated tables the MariaDB original never existed here, so
-- expect Exasol's types (DECIMAL(18,0) where MariaDB said int), no secondary
-- indexes or KEY lines (Exasol has none), and no foreign keys unless Exasol
-- itself holds the constraint. A primary key Exasol holds as disabled -- which
-- is how CDC creates them, and why such a key can sit on a nullable column --
-- is emitted with DISABLE, so running the DDL reproduces the table exactly
-- rather than silently adding NOT NULL.
--
-- The DDL is Exasol SQL -- double-quoted identifiers in the case Exasol stores
-- them, Exasol type names, no ENGINE or CHARSET clause -- so it can be run to
-- recreate the table. Emitting MariaDB syntax around Exasol types would produce
-- a statement valid in neither database.
--
-- Lives in UTIL rather than INFORMATION_SCHEMA because MariaDB has no such
-- table -- SHOW CREATE TABLE is the only interface to it.
CREATE OR REPLACE VIEW UTIL.SHOW_CREATE_TABLE AS
WITH cols AS (
    SELECT
        c.COLUMN_SCHEMA AS TABLE_SCHEMA,
        c.COLUMN_TABLE  AS TABLE_NAME,
        GROUP_CONCAT(
            '  "' || c.COLUMN_NAME || '" ' || c.COLUMN_TYPE
            || CASE WHEN c.COLUMN_IS_NULLABLE THEN '' ELSE ' NOT NULL' END
            || CASE WHEN c.COLUMN_DEFAULT IS NULL THEN ''
                    ELSE ' DEFAULT ' || TRIM(c.COLUMN_DEFAULT) END
            || CASE WHEN c.COLUMN_IDENTITY IS NULL THEN '' ELSE ' IDENTITY' END
            ORDER BY c.COLUMN_ORDINAL_POSITION
            SEPARATOR ',' || CHR(10)) AS COLUMN_LIST
    FROM SYS.EXA_ALL_COLUMNS c
    WHERE c.COLUMN_OBJECT_TYPE = 'TABLE'
    GROUP BY c.COLUMN_SCHEMA, c.COLUMN_TABLE
),
pk AS (
    SELECT
        cc.CONSTRAINT_SCHEMA AS TABLE_SCHEMA,
        cc.CONSTRAINT_TABLE  AS TABLE_NAME,
        GROUP_CONCAT('"' || cc.COLUMN_NAME || '"'
                     ORDER BY cc.ORDINAL_POSITION
                     SEPARATOR ', ') AS KEY_LIST,
        MIN(ct.CONSTRAINT_ENABLED) AS KEY_ENABLED
    FROM SYS.EXA_ALL_CONSTRAINT_COLUMNS cc
    JOIN SYS.EXA_ALL_CONSTRAINTS ct
      ON ct.CONSTRAINT_SCHEMA = cc.CONSTRAINT_SCHEMA
     AND ct.CONSTRAINT_TABLE = cc.CONSTRAINT_TABLE
     AND ct.CONSTRAINT_NAME = cc.CONSTRAINT_NAME
    WHERE cc.CONSTRAINT_TYPE = 'PRIMARY KEY'
    GROUP BY cc.CONSTRAINT_SCHEMA, cc.CONSTRAINT_TABLE
)
SELECT
    t.TABLE_SCHEMA                          AS "TABLE_SCHEMA",
    t.TABLE_NAME                            AS "TABLE_NAME",
    'CREATE TABLE "' || t.TABLE_NAME || '" (' || CHR(10)
        || cols.COLUMN_LIST
        || CASE WHEN pk.KEY_LIST IS NULL THEN ''
                ELSE ',' || CHR(10) || '  PRIMARY KEY (' || pk.KEY_LIST || ')'
                     || CASE WHEN pk.KEY_ENABLED THEN '' ELSE ' DISABLE' END END
        || CHR(10) || ')'
                                            AS "DDL"
FROM SYS.EXA_ALL_TABLES t
JOIN cols
  ON cols.TABLE_SCHEMA = t.TABLE_SCHEMA AND cols.TABLE_NAME = t.TABLE_NAME
LEFT JOIN pk
  ON pk.TABLE_SCHEMA = t.TABLE_SCHEMA AND pk.TABLE_NAME = t.TABLE_NAME
