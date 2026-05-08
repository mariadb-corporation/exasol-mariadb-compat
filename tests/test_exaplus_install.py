#!/usr/bin/env python3
"""Smoke test: install dist/mariadb-compat.sql via `exaplus -f` against a
running Exasol container, then verify the expected 8 of 9 UTIL.* scripts
landed. Pins the exaplus path to its known-good behavior so we'd catch a
regression that drops a SCALAR UDF or the production MARIA_PREPROCESSOR.

Why 8, not 9: exaplus 25.2.6 has a client-side parser bug — after the
first `--/ ... /` PREPROCESSOR block, subsequent `--/` markers no longer
enter script-body mode and the next script's body is silently dropped.
The bundle orders MARIA_PREPROCESSOR (production) before
MARIA_PREPROCESSOR_DEBUG (dev-only) so production survives. Users who
need DEBUG run install.py instead.

Requires: pyexasol, plus a Docker-running Exasol container that ships
exaplus inside it (default name: exasoldb). Skips with a clear message
if either is missing.
"""
from __future__ import annotations

import argparse
import shutil
import ssl
import subprocess
import sys
from pathlib import Path

EXAPLUS_PATH = "/opt/exasol/db-2025.2.1/bin/Console/exaplus"
EXPECTED_VIA_EXAPLUS = {
    "JSON_EXTRACT", "JSON_MERGE_PRESERVE", "JSON_OBJECT", "JSON_UNQUOTE",
    "GET_GLOT_VERSION", "ELT", "FIELD", "MARIA_PREPROCESSOR",
}


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--container", default="exasoldb",
                   help="Docker container running Exasol (default: exasoldb)")
    p.add_argument("--exaplus", default=EXAPLUS_PATH,
                   help=f"Path to exaplus inside the container (default: {EXAPLUS_PATH})")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", default="8563")
    p.add_argument("--user", default="sys")
    p.add_argument("--password", default="exasol")
    p.add_argument("--bundle", type=Path,
                   default=Path(__file__).resolve().parent.parent / "dist" / "mariadb-compat.sql")
    args = p.parse_args()

    if not shutil.which("docker"):
        print("[skip] docker not installed", file=sys.stderr)
        return 77
    try:
        import pyexasol
    except ImportError:
        print("[skip] pyexasol not installed", file=sys.stderr)
        return 77

    if not args.bundle.exists():
        print(f"[fail] bundle {args.bundle} missing — run ./build.sh", file=sys.stderr)
        return 1

    inspect = subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}", args.container],
                             capture_output=True, text=True)
    if inspect.returncode != 0 or inspect.stdout.strip() != "true":
        print(f"[skip] container {args.container!r} not running", file=sys.stderr)
        return 77

    c = pyexasol.connect(dsn=f"{args.host}:{args.port}", user=args.user,
                         password=args.password, compression=True,
                         websocket_sslopt={"cert_reqs": ssl.CERT_NONE})
    c.execute("DROP SCHEMA IF EXISTS UTIL CASCADE")

    container_path = "/tmp/mariadb-compat-smoke.sql"
    cp = subprocess.run(["docker", "cp", str(args.bundle),
                         f"{args.container}:{container_path}"],
                        capture_output=True, text=True)
    if cp.returncode != 0:
        print(f"[fail] docker cp: {cp.stderr.strip()}", file=sys.stderr)
        return 1

    # exaplus runs inside the container connecting to localhost; its JDBC
    # client requires the TLS fingerprint pinned in the connection string.
    # Pull it from the live cert via openssl (already on the Exasol image).
    fp = subprocess.run(["docker", "exec", args.container, "sh", "-c",
                         "openssl s_client -connect localhost:8563 -showcerts </dev/null 2>/dev/null "
                         "| openssl x509 -fingerprint -sha256 -noout"],
                        capture_output=True, text=True)
    fingerprint = None
    if fp.returncode == 0 and "Fingerprint=" in fp.stdout:
        fingerprint = fp.stdout.split("Fingerprint=", 1)[1].strip().replace(":", "")
    conn = (f"localhost/{fingerprint}:{args.port}" if fingerprint
            else f"localhost:{args.port}")

    run = subprocess.run(["docker", "exec", args.container, args.exaplus,
                          "-c", conn, "-u", args.user, "-p", args.password,
                          "-f", container_path],
                         capture_output=True, text=True)
    if run.returncode not in (0, 1):
        print(f"[fail] exaplus exit {run.returncode}: {run.stderr.strip()}", file=sys.stderr)
        return 1

    rows = c.execute("SELECT script_name FROM EXA_ALL_SCRIPTS "
                     "WHERE script_schema='UTIL' ORDER BY script_name").fetchall()
    installed = {r[0] for r in rows}
    missing = EXPECTED_VIA_EXAPLUS - installed
    extra = installed - EXPECTED_VIA_EXAPLUS - {"MARIA_PREPROCESSOR_DEBUG"}

    if missing:
        print(f"[fail] exaplus install missing scripts: {sorted(missing)}", file=sys.stderr)
        print(f"       installed: {sorted(installed)}", file=sys.stderr)
        print("---- exaplus stdout ----", file=sys.stderr)
        print(run.stdout, file=sys.stderr)
        return 1
    if extra:
        print(f"[warn] unexpected extra scripts in UTIL: {sorted(extra)}", file=sys.stderr)

    print(f"[ok] exaplus -f installed all {len(EXPECTED_VIA_EXAPLUS)} expected scripts: "
          f"{sorted(EXPECTED_VIA_EXAPLUS)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
