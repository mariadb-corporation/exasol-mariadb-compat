DROP TABLE IF EXISTS is_test;

CREATE TABLE is_test (
    `ID`        INT,
    `NAME`      VARCHAR(100),
    `CODE`      CHAR(3),
    `AMOUNT`    DECIMAL(10,2),
    `CREATED`   TIMESTAMP(3)
);

-- Needed under --compare-with-cdc: CDC only creates a table on Exasol once a row
-- event for it flows, so a never-written table never arrives and the fixture
-- wait times out. Insert-then-delete materializes it while leaving it empty.
INSERT INTO is_test (`ID`) VALUES (0);
DELETE FROM is_test;

DROP TABLE IF EXISTS is_test_pk;

CREATE TABLE is_test_pk (
    `K1`    INT NOT NULL,
    `K2`    VARCHAR(10) NOT NULL,
    `VAL`   VARCHAR(20),
    PRIMARY KEY (`K1`, `K2`)
);

-- Needed under --compare-with-cdc: the PRIMARY KEY only reaches Exasol once a
-- row event flows (and the table itself isn't created until then).
INSERT INTO is_test_pk (`K1`, `K2`, `VAL`) VALUES (1, 'a', 'seed');
