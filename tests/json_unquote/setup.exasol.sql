DROP TABLE IF EXISTS json_unquote_test;

CREATE TABLE json_unquote_test (
    "ID"  INT,
    "S"   VARCHAR(200),
    PRIMARY KEY ("ID")
);

-- Exasol string literals have no backslash escaping, so row 2 spells the
-- two-character sequence \n directly. setup.mariadb.sql writes it as '\\n'
-- to store the identical bytes on an engine that does interpret escapes.
INSERT INTO json_unquote_test VALUES
    (1, '"hello"'),
    (2, '"a\nb"'),
    (3, '"日本"'),
    (4, 'hello'),
    (5, '{"a": 1}'),
    (6, NULL),
    (7, '"unterminated'),
    (8, '""');

ALTER SESSION SET sql_preprocessor_script=UTIL.MARIA_PREPROCESSOR;
