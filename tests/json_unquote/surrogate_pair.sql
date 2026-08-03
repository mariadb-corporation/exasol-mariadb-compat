-- A surrogate pair must combine into the single astral character it encodes
-- (U+1F600), not be emitted as two lone surrogates.
SELECT JSON_UNQUOTE('"\\ud83d\\ude00"')
