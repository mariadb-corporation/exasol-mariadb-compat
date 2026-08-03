-- CAST is required because the preprocessor rewrites JSON_OBJECTAGG into
-- UTIL.JSON_OBJECTAGG(LISTAGG(UTIL.JSON_OBJECT(k, v), ',')), and UTIL.JSON_OBJECT
-- is a LUA script, which Exasol will not hand a DATE column. See the KNOWN
-- LIMITATION block in udfs/json/json_object.sql. A DATE renders as '2026-01-15',
-- so the expected output is unchanged from the PYTHON3 era.
SELECT JSON_OBJECTAGG(`DESCRIPTION`, CAST(`UPDATEDATE` AS VARCHAR(30))) FROM `objectagg_dates`
