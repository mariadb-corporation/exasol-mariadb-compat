SELECT `ID`, JSON_EXTRACT(`JSON`, '$.a') AS a_val
FROM `json_extract_test`
ORDER BY `ID`
