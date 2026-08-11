#!/usr/bin/env python3
"""Install the UTIL.* MariaDB-compat UDFs into an Exasol database.

Scans udfs/**, preprocessor/** and views/**/*.sql recursively and runs each as a
single CREATE OR REPLACE.
Idempotent — safe to re-run to update existing UDFs.

Install: pip install pyexasol
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    import pyexasol
except ImportError:
    sys.stderr.write("pyexasol is required: pip install pyexasol\n")
    sys.exit(3)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default="localhost")
    p.add_argument("--port", default="8563")
    p.add_argument("--user", default="sys")
    p.add_argument("--password", default="exasol")
    p.add_argument("--no-ssl-verify", action="store_true",
                   help="Skip Exasol TLS cert validation (for docker-db's self-signed cert)")
    p.add_argument("--udfs-dir", type=Path, default=Path(__file__).parent / "udfs",
                   help="Root directory to scan for UDF *.sql files (default: ./udfs)")
    p.add_argument("--preprocessor-dir", type=Path,
                   default=Path(__file__).parent / "preprocessor",
                   help="Root directory to scan for preprocessor *.sql files (default: ./preprocessor)")
    p.add_argument("--views-dir", type=Path, default=Path(__file__).parent / "views",
                   help="Root directory to scan for view *.sql files (default: ./views)")
    args = p.parse_args()

    sql_files = sorted(args.udfs_dir.rglob("*.sql"))
    if args.preprocessor_dir.exists():
        sql_files.extend(sorted(args.preprocessor_dir.rglob("*.sql")))
    if args.views_dir.exists():
        sql_files.extend(sorted(args.views_dir.rglob("*.sql")))
    if not sql_files:
        print(f"[warn] no .sql files found under {args.udfs_dir} or {args.preprocessor_dir}", file=sys.stderr)
        return 0

    connect_kwargs = dict(dsn=f"{args.host}:{args.port}", user=args.user,
                          password=args.password, compression=True)
    if args.no_ssl_verify:
        import ssl
        connect_kwargs["websocket_sslopt"] = {"cert_reqs": ssl.CERT_NONE}

    try:
        c = pyexasol.connect(**connect_kwargs)
    except Exception as e:
        print(f"[setup] connection failed: {e}", file=sys.stderr)
        return 3

    for schema in ("UTIL", "INFORMATION_SCHEMA"):
        try:
            c.execute(f"CREATE SCHEMA IF NOT EXISTS {schema}")
        except Exception as e:
            print(f"[setup] CREATE SCHEMA {schema} failed: {e}", file=sys.stderr)
            return 3

    repo_root = Path(__file__).parent.resolve()
    for f in sql_files:
        try:
            rel = f.resolve().relative_to(repo_root)
        except ValueError:
            rel = f
        stmt = f.read_text().strip().rstrip(";")
        try:
            c.execute(stmt)
            print(f"[ok] installed {rel}")
        except Exception as e:
            print(f"[fail] {rel}: {e}", file=sys.stderr)
            return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
