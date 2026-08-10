SET STATEMENT SQL_SELECT_LIMIT=20000 FOR
SELECT
    `ID`                                    AS id,
    COUNT(*) OVER ()                        AS total,
    RANK() OVER (ORDER BY `ID` DESC)        AS rnk
FROM `json_test`
ORDER BY `ID`
