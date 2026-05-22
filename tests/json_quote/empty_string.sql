-- Exasol treats VARCHAR '' as NULL at UDF boundaries, so JSON_QUOTE('')
-- returns NULL here (MariaDB would return '""'). The UDF code itself handles
-- the empty-string case correctly when invoked outside Exasol; this test
-- pins the platform-driven behavior so it doesn't change silently.
SELECT JSON_QUOTE('')
