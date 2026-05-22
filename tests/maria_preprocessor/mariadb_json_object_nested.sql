SELECT JSON_OBJECT(
    "data", JSON_OBJECT(
        "userActivity", JSON_OBJECT(
            "queueRecordSize", 100,
            "maxRecordSize",   1000
        ),
        "orgUnit", JSON_OBJECT(
            "aa", 123,
            "bb", 456
        )
    )
) AS retVal
