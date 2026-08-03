-- Raw (already-decoded) UTF-8 inside the quotes survives unchanged.
SELECT JSON_UNQUOTE('"日本"')
