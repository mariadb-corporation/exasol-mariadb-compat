-- Opens with '"' but does not close, so the trailing-quote guard rejects it
-- before any parse is attempted and the input passes through unchanged.
SELECT JSON_UNQUOTE('"unterminated')
