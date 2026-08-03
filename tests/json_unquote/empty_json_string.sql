-- '""' decodes to the empty string, but Exasol treats VARCHAR '' as NULL at
-- the UDF boundary, so this returns NULL here (MariaDB returns ''). Same
-- platform limitation pinned by json_quote/empty_string -- recorded so it
-- cannot change silently.
SELECT JSON_UNQUOTE('""')
