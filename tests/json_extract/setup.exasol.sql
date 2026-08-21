DROP TABLE IF EXISTS "json_test";

CREATE TABLE "json_test" (
    "ID"          INT,
    "JSON"        VARCHAR(2000000),
    "DESCRIPTION" VARCHAR(100),
    PRIMARY KEY ("ID")
);

INSERT INTO json_test VALUES
    (1, '{"a": 100, "b": "hello"}',        'Standard Integer'),
    (2, '{"a": "apple", "b": 200}',        'Standard String'),
    (3, '{"b": 300}',                       'Missing Key'),
    (4, '{"a": null}',                      'Explicit Null'),
    (5, '{"a": {"nested": "value"}}',      'Nested Object');

ALTER SESSION SET sql_preprocessor_script=UTIL.MARIA_PREPROCESSOR;
