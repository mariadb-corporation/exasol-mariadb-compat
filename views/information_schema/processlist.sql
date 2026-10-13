-- MariaDB INFORMATION_SCHEMA.PROCESSLIST over Exasol's SYS.EXA_ALL_SESSIONS.
-- See tables.sql for why this is a view. SHOW [FULL] PROCESSLIST is rewritten
-- onto this view by the preprocessor, so both spellings report the same rows.
--
-- These are Exasol sessions, not client connections to MaxScale: the router
-- holds pooled ODBC sessions, and Exasol internals (LogServer) appear too. The
-- data is real, but it answers a slightly different question than it does on
-- MariaDB.
--
-- EXA_ALL_SESSIONS, never EXA_DBA_SESSIONS -- the DBA view exposes far more
-- than a session list should, and this view runs with its owner's rights.
--
-- Exasol reports DURATION as 'H:MM:SS' text where MariaDB reports whole
-- seconds. HOST carries the driver description rather than host:port, INFO the
-- current activity rather than the query text (not available here), and Exasol
-- has no per-session schema, so DB is NULL.
CREATE OR REPLACE VIEW INFORMATION_SCHEMA.PROCESSLIST AS
SELECT
    s.SESSION_ID                            AS "ID",
    s.USER_NAME                             AS "USER",
    s.CLIENT                                AS "HOST",
    CAST(NULL AS VARCHAR(64))               AS "DB",
    s.COMMAND_NAME                          AS "COMMAND",
    CAST(
        TO_NUMBER(REGEXP_SUBSTR(s.DURATION, '[0-9]+', 1, 1)) * 3600
      + TO_NUMBER(REGEXP_SUBSTR(s.DURATION, '[0-9]+', 1, 2)) * 60
      + TO_NUMBER(REGEXP_SUBSTR(s.DURATION, '[0-9]+', 1, 3))
        AS DECIMAL(18, 0))                  AS "TIME",
    s.STATUS                                AS "STATE",
    s.ACTIVITY                              AS "INFO",
    CAST(0 AS DECIMAL(18, 3))               AS "PROGRESS"
FROM SYS.EXA_ALL_SESSIONS s
