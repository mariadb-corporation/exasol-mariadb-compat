-- MariaDB scans a single leading string token and ignores everything after
-- the closing quote, rather than requiring the whole input to be valid JSON.
SELECT JSON_UNQUOTE('"a" trailing'), JSON_UNQUOTE('"a"x'), JSON_UNQUOTE('"a" "b"')
