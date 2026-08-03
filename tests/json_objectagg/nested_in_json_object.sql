SELECT JSON_OBJECT(
    'data', JSON_OBJECT(
        'orgUnit', JSON_OBJECT('aa', 123, 'bb', 456),
        'lastUpdates', (
            -- CAST required: UTIL.JSON_OBJECT is LUA and cannot take a DATE.
            -- See tests/json_objectagg/dates.sql and the KNOWN LIMITATION block
            -- in udfs/json/json_object.sql.
            SELECT JSON_OBJECTAGG(`DESCRIPTION`, CAST(`UPDATEDATE` AS VARCHAR(30)))
            FROM `objectagg_dates`
        )
    )
) AS retVal
