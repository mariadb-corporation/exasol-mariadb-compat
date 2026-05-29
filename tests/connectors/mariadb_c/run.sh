#!/usr/bin/env bash
# Wrapper that compiles runner.c against MariaDB Connector/C (libmariadb) on
# first run, then exec's it. run_tests.py invokes this the same way it invokes
# the node/python runners — args after this script are passed to the binary.
# Needs a C compiler and the Connector/C dev package (mariadb_config) on PATH.
set -euo pipefail
cd "$(dirname "$0")"

BIN=runner
if [ ! -x "$BIN" ] || [ runner.c -nt "$BIN" ]; then
    # mariadb_config output is intentionally word-split (compiler flags).
    cc -O2 -Wall -o "$BIN" runner.c $(mariadb_config --cflags) $(mariadb_config --libs) >&2
fi

exec ./"$BIN" "$@"
