#!/usr/bin/env python3
"""Run the MariaDB→Exasol rewrite as it happens *inside the MaxScale container*
— exec into MaxScale, report its sqlglot version, and transpile custom SQL with
the container's own maria_preprocessor (the exasolrouter's `adapter_call`).

This is the MaxScale-side counterpart to standalone_adhoc_test.py: instead of
the local fork + the in-repo preprocessor SQL, it uses MaxScale's bundled
sqlglot (/usr/lib64/maxscale/python3/site-packages) and the deployed
/usr/share/maxscale/maria_preprocessor.py, so you see exactly what the router
emits — UTIL rewrites, identify=True quoting and all.

  echo 'SELECT FIELD(x,"a","b") FROM t' | python3 maxscale_adhoc_test.py
  python3 maxscale_adhoc_test.py path/to/query.sql
  python3 maxscale_adhoc_test.py --safe < query.sql      # adapter_call (swallows errors)
  python3 maxscale_adhoc_test.py --container my_maxscale < query.sql

Requires the MaxScale container to be running and docker on PATH.
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

# Container paths (where MaxScale keeps its python + the deployed preprocessor).
SITE_PACKAGES = "/usr/lib64/maxscale/python3/site-packages"
PREPROCESSOR_DIR = "/usr/share/maxscale"
CONTAINER_PYTHON = "/usr/bin/python3.12"

# Runs inside the container. Everything is passed via env vars so no SQL or
# path ever has to be escaped into this program string.
CONTAINER_PROGRAM = r"""
import os, sys, pathlib
sys.path.insert(0, os.environ["ADHOC_PRE_DIR"])
import sqlglot
print("---- SQLGLOT ---- sqlglot %s @ %s" % (
    sqlglot.__version__, pathlib.Path(sqlglot.__file__).resolve().parent))
import maria_preprocessor as mp
sql = os.environ.get("ADHOC_SQL", "")
print("---- INPUT  ----")
print(sql.rstrip())
print("---- OUTPUT ----")
fn = mp.adapter_call if os.environ.get("ADHOC_SAFE") == "1" else mp._transpile
print(fn(sql))
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("file", nargs="?", help="SQL file (default: stdin)")
    ap.add_argument("--safe", action="store_true",
                    help="use adapter_call (swallows errors, returns input on failure) "
                         "instead of _transpile (raises so you see the error)")
    ap.add_argument("--container", default="maxscale",
                    help="MaxScale container name (default: maxscale)")
    args = ap.parse_args()

    sql = pathlib.Path(args.file).read_text() if args.file else sys.stdin.read()

    cmd = [
        "docker", "exec",
        "-e", f"PYTHONPATH={SITE_PACKAGES}",
        "-e", f"ADHOC_PRE_DIR={PREPROCESSOR_DIR}",
        "-e", f"ADHOC_SQL={sql}",
        "-e", f"ADHOC_SAFE={'1' if args.safe else '0'}",
        args.container, CONTAINER_PYTHON, "-c", CONTAINER_PROGRAM,
    ]
    try:
        return subprocess.run(cmd).returncode
    except FileNotFoundError:
        print("docker not found on PATH", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
