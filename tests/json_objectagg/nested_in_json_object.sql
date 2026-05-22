SELECT JSON_OBJECT(
    'data', JSON_OBJECT(
        'orgUnit', JSON_OBJECT('aa', 123, 'bb', 456),
        'lastUpdates', (
            SELECT JSON_OBJECTAGG(`DESCRIPTION`, `UPDATEDATE`)
            FROM `objectagg_dates`
        )
    )
) AS retVal
