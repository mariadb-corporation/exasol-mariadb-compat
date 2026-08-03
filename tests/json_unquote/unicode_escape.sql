-- \uXXXX escapes are resolved to the character they denote.
SELECT JSON_UNQUOTE('"caf\\u00e9"')
