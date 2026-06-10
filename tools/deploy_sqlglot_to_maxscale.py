#!/usr/bin/env python3
"""Deploy a local sqlglot package into the MaxScale container, then restart it.

  python3 tools/deploy_sqlglot_to_maxscale.py              # deploy ../sqlglot/sqlglot + restart
  python3 tools/deploy_sqlglot_to_maxscale.py --restore    # undo last deploy

  # quick start
  cd ..; git clone git@github.com:tobymao/sqlglot.git; cd sqlglot; git checkout x
  make install   # build + install sqlglot locally; writes sqlglot/_version.py
  cd ../exasol-mariadb-compat; python3 tools/deploy_sqlglot_to_maxscale.py

Afterwards test with maxscale_adhoc_test.py
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys
import time

SITE_PACKAGES = "/usr/lib64/maxscale/python3/site-packages"
CONTAINER_PYTHON = "/usr/bin/python3.12"
LISTENER_PORT = 3311  # exasol_listener in maxscale.cnf — used for the readiness wait
REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent


def _dexec_root(container: str, sh: str):
    """Run a shell snippet in the container as root (site-packages isn't writable
    by the default `maxscale` exec user)."""
    return subprocess.run(["docker", "exec", "-u", "0", container, "sh", "-c", sh],
                          capture_output=True, text=True)


def _container_version(container: str) -> str:
    r = subprocess.run(
        ["docker", "exec", "-e", f"PYTHONPATH={SITE_PACKAGES}",
         container, CONTAINER_PYTHON, "-c", "import sqlglot; print(sqlglot.__version__)"],
        capture_output=True, text=True)
    if r.returncode == 0 and r.stdout.strip():
        return r.stdout.strip()
    return f"(probe failed: {(r.stderr or r.stdout).strip() or 'no output'})"


def _restart_and_wait(container: str) -> None:
    print(f"[deploy] restarting {container}...")
    if subprocess.run(["docker", "restart", container], capture_output=True).returncode != 0:
        print("[deploy] restart failed", file=sys.stderr)
        return
    probe = f"exec 3<>/dev/tcp/127.0.0.1/{LISTENER_PORT}"
    for i in range(1, 31):
        if subprocess.run(["docker", "exec", container, "sh", "-c", probe],
                          capture_output=True).returncode == 0:
            print(f"[deploy] :{LISTENER_PORT} up after {i}s")
            return
        time.sleep(1)
    print(f"[deploy] warning: :{LISTENER_PORT} not up within 30s", file=sys.stderr)


def deploy(source: pathlib.Path, container: str, restart: bool) -> int:
    if not (source / "__init__.py").exists():
        print(f"[deploy] {source} is not a sqlglot package (no __init__.py)", file=sys.stderr)
        return 3
    dst = f"{SITE_PACKAGES}/sqlglot"
    print(f"[deploy] source : {source}")
    print(f"[deploy] before : sqlglot in {container} = {_container_version(container)}")
    # Preserve the pristine image version once as sqlglot.orig (seed it from an
    # existing sqlglot.bak if that's the only original we have), then roll the
    # current copy to sqlglot.bak for one-step --restore. Finally clean-copy the
    # new package in — cp into an existing dir would nest it (sqlglot/sqlglot).
    _dexec_root(container,
                f"[ -e {dst}.orig ] || {{ [ -e {dst}.bak ] && cp -a {dst}.bak {dst}.orig; }} || true; "
                f"[ -e {dst}.orig ] || {{ [ -e {dst} ] && cp -a {dst} {dst}.orig; }} || true; "
                f"rm -rf {dst}.bak; [ -e {dst} ] && mv {dst} {dst}.bak || true")
    if subprocess.run(["docker", "cp", str(source), f"{container}:{dst}"]).returncode != 0:
        print("[deploy] docker cp failed", file=sys.stderr)
        return 3
    _dexec_root(container, f"chmod -R a+rX {dst}")
    print(f"[deploy] copied : sqlglot in {container} = {_container_version(container)} "
          f"(backup at {dst}.bak)")
    if restart:
        _restart_and_wait(container)
        print(f"[deploy] loaded : sqlglot in {container} = {_container_version(container)}")
    else:
        print("[deploy] --no-restart: MaxScale keeps the OLD module until it is restarted")
    return 0


def restore(container: str, restart: bool) -> int:
    dst = f"{SITE_PACKAGES}/sqlglot"
    if _dexec_root(container, f"[ -e {dst}.bak ]").returncode != 0:
        print(f"[deploy] no {dst}.bak to restore", file=sys.stderr)
        return 3
    _dexec_root(container, f"rm -rf {dst} && mv {dst}.bak {dst}")
    print(f"[deploy] restored: sqlglot in {container} = {_container_version(container)}")
    if restart:
        _restart_and_wait(container)
        print(f"[deploy] loaded : sqlglot in {container} = {_container_version(container)}")
    return 0


def main() -> int:
    def _fmt(prog):
        # wider help column so e.g. `--container CONTAINER` keeps its help on
        # the same line instead of wrapping
        return argparse.RawDescriptionHelpFormatter(prog, max_help_position=32)

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=_fmt)
    ap.add_argument("--source", type=pathlib.Path,
                    default=REPO_ROOT.parent / "sqlglot" / "sqlglot",
                    help="local sqlglot package dir to deploy (default: ../sqlglot/sqlglot)")
    ap.add_argument("--container", default="maxscale",
                    help="MaxScale container name (default: maxscale)")
    ap.add_argument("--no-restart", action="store_true",
                    help="copy only; don't restart MaxScale (old module stays loaded)")
    ap.add_argument("--restore", action="store_true",
                    help="restore the previous copy (sqlglot.bak) instead of deploying")
    args = ap.parse_args()
    try:
        if args.restore:
            return restore(args.container, restart=not args.no_restart)
        return deploy(args.source.resolve(), args.container, restart=not args.no_restart)
    except FileNotFoundError:
        print("docker not found on PATH", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
