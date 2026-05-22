DROP TABLE IF EXISTS json_quote_test;

CREATE TABLE json_quote_test (
    "ID"  INT,
    "S"   VARCHAR(200),
    PRIMARY KEY ("ID")
);

INSERT INTO json_quote_test VALUES
    (1, 'hello'),
    (2, ''),
    (3, 'a"b'),
    (4, NULL),
    (5, 'null'),
    (6, '{"k": 1}');

ALTER SESSION SET sql_preprocessor_script=UTIL.MARIA_PREPROCESSOR;
