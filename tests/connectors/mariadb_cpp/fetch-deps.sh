#!/usr/bin/env bash
# Install MariaDB Connector/C++ from source (no RHEL/Rocky repo ships it; the
# Enterprise repos carry only Connector/C). Builds against the system
# Connector/C and installs to /usr/local, which run.sh's default paths expect.
# Needs root for the dnf/install steps. Override CONNCPP_TAG to pin a version.
set -euo pipefail

CONNCPP_TAG="${CONNCPP_TAG:-$(curl -s https://api.github.com/repos/mariadb-corporation/mariadb-connector-cpp/releases/latest \
    | grep -oP '"tag_name":\s*"\K[^"]+')}"
SRC="${SRC:-/tmp/mariadb-connector-cpp}"

echo "Installing build deps (cmake, openssl-devel, gcc-c++, Connector/C dev)..."
dnf install -y cmake openssl-devel gcc-c++ mariadb-connector-c-devel

echo "Cloning mariadb-connector-cpp @ ${CONNCPP_TAG}..."
rm -rf "$SRC"
git clone --quiet --depth 1 --branch "$CONNCPP_TAG" --recurse-submodules \
    --shallow-submodules https://github.com/mariadb-corporation/mariadb-connector-cpp.git "$SRC"

echo "Building + installing to /usr/local..."
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$SRC/build" -j "$(nproc)"
cmake --install "$SRC/build"
ldconfig || true

echo "Done. libmariadbcpp + headers under /usr/local (include/mariadb, lib64/mariadb)."
