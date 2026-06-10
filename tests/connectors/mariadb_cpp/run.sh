#!/usr/bin/env bash
# Wrapper that compiles runner.cpp against MariaDB Connector/C++ (libmariadbcpp)
# on first run, then exec's it. run_tests.py invokes this the same way it
# invokes the other runners — args after this script are passed to the binary.
# Needs a C++ compiler and Connector/C++ installed; override the install paths
# via CONNCPP_INCLUDE / CONNCPP_LIBDIR if it's not under /usr/local. See
# fetch-deps.sh for a source-build install.
set -euo pipefail
cd "$(dirname "$0")"

BIN=runner
INC="${CONNCPP_INCLUDE:-/usr/local/include/mariadb}"
LIBDIR="${CONNCPP_LIBDIR:-/usr/local/lib64/mariadb}"
if [ ! -x "$BIN" ] || [ runner.cpp -nt "$BIN" ]; then
    g++ -std=c++17 -O2 -o "$BIN" runner.cpp \
        -I"$INC" -L"$LIBDIR" -lmariadbcpp -Wl,-rpath,"$LIBDIR" >&2
fi

exec ./"$BIN" "$@"
