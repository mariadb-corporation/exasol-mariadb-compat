DROP TABLE IF EXISTS is_test;

CREATE TABLE is_test (
    `ID`        INT,
    `NAME`      VARCHAR(100),
    `CODE`      CHAR(3),
    `AMOUNT`    DECIMAL(10,2),
    `CREATED`   TIMESTAMP
);

DROP TABLE IF EXISTS is_test_pk;

CREATE TABLE is_test_pk (
    `K1`    INT NOT NULL,
    `K2`    VARCHAR(10) NOT NULL,
    `VAL`   VARCHAR(20),
    PRIMARY KEY (`K1`, `K2`)
);
