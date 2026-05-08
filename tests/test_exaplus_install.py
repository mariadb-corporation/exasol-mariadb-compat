#!/usr/bin/env python3
"""Smoke test: install dist/mariadb-compat.sql via `exaplus -f` against a
running Exasol container, then verify all 9 UTIL.* scripts land AND each
has a non-truncated body. The body-length check is what catches the
exaplus 25.2.6 PREPROCESSOR-script bug: the script name appears in
EXA_ALL_SCRIPTS but the body stops at the first `;` (or unbalanced `'`)
in a Python comment, so existence-only checks pass while the rewrites
silently no-op.

Build.sh sanitizes preprocessor bodies for the bundle (strips comment-only
lines, omits --/ markers, terminates with bare `;`), so the bundled body
is shorter than the source — we compare each installed script against the
*bundled* body length, not the original source.

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
    "GET_GLOT_VERSION", "ELT", "FIELD",
    "MARIA_PREPROCESSOR", "MARIA_PREPROCESSOR_DEBUG",
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

    rows = c.execute("SELECT script_name, LENGTH(script_text) FROM EXA_ALL_SCRIPTS "
                     "WHERE script_schema='UTIL' ORDER BY script_name").fetchall()
    installed = {r[0]: r[1] for r in rows}
    missing = EXPECTED_VIA_EXAPLUS - installed.keys()

    if missing:
        print(f"[fail] exaplus install missing scripts: {sorted(missing)}", file=sys.stderr)
        print(f"       installed: {sorted(installed)}", file=sys.stderr)
        print("---- exaplus stdout ----", file=sys.stderr)
        print(run.stdout, file=sys.stderr)
        return 1

    # Body-length check: the catalog SCRIPT_TEXT must be at least as long as
    # the script's section in the bundle (minus the SQL comment header and
    # block delimiters). If a body got truncated at a `;`/`'` in a Python
    # comment, this catches it.
    bundle = args.bundle.read_text()
    expected_lengths = _bundled_body_lengths(bundle)
    truncated = []
    for name in sorted(EXPECTED_VIA_EXAPLUS):
        want = expected_lengths.get(name, 0)
        got = installed[name]
        # Allow modest formatting differences (Exasol normalizes whitespace
        # in CREATE-statement headers); flag anything below 80% of expected.
        if want and got < want * 0.8:
            truncated.append((name, got, want))
    if truncated:
        print("[fail] exaplus install produced truncated bodies:", file=sys.stderr)
        for name, got, want in truncated:
            print(f"  {name}: catalog={got}B, bundle expected ~{want}B", file=sys.stderr)
        return 1

    print(f"[ok] exaplus -f installed all {len(EXPECTED_VIA_EXAPLUS)} expected scripts "
          f"with full bodies: {sorted(EXPECTED_VIA_EXAPLUS)}")
    return 0


def _bundled_body_lengths(bundle: str) -> dict[str, int]:
    """Map script name → length of its CREATE statement in the bundle, so we
    can compare against catalog SCRIPT_TEXT and catch silent truncation."""
    import re
    out = {}
    # Bundle sections look like:
    #   -- === <relpath> ===
    #   [--/]
    #   CREATE [OR REPLACE] ... SCRIPT [UTIL.]<NAME>...
    #   <body>
    #   [/ or ;]
    sections = re.split(r"^-- === [^\n]+ ===\n", bundle, flags=re.M)
    for section in sections[1:]:
        m = re.search(r"CREATE\s+(?:OR\s+REPLACE\s+)?[A-Z0-9 ]+SCRIPT\s+(?:UTIL\.)?(\w+)",
                      section, re.I)
        if not m:
            continue
        # Strip leading `--/` and trailing `/` or `;` block-marker lines
        body = re.sub(r"^--/\n", "", section)
        body = re.sub(r"\n[/;]\s*\n.*$", "", body, flags=re.S)
        out[m.group(1).upper()] = len(body)
    return out


if __name__ == "__main__":
    sys.exit(main())
