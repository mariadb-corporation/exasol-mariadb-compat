DROP TABLE IF EXISTS "json_test";

CREATE TABLE "json_test" (
    "ID"   INT,
    "JSON" VARCHAR(2000000),
    PRIMARY KEY ("ID")
);

INSERT INTO json_test VALUES
    (1, '{"a": 100, "b": "hello"}'),
    (2, '{"a": "apple", "b": 200}'),
    (3, '{"b": 300}'),
    (4, '{"a": null}'),
    (5, '{"a": {"nested": "value"}}');

ALTER SESSION SET sql_preprocessor_script=UTIL.MARIA_PREPROCESSOR;
