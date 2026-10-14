#!/usr/bin/env python3
"""Run the MARIA_PREPROCESSOR rewrite locally — outside Exasol — to eyeball
the MariaDB SQL going in and the Exasol SQL coming out.

  echo 'SELECT FIELD(x,"a","b") FROM t' | python3 local_adhoc_test.py
  python3 local_adhoc_test.py path/to/query.sql
  python3 local_adhoc_test.py --safe < query.sql   # use non-DEBUG variant

Uses whichever sqlglot is on the local PYTHONPATH (pip install -e ../sqlglot
to test fork changes).
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

PREPROCESSOR_DIR = pathlib.Path(__file__).resolve().parent.parent / "preprocessor"


def load_adapter(safe: bool):
    fname = "maria_preprocessor.py" if safe else "maria_preprocessor_debug.sql"
    body = (PREPROCESSOR_DIR / fname).read_text()
    if not safe:
        body = body.split(" AS\n", 1)[1]  # drop the CREATE ... AS header
    ns: dict = {}
    exec(compile(body, fname, "exec"), ns)
    return ns["adapter_call"]


def sqlglot_banner() -> str:
    import sqlglot
    path = pathlib.Path(sqlglot.__file__).resolve().parent
    parts = [f"sqlglot {sqlglot.__version__} @ {path}"]
    try:
        commit = subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "--short", "HEAD"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        dirty = subprocess.check_output(
            ["git", "-C", str(path), "status", "--porcelain"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        branch = subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "--abbrev-ref", "HEAD"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        parts.append(f"git {branch}@{commit}{'-dirty' if dirty else ''}")
    except (subprocess.CalledProcessError, FileNotFoundError):
        parts.append("(not a git checkout)")
    return " | ".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="example:\n  echo 'SELECT FIELD(x,\"a\",\"b\") FROM t' | python3 tools/local_adhoc_test.py")
    ap.add_argument("file", nargs="?", help="SQL file (default: stdin)")
    ap.add_argument("--safe", action="store_true",
                    help="use MARIA_PREPROCESSOR (swallows errors) instead of _DEBUG")
    args = ap.parse_args()

    sql = pathlib.Path(args.file).read_text() if args.file else sys.stdin.read()
    adapter_call = load_adapter(safe=args.safe)

    print(f"---- SQLGLOT ---- {sqlglot_banner()}")
    print("---- INPUT  ----")
    print(sql.rstrip())
    print("---- OUTPUT ----")
    print(adapter_call(sql))
    return 0


if __name__ == "__main__":
    sys.exit(main())
