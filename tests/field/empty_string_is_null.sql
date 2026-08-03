-- Exasol treats '' IS NULL as TRUE, so the empty string reaches the UDF as NULL
-- and can never match. MariaDB coerces '' to 0 in mixed mode and answers 1.
-- Platform-level quirk, not fixable in the UDF -- see udfs/string/field.sql.
SELECT FIELD('', 0)
