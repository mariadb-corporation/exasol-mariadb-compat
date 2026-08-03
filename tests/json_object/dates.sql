-- UTIL.JSON_OBJECT is a LUA script, and Exasol rejects DATE/TIMESTAMP arguments to
-- Lua scripts outright ("Lua script input type not supported DATE"), so date-typed
-- values must be CAST to VARCHAR at the call site. This test pins that supported
-- form. See the KNOWN LIMITATION block in udfs/json/json_object.sql.
-- NB the TIMESTAMP text keeps Exasol's '.000000' tail, where MariaDB renders
-- '2026-04-24 16:20:00', so this case diverges under --compare-direct.
SELECT JSON_OBJECT(
    'ts', CAST(CAST('2026-04-24 16:20:00' AS DATETIME) AS VARCHAR(30)),
    'd',  CAST(CAST('2026-04-24' AS DATE) AS VARCHAR(30))
)
