CREATE OR REPLACE PYTHON3 SCALAR SCRIPT UTIL.JSON_OBJECTAGG(s VARCHAR(2000000))
RETURNS VARCHAR(2000000) AS

import json


# MariaDB JSON_OBJECTAGG(key, value) aggregates rows into a single JSON object.
# Exasol implements user-defined aggregates as SET SCRIPTs, but emitting SET
# SCRIPTs cannot appear inside any expression context (scalar subqueries,
# argument positions, CTE referenced from an outer expression — all rejected
# with "emitting function in expression"). MariaDB JSON_OBJECTAGG routinely
# appears inside JSON_OBJECT(...) or as a scalar subquery, so a SET SCRIPT
# wouldn't cover real workloads.
#
# Workaround: the preprocessor rewrites MariaDB-form JSON_OBJECTAGG(k, v) into
#   UTIL.JSON_OBJECTAGG(LISTAGG(UTIL.JSON_OBJECT(k, v), ','))
# LISTAGG is a standard SQL aggregate (expression-safe). It concatenates each
# row's mini JSON object — produced by UTIL.JSON_OBJECT, which handles type
# coercion, JSON nesting, and NULL-key errors — into one comma-joined string.
# This UDF then wraps that string in [...] to make a JSON array, parses, and
# merges the per-row objects into one.
#
# Semantics:
#   - Empty group -> LISTAGG returns NULL -> we return NULL. Matches MariaDB.
#   - NULL key -> UTIL.JSON_OBJECT raises -> error propagates. Matches MariaDB.
#   - NULL value -> embedded as JSON `null`. Matches MariaDB.
#   - Duplicate keys -> last-write-wins (`dict.update`). Matches MariaDB's
#     "rows processed in unspecified order, later one wins" behavior.
#   - Aggregation order is whatever LISTAGG produces (no WITHIN GROUP ORDER BY
#     added by the preprocessor, so unspecified); same as MariaDB.


def run(ctx):
    s = ctx[0]
    if s is None:
        return None
    arr = json.loads('[' + s + ']')
    out = {}
    for o in arr:
        out.update(o)
    return json.dumps(out, ensure_ascii=False)
