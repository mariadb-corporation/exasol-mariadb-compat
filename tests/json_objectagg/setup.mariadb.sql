DROP TABLE IF EXISTS `objectagg_test`;

CREATE TABLE `objectagg_test` (
    `ID`      INT,
    `KEYNAME` VARCHAR(50),
    `VAL`     VARCHAR(200),
    `NUM`     INT,
    PRIMARY KEY (`ID`)
);

INSERT INTO `objectagg_test` VALUES
    (1, 'a', 'hello', 100),
    (2, 'b', 'world', 200),
    (3, 'c', NULL,    300);

DROP TABLE IF EXISTS `objectagg_dates`;

CREATE TABLE `objectagg_dates` (
    `ID`          INT,
    `DESCRIPTION` VARCHAR(50),
    `UPDATEDATE`  DATE,
    PRIMARY KEY (`ID`)
);

INSERT INTO `objectagg_dates` VALUES
    (1, 'alpha', '2026-01-15'),
    (2, 'beta',  '2026-02-20');
