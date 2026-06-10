# Connectors

Per-language test runners that exercise the same `tests/<group>/` fixtures
through MaxScale's ExasolRouter instead of `pyexasol` direct. Each runner
implements the same driver-mode JSON Lines protocol so `run_tests.py` can
fan out across them.

## Driver-mode protocol

### Stdin (master → runner)

One JSON object per line:

```json
{"name": "<test-id>", "sql": "<MariaDB SQL>"}
```

EOF on stdin → runner closes its connection and exits cleanly.

### Stdout (runner → master)

First line — startup event:

```json
{"event": "ready", "driver": "<library>@<version>"}
```

…or, on connection failure, a single error line followed by exit code != 0:

```json
{"event": "error", "error": "<msg>"}
```

Per-request lines (one per stdin line, in order):

```json
{"name": "<test-id>", "ok": true,  "rows": [[...], [...]]}
{"name": "<test-id>", "ok": false, "error": "<msg>"}
```

`rows` is `[]` for non-SELECT statements (DDL / SET / DML).

## Available runners

| Runner | Library | Setup |
|---|---|---|
| `nodejs/`         | `mariadb-connector-nodejs@2.x` | `cd nodejs && npm install` |
| `python_mariadb/` | `mariadb-connector-python` (libmariadb-backed) | `pip install -r python_mariadb/requirements.txt` |
| `python_pymysql/` | `pymysql` (pure Python) | `pip install -r python_pymysql/requirements.txt` |
| `java/`           | MariaDB Connector/J (JDBC) | `cd java && ./fetch-deps.sh` (needs JDK 11+ on PATH) |
| `mariadb_c/`      | MariaDB Connector/C (libmariadb) | needs a C compiler + `mariadb_config` (Connector/C dev) on PATH; `run.sh` compiles `runner.c` on first use |
| `mariadb_cpp/`    | MariaDB Connector/C++ (libmariadbcpp) | `cd mariadb_cpp && ./fetch-deps.sh` (source-build Connector/C++ to /usr/local); `run.sh` compiles `runner.cpp` on first use |

(More to come — odbc.)

## Master-side invocation

`run_tests.py` adds `--connector` (default `pyexasol`, the existing
direct-to-Exasol path). Pass a non-default value to route test execution
through MaxScale via the named connector:

```bash
python tests/run_tests.py \
    --connector nodejs \
    --maxscale-host 127.0.0.1 --maxscale-port 3309 \
    --mariadb-user admin_user --mariadb-password 'aBc123%%' \
    --udf set_names
```

Setup (`setup.exasol.sql`, schema management, sqlglot version probe) still
runs over `pyexasol` direct regardless — only test-case execution moves to
the chosen connector.
