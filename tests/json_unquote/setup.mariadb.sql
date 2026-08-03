DROP TABLE IF EXISTS `json_unquote_test`;

CREATE TABLE `json_unquote_test` (
    `ID`  INT,
    `S`   VARCHAR(200),
    PRIMARY KEY (`ID`)
);

-- Row 2 uses '\\n' so MariaDB's literal escaping yields the same two
-- characters (backslash, n) that setup.exasol.sql stores as '\n'.
INSERT INTO `json_unquote_test` VALUES
    (1, '"hello"'),
    (2, '"a\\nb"'),
    (3, '"日本"'),
    (4, 'hello'),
    (5, '{"a": 1}'),
    (6, NULL),
    (7, '"unterminated'),
    (8, '""');
