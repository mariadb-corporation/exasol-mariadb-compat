SELECT JSON_OBJECT(
    "data", JSON_OBJECT(
        "userActivity", JSON_OBJECT(
            "queueRecordSize", 100,
            "maxRecordSize",   1000
        ),
        "orgUnit", JSON_OBJECT(
            "aa", 123,
            "bb", 456
        ),
        "lastUpdates", (
            SELECT JSON_OBJECTAGG(t.description, t.updatedate)
            FROM (
                SELECT 'alpha' AS description, '2026-01-15' AS updatedate
                UNION ALL
                SELECT 'beta',  '2026-02-20'
            ) t
        )
    )
) AS retVal
