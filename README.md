# exasol-mariadb-compat

MariaDB-compatible SQL UDFs for Exasol. Pairs with a MariaDB→Exasol query
rewriter (e.g. a sqlglot-based preprocessor) so apps written against MariaDB
run unchanged against Exasol.

All UDFs live in `UTIL.*` and are `CREATE OR REPLACE`

## Quick start

High level all you need to do is import `dist/mariadb-compat.sql`

### 1) Download the latest UDF Compatibility Pack SQL

```sh
curl -sSL -o mariadb-compat.sql https://raw.githubusercontent.com/mariadb-AllenHerrera/exasol-mariadb-compat/main/dist/mariadb-compat.sql
```
This file contains all the UDFs

### 2) Import the SQL file into Exasol

Option A) Via Exaplus
```sh
exaplus -c <host>:8563 -u sys -p <pw> -f mariadb-compat.sql
```

Option B) Via Python (pyexasol)
```sh
git clone https://github.com/mariadb-AllenHerrera/exasol-mariadb-compat.git
cd exasol-mariadb-compat

pip install pyexasol
python install.py --host <host> --user sys --password <pw> [--no-ssl-verify]
```

Re-run either command any time to pick up new/updated UDFs.

## How it works

Apps send MariaDB SQL to MaxScale's `exasolrouter`, which runs a
sqlglot-based preprocessor (`preprocessor/maria_preprocessor.py`) to rewrite
it into Exasol SQL. Where Exasol has an equivalent, sqlglot emits it directly.
Where it doesn't, the preprocessor maps the MariaDB function onto a UDF from
this pack (`udfs/`, installed into `UTIL.*`):

| MariaDB | Exasol |
|---|---|
| `JSON_EXTRACT(doc, p1, ..., pN)` | `UTIL.JSON_EXTRACT(...)` |
| `JSON_OBJECT(k, v, ...)` | `UTIL.JSON_OBJECT(...)` |
| `JSON_OBJECTAGG(k, v)` | `UTIL.JSON_OBJECTAGG(...)` |
| `JSON_MERGE_PRESERVE(...)` | `UTIL.JSON_MERGE_PRESERVE(...)` |
| `JSON_QUOTE(s)` / `JSON_UNQUOTE(s)` | `UTIL.JSON_QUOTE(s)` / `UTIL.JSON_UNQUOTE(s)` |
| `ELT(n, s1, ...)` / `FIELD(x, s1, ...)` | `UTIL.ELT(...)` / `UTIL.FIELD(...)` |

The preprocessor also answers a few MariaDB-only statements itself (such as
`SHOW ENGINES` or `@@variable` lookups), and `views/` adds MariaDB-style
`INFORMATION_SCHEMA` views over Exasol's catalog so clients like DBeaver work.

To deploy the preprocessor into MaxScale: `python3 tools/deploy_sqlglot_to_maxscale.py`.

## Testing

Each directory under `tests/` is a group: optional `setup.exasol.sql` /
`setup.mariadb.sql` fixtures plus `<case>.sql` and `<case>.expected.json`
pairs. Rows are compared as strings.

The main command:

```sh
python tests/run_tests.py --no-ssl-verify --via-maxscale --compare-with-cdc -vvv --connector all --parallel
```

This installs `dist/mariadb-compat.sql` into Exasol, then runs every case
through MaxScale (port 3311) once per connector (`nodejs`, `python_mariadb`,
`python_pymysql`, `java`, `mariadb_c`, `mariadb_cpp`), all in parallel, each in
its own schema. Each result is checked against `.expected.json` and also run
on MariaDB, whose tables reach Exasol through the CDC pipe. `-vvv` prints the
full setup, SQL, expected and actual output for every failure.

To run against your own deployment, point it at your hosts and credentials:

| Option | What it points at |
|---|---|
| `--host` `--port` `--user` `--password` | MaxScale's `exasolrouter` (default `127.0.0.1:3311`, `admin_user`) |
| `--exasol-host` `--exasol-port` `--exasol-user` `--exasol-password` | Exasol, for the install, schemas and CDC checks (default `localhost:8563`, `sys`) |
| `--mariadb-host` `--mariadb-port` `--mariadb-user` `--mariadb-password` | MariaDB, for `--compare-*` (default `127.0.0.1:3306`, `admin_user`) |
| `--connector` | one connector, a comma-separated list, or `all` |
| `--udf` | run only this test group (repeatable) |
| `--schema` | base name for the test schema (default `MARIADB_COMPAT_TEST`) |
| `--no-reload` | skip reinstalling the bundle first |

Run `python tests/run_tests.py --help` for everything else, including
`--compare-direct` (no CDC) and `--cdc-timeout`. `tests/connectors/README.md`
describes the connector runners.

To see how a statement is rewritten without a database, pipe it through
`tools/local_adhoc_test.py` (uses the repo's preprocessor) or
`tools/maxscale_adhoc_test.py` (uses the one deployed in MaxScale):

```sh
echo "SELECT FIELD(x,'a','b') FROM t" | python3 tools/local_adhoc_test.py
```

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
│   └── maria_preprocessor.py   # UTIL.MARIA_PREPROCESSOR: AST-level MariaDB → Exasol rewriter
├── tools/
│   └── local_adhoc_test.py # runs the preprocessor adapter locally (no DB needed)
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
