# exasol-mariadb-compat

MariaDB-compatible SQL UDFs for Exasol. Pairs with a MariaDB→Exasol query
rewriter (e.g. a sqlglot-based preprocessor) so apps written against MariaDB
run unchanged against Exasol.

All UDFs live in `UTIL.*` and are `CREATE OR REPLACE` — the same command
installs fresh and updates.

## Quick start

High level all you need to do is import `dist/mariadb-compat.sql`

### 1) Download the latest UDF Compatibility Pack SQL

```sh
curl -sSL -o mariadb-compat.sql https://raw.githubusercontent.com/mariadb-AllenHerrera/exasol-mariadb-compat/main/dist/mariadb-compat.sql
```
This file is regenerated every PR and contains all the UDFs and main preprocessor function

### 2) Import the SQL file into Exasol

Option A) Via Python (pyexasol) — **recommended**, installs all 9 scripts
```sh
git clone https://github.com/mariadb-AllenHerrera/exasol-mariadb-compat.git
cd exasol-mariadb-compat

pip install pyexasol
python install.py --host <host> --user sys --password <pw> [--no-ssl-verify]
```

Option B) Via Exaplus — installs 8 of 9 (production preprocessor included)
```sh
exaplus -c <host>:8563 -u sys -p <pw> -f mariadb-compat.sql
```

Exaplus 25.2.6 has a client-side parser bug that prevents two
`--/ ... /` `PREPROCESSOR` blocks installing in the same file: after
the first one, subsequent `--/` markers no longer enter script-body mode
and the next script's body is silently dropped. The bundle orders
`UTIL.MARIA_PREPROCESSOR` (production) before
`UTIL.MARIA_PREPROCESSOR_DEBUG` (dev-only) so production survives via
exaplus. Use `python install.py` if you also need DEBUG.

Re-run either command any time to pick up new/updated UDFs.

## What's shipped today

### UDFs (`udfs/`)

| UDF | MariaDB function | Notes |
|---|---|---|
| `UTIL.JSON_EXTRACT(doc, paths_json_array)` | `JSON_EXTRACT(doc, p1, ..., pN)` | Single path → JSON-typed value; multi-path → JSON array of matches with missing paths silently skipped; all-missing → NULL. Path grammar: `$`, `$.key`, `$[idx]`, dotted/indexed chains. Wildcards (`$**`, `$[*]`) not yet supported. |
| `UTIL.JSON_OBJECT(k1, v1, ..., kN, vN)` | `JSON_OBJECT(k1, v1, ...)` | Variadic key/value pairs → JSON object. DECIMAL values render as integers or floats; DATE / TIMESTAMP render as ISO-8601 strings. Odd-arg or NULL-key calls raise. |

### Preprocessor (`preprocessor/`)

`UTIL.MARIA_PREPROCESSOR` is an Exasol preprocessor script that, when
activated with `ALTER SESSION SET sql_preprocessor_script=UTIL.MARIA_PREPROCESSOR`,
transparently rewrites MariaDB SQL into Exasol SQL before it reaches the
engine. Under the hood it uses `sqlglot` (from whatever SLC is active) to
parse MariaDB, walks the AST rewriting specific constructs into calls
against the UDFs above (or into native Exasol functions where they match),
then generates the final Exasol SQL.

The rewrite table lives inside the preprocessor script. When adding a new
UDF here, add a corresponding branch to `_rewrite_to_util` in **both**
`maria_preprocessor.sql` and `maria_preprocessor_debug.sql` in the same PR.
Currently covered:

- `JSON_EXTRACT` → `UTIL.JSON_EXTRACT`
- `JSON_OBJECT` → `UTIL.JSON_OBJECT`

#### Safe vs debug variants

Two preprocessor scripts ship side by side, identical rewrite rules,
different error handling. Toggle per session:

```sql
-- Production / day-to-day: any sqlglot failure (parse error, transform
-- bug, unknown construct) returns the original statement so Exasol gets
-- to execute or reject it. Exasol-only syntax sails through unchanged.
ALTER SESSION SET sql_preprocessor_script=UTIL.MARIA_PREPROCESSOR;

-- Development: errors raise as full Python tracebacks via Exasol's
-- "While preprocessing SQL with..." wrapper, so you can see exactly
-- where sqlglot or the rewrite logic broke.
ALTER SESSION SET sql_preprocessor_script=UTIL.MARIA_PREPROCESSOR_DEBUG;
```

## Adding or updating UDFs (build from source)

1. Drop a single `CREATE OR REPLACE PYTHON3 SCALAR SCRIPT UTIL.<name>(...) ...`
   into `udfs/<category>/<name>.sql`. No trailing `;` or `/`.
2. Run `./build.sh` to regenerate `dist/mariadb-compat.sql` (stamped with the
   current `git describe` version).
3. Commit both the UDF source and the updated `dist/` file.

## Testing

Each UDF has a directory under `tests/` with optional per-engine fixtures
(`setup.exasol.sql` and/or `setup.mariadb.sql`) plus `<case>.sql` +
`<case>.expected.json` pairs. Rows are compared stringified so `DECIMAL` /
`int` / `float` collapse.

```sh
# Prereq: UTIL.* already installed (see Quick start)
pip install pyexasol
python tests/run_tests.py --host 127.0.0.1 --user sys --password exasol --port 8563 --no-ssl-verify

# Only one UDF:
python tests/run_tests.py --udf json_object --no-ssl-verify

# Cross-check each case against MariaDB (auto-spawns mariadb:11.8 on :3306
# if nothing's there; needs `pip install pymysql`):
python tests/run_tests.py --compare-direct --no-ssl-verify

# End-to-end check via an existing CDC pipe MariaDB → Exasol. Skips
# setup.exasol.sql DDL/data (CDC owns it; only ALTER SESSION lines are kept
# as session prelude), runs setup.mariadb.sql on MariaDB, and waits for CDC
# to propagate before running each case on both engines:
python tests/run_tests.py --compare-with-cdc --no-ssl-verify \
    --mariadb-user admin_user --mariadb-password 'aBc123%%'

# Route test execution through MaxScale (port 3309 by default) using a
# specific MariaDB connector. Setup still uses pyexasol direct; only test
# SQL goes via the chosen runner. See tests/connectors/README.md for the
# JSON Lines protocol each runner implements and the available choices
# (currently nodejs, python_pymysql, python_mariadb):
python tests/run_tests.py --connector nodejs --no-ssl-verify \
    --maxscale-host 127.0.0.1 --maxscale-port 3309 \
    --mariadb-user admin_user --mariadb-password 'aBc123%%' \
    --udf set_names
```

Each connector runner is also standalone-runnable on stdin/stdout for
ad-hoc probes (useful as a reproducer for upstream MaxScale / connector
bugs):

```sh
echo '{"name":"q","sql":"SET NAMES utf8"}' | \
    node tests/connectors/nodejs/runner.js \
         --host 127.0.0.1 --port 3309 --user admin_user --password 'aBc123%%'
```

The runner creates an ephemeral `MARIADB_COMPAT_TEST` schema, runs each
group's `setup.exasol.sql` inside it, executes every case, then drops the
schema. Under `--compare-direct` it also creates a same-named MariaDB
database, runs `setup.mariadb.sql`, and prints each case's MariaDB output
alongside Exasol's. Under `--compare-with-cdc` only `setup.mariadb.sql`
runs on MariaDB; tables and rows arrive on Exasol via CDC, validated with
a probe table at startup and per-group row-count polling. No persistent
state.

To eyeball the rewrite without a database in the loop, run the
preprocessor adapter locally via `tools/standalone_adhoc_test.py` — it
loads `preprocessor/maria_preprocessor.sql` (or `_debug.sql`) and runs
its `adapter_call` against SQL on stdin or a file. Uses whichever sqlglot
is on `PYTHONPATH`, so `pip install -e ../sqlglot` first if you're testing
fork changes:

```sh
echo "SELECT FIELD(x,'a','b') FROM t" | python3 tools/standalone_adhoc_test.py
python3 tools/standalone_adhoc_test.py path/to/query.sql
python3 tools/standalone_adhoc_test.py --safe < query.sql   # non-DEBUG variant
```

Watch shell quoting: an outer `'…'` is terminated by inner `'`s, so
`echo '… SELECT 1, ''val''…'` reaches Python with the inner quotes
stripped and `val` parsed as an identifier. Prefer a heredoc or a file
when the SQL contains string literals.

## Layout

```
exasol-mariadb-compat/
├── install.py                  # pyexasol installer (idempotent)
├── build.sh                    # aggregates udfs/**/*.sql → dist/mariadb-compat.sql
├── udfs/
│   └── json/
│       ├── json_extract.sql    # one CREATE OR REPLACE per file
│       └── json_object.sql
├── preprocessor/
│   └── maria_preprocessor.sql  # UTIL.MARIA_PREPROCESSOR: AST-level MariaDB → Exasol rewriter
├── tools/
│   └── standalone_adhoc_test.py # runs the preprocessor adapter locally (no DB needed)
├── dist/
│   └── mariadb-compat.sql      # built artifact, committed
└── tests/
    ├── run_tests.py
    ├── json_extract/           # UDF runtime tests (raw UTIL.* calls)
    ├── json_object/
    └── maria_preprocessor/     # end-to-end MariaDB SQL through the preprocessor
```

## Versioning

The first line of `dist/mariadb-compat.sql` carries the version, filled in by
`build.sh` from `git describe`. Tag releases (`v0.1.0`, `v0.2.0`, …) when you
cut one.

## Known semantic gaps

These are MariaDB behaviors the preprocessor deliberately does **not** try to
emulate, because any "fix" would be wrong in enough cases to do more harm
than good. Write the explicit form in your MariaDB source and the
transpilation works on both engines.

### `GROUP_CONCAT` without `ORDER BY`

MariaDB's `GROUP_CONCAT(col)` (no `ORDER BY` clause) often comes out in
auto-increment-PK order — not because it's specified, but because of how
InnoDB happens to return rows. sqlglot transpiles this to Exasol's
`LISTAGG(col, ',')`, which is genuinely non-deterministic without a
`WITHIN GROUP (ORDER BY ...)`.

We considered injecting an `ORDER BY <pk>` automatically and decided
against it. The heuristic only works for single-table queries with a
single-column auto-increment PK; joins, subqueries, CTEs, composite PKs,
and UUID PKs all produce wrong-but-runs SQL that fails far away from the
typo. The honest answer is to write the order you want in MariaDB:

```sql
-- portable
SELECT GROUP_CONCAT(name ORDER BY id) FROM users;

-- if you don't actually care about order, sort on the column itself —
-- deterministic on both engines:
SELECT GROUP_CONCAT(name ORDER BY name) FROM users;
```
