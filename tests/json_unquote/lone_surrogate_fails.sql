-- An unpaired surrogate makes the scan fail; only a full high+low pair
-- decodes to an astral character.
SELECT JSON_UNQUOTE('"\\ud83d"'), JSON_UNQUOTE('"\\ude00"')
