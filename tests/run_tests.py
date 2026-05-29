#!/usr/bin/env python3
"""Run UDF regression tests against a running Exasol with UTIL.* installed.

Each subdirectory of tests/ is one UDF group. Inside, optional per-engine
fixtures (`setup.exasol.sql` and/or `setup.mariadb.sql`), then one `<name>.sql`
+ `<name>.expected.json` pair per test case. The SQL file holds a single
SELECT; the JSON file holds the expected rows as a list of lists. Rows are
compared stringified so DECIMAL/int/float collapse.

Connection:
  default            run test SQL on Exasol via pyexasol-direct (--host:--port,
                     default :8563).
  --via-maxscale     run test SQL through MaxScale's Exasol router via a MariaDB
                     client instead (--host/--port/--user/--password default to
                     127.0.0.1/3311/admin_user/aBc123%%, connector default
                     python_mariadb), exercising the in-MaxScale sqlglot/
                     mariadb_preprocessor path. A pyexasol-direct control
                     connection to Exasol (--exasol-*, default localhost:8563)
                     still does the Exasol-native work — UDF reload, schema
                     create/drop, catalog/CDC queries — since that can't
                     round-trip through MaxScale's MariaDB preprocessor. Under
                     --compare-*, the comparison client connects directly to
                     MariaDB (--mariadb-*, default admin_user/aBc123%%).

Modes:
  default            run cases on Exasol, compare to .expected.json.
  --compare-direct   additionally run each case against MariaDB (auto-spawns
                     a mariadb:11.8 docker container if nothing is on :3306)
                     and print its output alongside Exasol's.
  --compare-with-cdc assume a CDC pipe MariaDB → Exasol exists. Validates it
                     by creating a probe table on MariaDB and waiting (up to
                     5 s) for it to appear in Exasol. Then per group: skip
                     setup.exasol.sql DDL/data (CDC owns it; only ALTER
                     SESSION lines are kept as Exasol session prelude), run
                     setup.mariadb.sql on MariaDB, wait for CDC to propagate
                     each created table's row count, then run each case on
                     both engines.

Prereqs: UTIL.* UDFs installed (run ../install.py first).

Install: pip install pyexasol
        pip install pymysql   # only if --compare-direct is used
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

try:
    import pyexasol
except ImportError:
    sys.stderr.write("pyexasol is required: pip install pyexasol\n")
    sys.exit(3)


def _split_sql(text: str) -> list[str]:
    return [s.strip() for s in text.split(";") if s.strip()]


# {connector_name: (interpreter, script_filename)} — each runner lives at
# tests/connectors/<name>/<script_filename> and implements the JSON Lines
# protocol documented in tests/connectors/README.md. Adding a new connector
# is a one-line entry plus the runner file.
_CONNECTOR_RUNNERS = {
    "nodejs":         ("node",    "runner.js"),
    "python_mariadb": ("python3", "runner.py"),
    "python_pymysql": ("python3", "runner.py"),
    "java":           ("bash",    "run.sh"),  # wrapper compiles Runner.java
    "mariadb_c":      ("bash",    "run.sh"),  # wrapper compiles runner.c (libmariadb)
}


class _PyexasolRunner:
    """Default runner: executes test SQL on the existing pyexasol connection."""

    name = "pyexasol"

    def __init__(self, c):
        self.c = c

    def execute(self, name: str, sql: str) -> list[list]:
        stmt = self.c.execute(sql)
        if getattr(stmt, "result_type", "resultSet") == "resultSet":
            return [list(r) for r in stmt.fetchall()]
        return []

    def close(self):
        pass


def _suggest_node_switch() -> str:
    """Find the newest nvm-installed node >= 12.5 and return a copy-pasteable
    `nvm use vX.Y.Z`; fall back to installing the LTS if none qualifies."""
    import os
    import pathlib
    nvm = os.environ.get("NVM_DIR") or os.path.expanduser("~/.nvm")
    best = None
    try:
        for d in (pathlib.Path(nvm) / "versions" / "node").iterdir():
            try:
                parts = tuple(int(x) for x in d.name.lstrip("v").split(".")[:3])
            except ValueError:
                continue
            if parts[:2] >= (12, 5) and (best is None or parts > best[0]):
                best = (parts, d.name)
    except OSError:
        pass
    return f"nvm use {best[1]}" if best else "nvm install --lts && nvm use --lts"


def _node_too_old(interp: str) -> str | None:
    """Precheck for the nodejs connector: runner.js uses ES2021 numeric
    separators, so node must be >= 12.5. Returns a human-readable reason if node
    is missing or too old, else None (unknown/OK — let the runner try)."""
    import shutil
    import subprocess
    if not shutil.which(interp):
        return f"{interp!r} not found on PATH"
    try:
        ver = subprocess.run([interp, "--version"], capture_output=True, text=True,
                             timeout=5).stdout.strip().lstrip("v")
        major, minor = int(ver.split(".")[0]), int(ver.split(".")[1])
    except Exception:
        return None
    if (major, minor) < (12, 5):
        return (f"node {ver} is too old (runner.js needs >= 12.5 for numeric "
                f"separators) — run: {_suggest_node_switch()}")
    return None


def _runner_start_hint(stderr: str) -> str:
    """Map a runner's pre-ready stderr to a likely cause, appended to the error."""
    low = stderr.lower()
    if "invalid or unexpected token" in low:
        return ("\n  -> likely an outdated interpreter (e.g. node < 12.5 can't parse "
                f"runner.js) — run: {_suggest_node_switch()}")
    if "cannot find module" in low or "modulenotfounderror" in low:
        return "\n  -> likely missing dependencies — install the runner's deps first"
    return ""


class _SubprocessRunner:
    """Driver-mode JSON Lines runner — talks to a long-lived subprocess that
    implements the protocol documented under tests/connectors/README.md."""

    def __init__(self, name: str, cmd: list[str]):
        import subprocess
        self.name = name
        try:
            self.proc = subprocess.Popen(
                cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True, bufsize=1,
            )
        except FileNotFoundError:
            raise RuntimeError(
                f"{name} runner: interpreter {cmd[0]!r} not found on PATH — is it installed?")
        # Wait for the ready/error event before driving requests through.
        first = self.proc.stdout.readline()
        if not first:
            err = (self.proc.stderr.read() or "").strip()
            raise RuntimeError(f"{name} runner exited before ready: {err}{_runner_start_hint(err)}")
        evt = json.loads(first)
        if evt.get("event") == "error":
            raise RuntimeError(f"{name} runner connect failed: {evt.get('error')}")
        if evt.get("event") != "ready":
            raise RuntimeError(f"{name} runner unexpected first line: {first!r}")
        self.driver = evt.get("driver", "?")

    def execute(self, name: str, sql: str) -> list[list]:
        self.proc.stdin.write(json.dumps({"name": name, "sql": sql}) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            err = self.proc.stderr.read()
            raise RuntimeError(f"{self.name} runner died: {err.strip()}")
        result = json.loads(line)
        if not result.get("ok"):
            raise RuntimeError(result.get("error", "unknown error"))
        return [list(r) for r in (result.get("rows") or [])]

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def _reload_udfs_and_preprocessor(c, repo_root: Path, verbose: int = 0) -> int:
    """Run dist/mariadb-compat.sql against the open connection so the test
    session always exercises the working-tree bundle. The bundle separates
    statements three ways: SCALAR scripts are wrapped in `^--/$` ... `^/$`
    block markers (so exaplus enters script-body mode), and PREPROCESSOR
    scripts terminate with a bare `^;$` line (build.sh notes that exaplus
    25.2.6 doesn't enter script-body mode for CREATE PREPROCESSOR SCRIPT).
    Split on any of the three so each CREATE statement becomes one execute()
    call. Each resulting part is a single statement with optional surrounding
    SQL comments — strip leading `--` and blank lines, then send what remains
    to Exasol. Returns the count of statements actually executed."""
    bundle = repo_root / "dist" / "mariadb-compat.sql"
    if not bundle.exists():
        raise FileNotFoundError(
            f"{bundle} not found — run ./build.sh to regenerate, or pass --no-reload"
        )
    parts = re.split(r"(?m)^\s*(?:--/|/|;)\s*$", bundle.read_text())
    executed = 0
    for part in parts:
        body = []
        for line in part.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("--"):
                continue
            body.append(line)
        stmt = "\n".join(body).rstrip().rstrip(";")
        if not stmt:
            continue
        if verbose >= 2:
            head = stmt.splitlines()[0][:80]
            print(f"[reload] {head}")
        c.execute(stmt)
        executed += 1
    return executed


MARIADB_CONTAINER_NAME = "exasol-mariadb-compat-test"


def _port_open(host: str, port: int, timeout: float = 2.0) -> bool:
    import socket
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _is_local(host: str) -> bool:
    return host in ("localhost", "127.0.0.1", "::1", "0.0.0.0")


def _maxscale_sqlglot_version(container: str = "maxscale"):
    """Best-effort: return the sqlglot version MaxScale uses to transpile (its
    bundled site-packages, NOT the Exasol SLC's), by exec'ing into the MaxScale
    container. Returns the version string, or None if no MaxScale container is
    detected (docker missing or container absent)."""
    import subprocess
    cmd = ["docker", "exec",
           "-e", "PYTHONPATH=/usr/lib64/maxscale/python3/site-packages",
           container, "/usr/bin/python3.12", "-c",
           "import sqlglot; print(sqlglot.__version__)"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None  # docker not installed / unresponsive
    if r.returncode == 0 and r.stdout.strip():
        return r.stdout.strip()
    err = (r.stderr or r.stdout).strip()
    if "no such container" in err.lower():
        return None
    return f"probe error: {err or 'no output'}"


def _docker_available() -> bool:
    import subprocess
    try:
        r = subprocess.run(["docker", "version"], capture_output=True, timeout=5)
        return r.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def _start_mariadb_container(image: str, port: int, password: str) -> None:
    import subprocess
    subprocess.run(["docker", "rm", "-f", MARIADB_CONTAINER_NAME], capture_output=True)
    env = (["-e", f"MARIADB_ROOT_PASSWORD={password}"] if password
           else ["-e", "MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=yes"])
    subprocess.run(
        ["docker", "run", "-d", "--rm",
         "--name", MARIADB_CONTAINER_NAME,
         "-p", f"{port}:3306",
         *env, image],
        check=True, capture_output=True,
    )


def _stop_mariadb_container() -> None:
    import subprocess
    subprocess.run(["docker", "rm", "-f", MARIADB_CONTAINER_NAME], capture_output=True)


def _wait_for_mariadb(connect_kwargs: dict, timeout: float = 60.0):
    import time
    import pymysql
    deadline = time.monotonic() + timeout
    last_err: Exception | None = None
    while time.monotonic() < deadline:
        try:
            return pymysql.connect(**connect_kwargs)
        except Exception as e:
            last_err = e
            time.sleep(1)
    raise RuntimeError(f"MariaDB did not become ready within {int(timeout)}s: {last_err}")


_CREATE_TABLE_RE = None


def _parse_create_tables(sql_text: str) -> list[str]:
    """Return the bare table names referenced by CREATE TABLE statements.
    Handles backticks, double quotes, and `IF NOT EXISTS`. Drops db-qualifier."""
    import re
    global _CREATE_TABLE_RE
    if _CREATE_TABLE_RE is None:
        _CREATE_TABLE_RE = re.compile(
            r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?"
            r"(?:[`\"]?\w+[`\"]?\s*\.\s*)?[`\"]?(\w+)[`\"]?",
            re.IGNORECASE,
        )
    return [m.group(1) for m in _CREATE_TABLE_RE.finditer(sql_text)]


def _exasol_session_prelude(setup_text: str) -> list[str]:
    """In CDC mode, only `ALTER SESSION` statements from setup.exasol.sql
    apply — table/data DDL is owned by CDC, but session knobs (e.g. enabling
    UTIL.MARIA_PREPROCESSOR) still need to be set on the test session."""
    return [s for s in _split_sql(setup_text)
            if s.upper().startswith("ALTER SESSION")]


def _cdc_probe(c, mc, schema: str, timeout: float = 5.0) -> None:
    """Validate the CDC pipe by creating a small PK'd table on MariaDB and
    waiting for it to appear in Exasol's catalog. Drops the probe afterward."""
    import time
    # No leading underscore: the CDC consumer emits unquoted identifiers
    # (e.g. `DROP TABLE IF EXISTS SCHEMA._cdc_probe_X`) and Exasol's parser
    # rejects an unquoted name that starts with `_`.
    probe = f"cdc_probe_{int(time.monotonic() * 1000) % 1_000_000}"
    with mc.cursor() as mcur:
        mcur.execute(f"DROP TABLE IF EXISTS `{probe}`")
        mcur.execute(f"CREATE TABLE `{probe}` (id INT PRIMARY KEY)")
        # MaxScale CDC streams DML row events, not bare DDL: an empty table never
        # produces a change record, so the consumer never materializes it in
        # Exasol. Insert a row to actually trigger the pipe.
        mcur.execute(f"INSERT INTO `{probe}` (id) VALUES (1)")
    deadline = time.monotonic() + timeout
    found = False
    last_err: Exception | None = None
    try:
        while time.monotonic() < deadline:
            try:
                rs = c.execute(
                    "SELECT 1 FROM SYS.EXA_ALL_TABLES "
                    f"WHERE UPPER(TABLE_SCHEMA) = '{schema.upper()}' "
                    f"AND UPPER(TABLE_NAME) = '{probe.upper()}'"
                ).fetchall()
                if rs:
                    found = True
                    break
            except Exception as e:
                last_err = e
            time.sleep(0.25)
    finally:
        try:
            with mc.cursor() as mcur:
                mcur.execute(f"DROP TABLE IF EXISTS `{probe}`")
        except Exception:
            pass
    if not found:
        msg = (f"CDC probe '{probe}' did not appear in Exasol schema {schema} within {int(timeout)}s"
               f" — raise --cdc-probe-timeout if the pipe is just slow")
        if last_err is not None:
            msg += f" (last catalog query error: {last_err})"
        raise RuntimeError(msg)


def _wait_for_cdc_propagation(c, mc, schema: str, tables: list[str], timeout: float = 10.0) -> None:
    """After running setup.mariadb.sql, wait until each created table has the
    same row count on Exasol as on MariaDB. Schema/table names are matched
    case-insensitively against SYS.EXA_ALL_TABLES."""
    import time
    if not tables:
        return
    counts_my: dict[str, int] = {}
    with mc.cursor() as mcur:
        for t in tables:
            mcur.execute(f"SELECT COUNT(*) FROM `{t}`")
            counts_my[t] = int(mcur.fetchone()[0])
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        all_ok = True
        for t, want in counts_my.items():
            try:
                rs = c.execute(
                    "SELECT TABLE_NAME FROM SYS.EXA_ALL_TABLES "
                    f"WHERE UPPER(TABLE_SCHEMA) = '{schema.upper()}' "
                    f"AND UPPER(TABLE_NAME) = '{t.upper()}'"
                ).fetchall()
                if not rs:
                    all_ok = False
                    break
                actual = rs[0][0]
                got = c.execute(f'SELECT COUNT(*) FROM "{schema}"."{actual}"').fetchall()[0][0]
                if int(got) != want:
                    all_ok = False
                    break
            except Exception:
                all_ok = False
                break
        if all_ok:
            return
        time.sleep(0.5)
    raise RuntimeError(
        f"CDC fixture propagation timed out after {int(timeout)}s "
        f"(expected on Exasol {schema}: {counts_my})"
    )


def _resolve_connectors(args) -> list[str]:
    """Expand --connector into a concrete list. 'all' = every connector valid
    for the mode (pyexasol excluded under --via-maxscale, where it can't reach
    MaxScale); a comma-separated list is taken verbatim; anything else is a
    single connector."""
    valid = ["pyexasol", *_CONNECTOR_RUNNERS]
    if args.connector == "all":
        return [c for c in valid if not (args.via_maxscale and c == "pyexasol")]
    conns = [s.strip() for s in args.connector.split(",") if s.strip()]
    bad = [c for c in conns if c not in valid]
    if bad:
        raise SystemExit(f"[setup] unknown connector(s) {bad}; choose from {valid} or 'all'")
    return conns


def _argv_without_connector(argv: list[str]) -> list[str]:
    """Original CLI args minus the --connector option (so we can re-issue it
    per connector when running several)."""
    out, skip = [], False
    for tok in argv:
        if skip:
            skip = False
            continue
        if tok == "--connector":
            skip = True
            continue
        if tok.startswith("--connector="):
            continue
        out.append(tok)
    return out


def _run_many(args, connectors: list[str]) -> int:
    """Run the suite once per connector — each a fresh subprocess so its setup
    (schema, fixtures) is fully isolated — teeing output live, then print a
    summary table. The UTIL.* UDFs live in their own schema and persist, so we
    reload only on the first connector."""
    import os
    import re
    import subprocess
    base = [sys.executable, os.path.abspath(__file__)]
    passthrough = _argv_without_connector(sys.argv[1:])
    env = {**os.environ, "PYTHONUNBUFFERED": "1"}
    rows = []
    for i, conn in enumerate(connectors):
        argv = base + passthrough + ["--connector", conn]
        if i > 0 and not args.no_reload:
            argv.append("--no-reload")  # UTIL.* already loaded by the first run
        print(f"\n==== connector: {conn} ====")
        passed = total = None
        note = ""
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, env=env)
        for line in proc.stdout:
            sys.stdout.write(line)
            m = re.search(r"(\d+)/(\d+) passed", line)
            if m:
                passed, total = int(m.group(1)), int(m.group(2))
            if "unavailable:" in line:
                note = "skipped — " + line.split("unavailable:", 1)[1].strip()
            elif re.search(r"\[setup\].*(failed|unreachable|not detected)", line):
                note = line.split("]", 1)[1].strip() if "]" in line else line.strip()
        rc = proc.wait()
        rows.append((conn, rc, passed, total, note))

    print("\n==== summary ====")
    w = max(len(c) for c, *_ in rows)
    bad = False
    for conn, rc, passed, total, note in rows:
        if rc == 0:
            result = f"{passed}/{total}" if total is not None else "passed"
        elif note.startswith("skipped"):
            result = note
        elif rc == 1 and total is not None:
            result = f"{passed}/{total}  ({total - passed} failed)"
            bad = True
        else:
            result = note or f"error (exit {rc})"
            bad = True
        print(f"  {conn.ljust(w)}  {result}")
    return 1 if bad else 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default=None,
                   help="Primary connection host. Default: localhost (Exasol direct), "
                        "or 127.0.0.1 under --via-maxscale (MaxScale).")
    p.add_argument("--port", default=None,
                   help="Primary connection port. Default: 8563 (Exasol direct), "
                        "or 3311 under --via-maxscale (MaxScale).")
    p.add_argument("--user", default=None,
                   help="Primary connection user. Default: sys (Exasol direct), "
                        "or admin_user under --via-maxscale (MaxScale).")
    p.add_argument("--password", default=None,
                   help="Primary connection password. Default: exasol (Exasol direct), "
                        "or aBc123%%%% under --via-maxscale (MaxScale).")
    p.add_argument("--no-ssl-verify", action="store_true",
                   help="Skip Exasol TLS cert validation (for docker-db's self-signed cert)")
    p.add_argument("--via-maxscale", action="store_true",
                   help="Route the primary connection through MaxScale's Exasol router "
                        "(MariaDB wire protocol) instead of pyexasol-direct, exercising the "
                        "in-MaxScale sqlglot/mariadb_preprocessor path. Flips the "
                        "--host/--port/--user/--password defaults to MaxScale "
                        "(127.0.0.1/3311/admin_user/aBc123%%%%) and runs all SQL via a MariaDB "
                        "connector (--connector, default python_mariadb). The UTIL.* UDF bundle "
                        "is still loaded into Exasol directly over the --exasol-* connection.")
    p.add_argument("--exasol-host", default="localhost",
                   help="Exasol host for the --via-maxscale UDF-reload connection (default: localhost)")
    p.add_argument("--exasol-port", default="8563",
                   help="Exasol port for the --via-maxscale UDF-reload connection (default: 8563)")
    p.add_argument("--exasol-user", default="sys",
                   help="Exasol user for the --via-maxscale UDF-reload connection (default: sys)")
    p.add_argument("--exasol-password", default="exasol",
                   help="Exasol password for the --via-maxscale UDF-reload connection (default: exasol)")
    p.add_argument("--script-language", default=None,
                   help="If set, run ALTER SESSION SET SCRIPT_LANGUAGES='<value>' before tests, "
                        "to pin the SLC under test (e.g. a custom-built one carrying a specific "
                        "sqlglot version). The full SCRIPT_LANGUAGES value is taken verbatim.")
    p.add_argument("--tests-dir", type=Path, default=Path(__file__).parent,
                   help="Directory to scan for UDF test subdirs (default: this script's dir)")
    p.add_argument("--connector", default="pyexasol",
                   help="Which client executes test SQL: 'pyexasol' (default, Exasol "
                        "direct on --port) or one of " + ", ".join(_CONNECTOR_RUNNERS)
                        + " (spawn a runner under tests/connectors/<name>/, talking JSON "
                        "Lines; these go via MaxScale at --maxscale-host:--maxscale-port "
                        "using --mariadb-user/--mariadb-password). Pass a comma-separated "
                        "list or 'all' to run several and print a summary table ('all' "
                        "excludes pyexasol under --via-maxscale).")
    p.add_argument("--maxscale-host", default="127.0.0.1",
                   help="MaxScale host for non-pyexasol connectors (default: 127.0.0.1)")
    p.add_argument("--maxscale-port", type=int, default=3309,
                   help="MaxScale port for non-pyexasol connectors (default: 3309)")
    p.add_argument("--no-reload", action="store_true",
                   help="Skip the install-from-disk step. By default each run executes "
                        "dist/mariadb-compat.sql from this checkout into the DB before "
                        "running tests, so the test target is always the working-tree bundle. "
                        "Run ./build.sh first if you've edited UDFs or the preprocessor.")
    p.add_argument("--repo-root", type=Path,
                   default=Path(__file__).resolve().parent.parent,
                   help="Repo root used by the reload step (looks up dist/mariadb-compat.sql "
                        "underneath; default: parent of tests/)")
    p.add_argument("--schema", default="MARIADB_COMPAT_TEST",
                   help="Ephemeral schema for fixtures (dropped at end)")
    p.add_argument("--udf", action="append", default=None,
                   help="Run only these UDF groups (repeatable; default: all)")
    p.add_argument("-v", "--verbose", action="count", default=0,
                   help="Print SQL and result rows for each test (-vv also prints setup SQL)")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--compare-direct", action="store_true",
                      help="Run each test SQL directly against MariaDB (using setup.mariadb.sql) and "
                           "print the result alongside Exasol's, marking (DIFF) when stringified rows "
                           "differ. Does not change pass/fail.")
    mode.add_argument("--compare-with-cdc", action="store_true",
                      help="Like --compare-direct, but assumes a CDC pipe MariaDB → Exasol is running. "
                           "Validates the pipe with a probe table (5 s budget), then for each group runs "
                           "only setup.mariadb.sql and waits for CDC to propagate the fixtures to Exasol.")
    p.add_argument("--cdc-timeout", type=float, default=10.0,
                   help="Seconds to wait for setup.mariadb.sql to propagate to Exasol per group "
                        "(--compare-with-cdc only; default: 10)")
    p.add_argument("--cdc-probe-timeout", type=float, default=5.0,
                   help="Seconds to wait for the initial CDC probe table to appear in Exasol "
                        "(--compare-with-cdc only; default: 5)")
    p.add_argument("--mariadb-host", default="127.0.0.1")
    p.add_argument("--mariadb-port", type=int, default=3306)
    p.add_argument("--mariadb-user", default=None,
                   help="MariaDB comparison-connection user. Default: root, "
                        "or admin_user under --via-maxscale.")
    p.add_argument("--mariadb-password", default=None,
                   help="MariaDB comparison-connection password. Default: empty, "
                        "or aBc123%%%% under --via-maxscale.")
    p.add_argument("--mariadb-image", default="mariadb:11.8",
                   help="Image used to auto-spawn a container when --compare-direct can't reach "
                        "MariaDB (local hosts only). Default: mariadb:11.8")
    p.add_argument("--no-spawn-mariadb", action="store_true",
                   help="Disable auto-spawning a MariaDB docker container under --compare-direct")
    args = p.parse_args()

    # Resolve primary-connection defaults: the Exasol WebSocket endpoint by
    # default, or the MaxScale MariaDB endpoint under --via-maxscale. (Done
    # post-parse so explicit flags still win in either mode.)
    if args.via_maxscale:
        args.host = args.host or "127.0.0.1"
        args.port = args.port or "3311"
        args.user = args.user or "admin_user"
        args.password = "aBc123%%" if args.password is None else args.password
        args.mariadb_user = args.mariadb_user or "admin_user"
        args.mariadb_password = "aBc123%%" if args.mariadb_password is None else args.mariadb_password
    else:
        args.host = args.host or "localhost"
        args.port = args.port or "8563"
        args.user = args.user or "sys"
        args.password = "exasol" if args.password is None else args.password
        args.mariadb_user = args.mariadb_user or "root"
        args.mariadb_password = "" if args.mariadb_password is None else args.mariadb_password

    # 'all' / comma-list / single → list. Multiple connectors fan out to one
    # subprocess each and report a summary table; a single connector runs inline.
    connectors = _resolve_connectors(args)
    if len(connectors) > 1:
        return _run_many(args, connectors)
    args.connector = connectors[0]

    # The control connection `c` is always pyexasol direct to Exasol: it owns
    # the Exasol-native work (UDF reload, CREATE/OPEN SCHEMA, catalog/CDC
    # queries, DROP SCHEMA) that can't round-trip through MaxScale's MariaDB
    # preprocessor. Under --via-maxscale it points at --exasol-* and test SQL
    # runs over the MaxScale runner built below; otherwise it points at the
    # primary --host/--port and (for the default connector) runs the tests too.
    if args.via_maxscale:
        exa_host, exa_port = args.exasol_host, args.exasol_port
        exa_user, exa_pass = args.exasol_user, args.exasol_password
    else:
        exa_host, exa_port = args.host, args.port
        exa_user, exa_pass = args.user, args.password
    connect_kwargs = dict(dsn=f"{exa_host}:{exa_port}", user=exa_user,
                          password=exa_pass, compression=True)
    if args.no_ssl_verify:
        import ssl
        connect_kwargs["websocket_sslopt"] = {"cert_reqs": ssl.CERT_NONE}
    try:
        c = pyexasol.connect(**connect_kwargs)
    except Exception as e:
        label = "Exasol control" if args.via_maxscale else "Exasol"
        print(f"[setup] {label} connection ({exa_host}:{exa_port}) failed: {e}", file=sys.stderr)
        return 3

    if args.script_language:
        escaped = args.script_language.replace("'", "''")
        stmt = f"ALTER SESSION SET SCRIPT_LANGUAGES='{escaped}'"
        try:
            c.execute(stmt)
            if args.verbose >= 2:
                print(f"[setup] {stmt}")
        except Exception as e:
            print(f"[setup] ALTER SESSION SET SCRIPT_LANGUAGES failed: {e}", file=sys.stderr)
            return 3

    if not args.no_reload:
        try:
            n = _reload_udfs_and_preprocessor(c, args.repo_root, verbose=args.verbose)
            print(f"[reload] {n} statements from {args.repo_root}/dist/mariadb-compat.sql")
        except Exception as e:
            print(f"[reload] failed: {e}", file=sys.stderr)
            return 3

    try:
        c.execute(f"CREATE SCHEMA IF NOT EXISTS {args.schema}")
        c.execute(f"OPEN SCHEMA {args.schema}")
    except Exception as e:
        print(f"[setup] schema creation failed: {e}", file=sys.stderr)
        return 3

    # The Exasol SLC's sqlglot is the transpiler only in pyexasol-direct mode.
    # Under --via-maxscale, MaxScale transpiles, so the SLC version (here and in
    # the runner probe below) is noise — skip it and report MaxScale's instead.
    if not args.via_maxscale:
        try:
            gv = c.execute("SELECT UTIL.GET_GLOT_VERSION()").fetchall()
            print(f"[setup] sqlglot in active SLC: {gv[0][0] if gv else 'unknown'}")
        except Exception as e:
            print(f"[setup] sqlglot version probe failed (UTIL.GET_GLOT_VERSION not installed?): {e}",
                  file=sys.stderr)

    # MaxScale's bundled sqlglot is what rewrites the SQL — the only version
    # that matters under --via-maxscale. Always try to report it (the container
    # may exist regardless of mode); say so cleanly if it isn't there.
    mxver = _maxscale_sqlglot_version()
    if mxver is None:
        print("[setup] MaxScale docker container not detected; skipping its sqlglot version probe")
    else:
        print(f"[setup] sqlglot in MaxScale: {mxver}")

    # Build the test-execution runner. The default pyexasol connector reuses the
    # control connection (Exasol direct). Other connectors — and --via-maxscale —
    # talk to MaxScale via a subprocess implementing the JSON Lines driver
    # protocol. --via-maxscale points that subprocess at the primary
    # --host/--port/--user/--password (MaxScale 3311) and defaults the connector
    # to python_mariadb; plain connector mode uses --maxscale-*/--mariadb-*.
    # NB: python_pymysql can't parse the exasolrouter's OK/non-result-set
    # response packets (USE/SET return "Result: OK" but pymysql drops the
    # connection); MariaDB Connector/Python handles them, so it's the default.
    connector = args.connector
    if args.via_maxscale and connector == "pyexasol":
        connector = "python_mariadb"
    if connector == "pyexasol":
        runner = _PyexasolRunner(c)
    elif connector in _CONNECTOR_RUNNERS:
        if args.via_maxscale:
            mx_host, mx_port = args.host, str(args.port)
            mx_user, mx_pass = args.user, args.password
        else:
            mx_host, mx_port = args.maxscale_host, str(args.maxscale_port)
            mx_user, mx_pass = args.mariadb_user, args.mariadb_password
        interp, script = _CONNECTOR_RUNNERS[connector]
        if connector == "nodejs":
            reason = _node_too_old(interp)
            if reason:
                print(f"[setup] nodejs connector unavailable: {reason}", file=sys.stderr)
                return 3
        runner_dir = Path(__file__).resolve().parent / "connectors" / connector
        cmd = [
            interp, str(runner_dir / script),
            "--host", mx_host,
            "--port", mx_port,
            "--user", mx_user,
            "--password", mx_pass,
        ]
        try:
            runner = _SubprocessRunner(connector, cmd)
            print(f"[setup] connector: {connector} ({runner.driver}) -> "
                  f"{mx_host}:{mx_port}")
            # The runner opens its own DB session over MaxScale, so the
            # SCRIPT_LANGUAGES pin we set on the pyexasol session above
            # does NOT apply here — re-issue it via the runner so UDF/
            # preprocessor calls hit the SLC the user actually requested.
            # Best-effort: ALTER SESSION SET responses also have the
            # rowCount-shaped packet that some connectors (e.g. pymysql via
            # MaxScale + ExasolRouter) can't parse.
            if args.script_language:
                escaped = args.script_language.replace("'", "''")
                stmt = f"ALTER SESSION SET SCRIPT_LANGUAGES='{escaped}'"
                try:
                    runner.execute("__set_script_languages__", stmt)
                    if args.verbose >= 2:
                        print(f"[setup] ({connector}) {stmt}")
                except Exception as e:
                    print(f"[setup] {connector}: SCRIPT_LANGUAGES pin "
                          f"failed ({e}); SLC may not match --script-language",
                          file=sys.stderr)
            # Connector lands in no schema by default; pyexasol pre-OPENs the
            # test schema on its own connection. Send a USE so unqualified
            # table refs in test fixtures resolve here too. Best-effort —
            # some connectors / proxy configs reject the rewritten OPEN SCHEMA
            # response packet (e.g. pymysql via MaxScale + ExasolRouter); if
            # USE fails, table-fixture tests will fail individually but
            # schema-less tests (set_names, sqlglot_native, ...) still run.
            try:
                runner.execute("__use_schema__", f"USE {args.schema}")
            except Exception as e:
                print(f"[setup] {connector}: USE {args.schema} failed "
                      f"({e}); table-fixture tests in this run will fail",
                      file=sys.stderr)
            # Re-probe sqlglot version — the runner's session may be on a
            # different SLC than pyexasol's (different user, different
            # server-side defaults via MaxScale, etc.), so report both. Skipped
            # under --via-maxscale: there the SLC isn't the transpiler (MaxScale
            # is), so its version is reported via the MaxScale probe instead.
            if not args.via_maxscale:
                try:
                    v = runner.execute("__glot_version__", "SELECT UTIL.GET_GLOT_VERSION()")
                    ver = v[0][0] if v and v[0] else "unknown"
                    print(f"[setup] sqlglot in {connector} runner SLC: {ver}")
                except Exception as e:
                    print(f"[setup] sqlglot version probe via {connector} runner failed: {e}",
                          file=sys.stderr)
        except Exception as e:
            print(f"[setup] connector init failed: {e}", file=sys.stderr)
            return 3
    else:
        print(f"[setup] unsupported connector: {connector}", file=sys.stderr)
        return 3

    compare_mode: str | None = None
    if args.compare_direct:
        compare_mode = "direct"
    elif args.compare_with_cdc:
        compare_mode = "cdc"

    mc = None
    started_container = False
    if compare_mode is not None:
        try:
            import pymysql
        except ImportError:
            print(f"[setup] --compare-{compare_mode if compare_mode == 'direct' else 'with-cdc'} "
                  f"needs pymysql: pip install pymysql", file=sys.stderr)
            return 3

        connect_kwargs_my = dict(host=args.mariadb_host, port=args.mariadb_port,
                                 user=args.mariadb_user, password=args.mariadb_password,
                                 autocommit=True, connect_timeout=3)

        if not _port_open(args.mariadb_host, args.mariadb_port):
            # Auto-spawn is meaningful only in --compare-direct: a freshly
            # spawned container has no CDC pipe attached, so spawning under
            # --compare-with-cdc would just produce a misleading probe failure.
            spawn_blocked = (args.no_spawn_mariadb or not _is_local(args.mariadb_host)
                             or compare_mode != "direct")
            if spawn_blocked:
                hint = (" (auto-spawn disabled under --compare-with-cdc)"
                        if compare_mode == "cdc" else "")
                print(f"[setup] mariadb {args.mariadb_host}:{args.mariadb_port} unreachable{hint}",
                      file=sys.stderr)
                return 3
            if not _docker_available():
                print("[setup] mariadb unreachable and docker not available; "
                      "start MariaDB or install docker", file=sys.stderr)
                return 3
            print(f"[setup] no MariaDB on :{args.mariadb_port}; "
                  f"spawning {args.mariadb_image} container...")
            try:
                _start_mariadb_container(args.mariadb_image, args.mariadb_port,
                                         args.mariadb_password)
                started_container = True
            except Exception as e:
                stderr = getattr(e, "stderr", b"")
                detail = stderr.decode(errors="replace") if isinstance(stderr, bytes) else str(stderr)
                print(f"[setup] docker run failed: {e}\n{detail}", file=sys.stderr)
                return 3
            print("[setup] waiting for mariadb to become ready...")
            try:
                mc = _wait_for_mariadb(connect_kwargs_my)
            except Exception as e:
                print(f"[setup] {e}", file=sys.stderr)
                _stop_mariadb_container()
                return 3
        else:
            try:
                mc = pymysql.connect(**connect_kwargs_my)
            except Exception as e:
                print(f"[setup] mariadb connection failed: {e}", file=sys.stderr)
                return 3

        try:
            with mc.cursor() as mcur:
                # In CDC mode the database is shared with the CDC pipe — recreate
                # it on MariaDB and let CDC propagate the schema reset to Exasol.
                mcur.execute(f"DROP DATABASE IF EXISTS {args.schema}")
                mcur.execute(f"CREATE DATABASE {args.schema}")
                mcur.execute(f"USE {args.schema}")
        except Exception as e:
            print(f"[setup] mariadb db init failed: {e}", file=sys.stderr)
            if started_container:
                _stop_mariadb_container()
            return 3

        if compare_mode == "cdc":
            print("[setup] validating CDC pipe MariaDB → Exasol...")
            try:
                _cdc_probe(c, mc, args.schema, timeout=args.cdc_probe_timeout)
            except Exception as e:
                print(f"[setup] CDC probe failed: {e}", file=sys.stderr)
                return 3
            print("[setup] CDC pipe verified.")

    udf_dirs = sorted(d for d in args.tests_dir.iterdir()
                      if d.is_dir() and d.name not in ("__pycache__", "fixtures"))
    if args.udf:
        udf_dirs = [d for d in udf_dirs if d.name in args.udf]

    setup_filenames = {"setup.exasol.sql", "setup.mariadb.sql"}
    passed = failed = 0
    for udf_dir in udf_dirs:
        # Always start each group with the preprocessor OFF so setup SQL is
        # parsed as Exasol-native. Groups that exercise the preprocessor
        # (e.g. maria_preprocessor/) turn it back on in their setup.exasol.sql.
        try:
            c.execute("ALTER SESSION SET sql_preprocessor_script=''")
        except Exception:
            pass

        setup_exasol = udf_dir / "setup.exasol.sql"
        if setup_exasol.exists():
            # In CDC mode we keep only ALTER SESSION lines (e.g. enabling
            # UTIL.MARIA_PREPROCESSOR for the maria_preprocessor group);
            # tables and rows arrive on Exasol via CDC.
            stmts = (_exasol_session_prelude(setup_exasol.read_text())
                     if compare_mode == "cdc"
                     else _split_sql(setup_exasol.read_text()))
            try:
                for stmt in stmts:
                    if args.verbose >= 2:
                        print(f"[setup-exasol] {udf_dir.name}: {stmt}")
                    c.execute(stmt)
            except Exception as e:
                print(f"[FAIL] {udf_dir.name}/setup.exasol: {e}", file=sys.stderr)
                failed += 1
                continue

        setup_mariadb = udf_dir / "setup.mariadb.sql"
        if mc is not None and setup_mariadb.exists():
            setup_text = setup_mariadb.read_text()
            try:
                for stmt in _split_sql(setup_text):
                    if args.verbose >= 2:
                        print(f"[setup-mariadb] {udf_dir.name}: {stmt}")
                    with mc.cursor() as mcur:
                        mcur.execute(stmt)
            except Exception as e:
                print(f"[FAIL] {udf_dir.name}/setup.mariadb: {e}", file=sys.stderr)
                failed += 1
                continue
            if compare_mode == "cdc":
                tables = _parse_create_tables(setup_text)
                if args.verbose:
                    print(f"[cdc-wait] {udf_dir.name}: waiting for {tables} on Exasol "
                          f"(timeout {args.cdc_timeout:g}s)")
                try:
                    _wait_for_cdc_propagation(c, mc, args.schema, tables,
                                              timeout=args.cdc_timeout)
                except Exception as e:
                    print(f"[FAIL] {udf_dir.name}/cdc-wait: {e}", file=sys.stderr)
                    failed += 1
                    continue

        cases = sorted(f for f in udf_dir.glob("*.sql") if f.name not in setup_filenames)
        for sql_file in cases:
            name = sql_file.stem
            expected_file = sql_file.with_suffix(".expected.json")
            if not expected_file.exists():
                print(f"[skip] {udf_dir.name}/{name}: no .expected.json")
                continue
            label = f"{udf_dir.name}/{name}"
            sql_text = sql_file.read_text()
            if args.verbose:
                print(f"[run]  {label}")
                print(f"       sql     : {sql_text.strip()}")
            try:
                rows = runner.execute(label, sql_text)
                expected = json.loads(expected_file.read_text())
            except Exception as e:
                print(f"[FAIL] {label}: {e}", file=sys.stderr)
                failed += 1
                continue

            if [[str(x) for x in r] for r in rows] == [[str(x) for x in r] for r in expected]:
                print(f"[ok]   {label}")
                if args.verbose:
                    print(f"       exasol  : {rows}")
                passed += 1
            else:
                print(f"[FAIL] {label}", file=sys.stderr)
                print(f"       expected: {expected}", file=sys.stderr)
                print(f"       exasol  : {rows}", file=sys.stderr)
                failed += 1

            if mc is not None:
                try:
                    with mc.cursor() as mcur:
                        mcur.execute(sql_text)
                        mrows = [list(r) for r in (mcur.fetchall() or ())]
                    diff = "" if ([[str(x) for x in r] for r in mrows]
                                  == [[str(x) for x in r] for r in rows]) else " (DIFF)"
                    print(f"       mariadb : {mrows}{diff}")
                except Exception as e:
                    print(f"       mariadb : ERROR: {e}")

    runner.close()

    try:
        c.execute("ALTER SESSION SET sql_preprocessor_script=''")
    except Exception:
        pass
    try:
        c.execute(f"DROP SCHEMA {args.schema} CASCADE")
    except Exception:
        pass

    if mc is not None:
        try:
            with mc.cursor() as mcur:
                mcur.execute(f"DROP DATABASE IF EXISTS {args.schema}")
        except Exception:
            pass
        try:
            mc.close()
        except Exception:
            pass
    if started_container:
        print("[setup] removing mariadb container...")
        _stop_mariadb_container()

    total = passed + failed
    print(f"\n{passed}/{total} passed" + (f", {failed} failed" if failed else ""))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
