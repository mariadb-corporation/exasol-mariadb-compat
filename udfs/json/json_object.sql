CREATE OR REPLACE PYTHON3 SCALAR SCRIPT UTIL.JSON_OBJECT(...)
RETURNS VARCHAR(2000000) AS

import json
import decimal
import datetime


def default_serializer(obj):
    if isinstance(obj, decimal.Decimal):
        if obj == obj.to_integral_value():
            return int(obj)
        return float(obj)
    if isinstance(obj, datetime.datetime):
        return obj.isoformat()
    if isinstance(obj, datetime.date):
        return obj.isoformat()
    raise TypeError(f'Object of type {type(obj).__name__} is not JSON serializable')


def run(ctx):
    n = exa.meta.input_column_count
    if n % 2 != 0:
        raise ValueError('JSON_OBJECT requires an even number of arguments (key-value pairs)')
    obj = {}
    for i in range(0, n, 2):
        key = ctx[i]
        if key is None:
            raise ValueError('JSON_OBJECT key must not be NULL')
        key = str(key)
        value = ctx[i + 1]
        # If a value is a string that looks like a JSON container (object or
        # array), parse it and embed the parsed value. Without this, a nested
        # UTIL.JSON_OBJECT (or JSON_EXTRACT / JSON_MERGE_PRESERVE) returns
        # JSON text that the outer call would re-quote as a string, producing
        # escaped output instead of properly nested JSON. Bare literals like
        # 'true' / 'null' / '123' are NOT parsed — that would change the
        # meaning of user-supplied scalar strings. A caller who genuinely
        # supplies a string that opens with '{' or '[' and happens to be valid
        # JSON will see it interpreted as JSON; this matches the behavior of
        # MariaDB's implicit JSON typing.
        if isinstance(value, str) and value[:1] in ('{', '['):
            try:
                value = json.loads(value)
            except ValueError:
                pass
        obj[key] = value
    return json.dumps(obj, default=default_serializer, ensure_ascii=False)
