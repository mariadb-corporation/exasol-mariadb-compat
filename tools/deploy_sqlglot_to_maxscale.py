#!/usr/bin/env python3
"""Deploy a local sqlglot package + this repo's preprocessor into MaxScale, then
restart it.

The preprocessor body is uploaded as sqlglot.custom.<build>.<timestamp>.udf and
maxscale.cnf's `preprocessor=internal:` line is repointed at it, so each deploy
is a distinct, identifiable version rather than an overwrite. install.py does
NOT cover this: it installs into Exasol, while MaxScale runs its own copy.

MaxScale reads the body at process start — stopping/starting the *service*
(maxctrl / REST) does not reload it, so a container restart is required.

  python3 tools/deploy_sqlglot_to_maxscale.py                     # sqlglot + preprocessor + restart
  python3 tools/deploy_sqlglot_to_maxscale.py --preprocessor-only # just the preprocessor
  python3 tools/deploy_sqlglot_to_maxscale.py --no-preprocessor   # just sqlglot (old behaviour)
  python3 tools/deploy_sqlglot_to_maxscale.py --restore           # undo last deploy

  # quick start
  cd ..; git clone git@github.com:tobymao/sqlglot.git; cd sqlglot; git checkout x
  make install   # build + install sqlglot locally; writes sqlglot/_version.py
  cd ../exasol-mariadb-compat; python3 tools/deploy_sqlglot_to_maxscale.py

Afterwards test with maxscale_adhoc_test.py
"""
from __future__ import annotations

import argparse
import ast
import datetime
import pathlib
import re
import subprocess
import sys
import time

SITE_PACKAGES = "/usr/lib64/maxscale/python3/site-packages"
LISTENER_PORT = 3311  # exasol_listener in maxscale.cnf — used for the readiness wait
REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent

# Where versioned preprocessor bodies are uploaded inside the container. Not a
# bind mount, so these are lost if the container is *recreated* (compose
# down/up) though they survive a restart -- see deploy_preprocessor().
PREPROC_DIR = "/var/lib/maxscale/preproc"
PREPROC_SRC = REPO_ROOT / "preprocessor" / "maria_preprocessor.py"
CNF_DEST = "/etc/maxscale.cnf"
# preprocessor=internal:/path — the line that selects the active body.
CNF_PREPROC_RE = re.compile(r"^(\s*preprocessor\s*=\s*internal:)(\S+)\s*$", re.M)


def _container_python(container: str) -> str:
    """Resolve the container's python3 binary (the image version drifts, e.g.
    3.12 -> 3.13), falling back to the newest /usr/bin/python3.* if there is no
    bare python3 on PATH."""
    r = subprocess.run(
        ["docker", "exec", container, "sh", "-c",
         "command -v python3 || ls -1 /usr/bin/python3.[0-9]* 2>/dev/null | "
         "grep -E '/python3\\.[0-9]+$' | sort -V | tail -1"],
        capture_output=True, text=True)
    return r.stdout.strip() or "python3"


def _dexec_root(container: str, sh: str):
    """Run a shell snippet in the container as root (site-packages isn't writable
    by the default `maxscale` exec user)."""
    return subprocess.run(["docker", "exec", "-u", "0", container, "sh", "-c", sh],
                          capture_output=True, text=True)


def _container_version(container: str) -> str:
    r = subprocess.run(
        ["docker", "exec", "-e", f"PYTHONPATH={SITE_PACKAGES}",
         container, _container_python(container), "-c", "import sqlglot; print(sqlglot.__version__)"],
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


def _mount_source(container: str, dest: str) -> pathlib.Path | None:
    """Host path backing a bind mount, so bind-mounted files can be edited from
    the host. Editing them in-container fails: docker cp and `sed -i` both
    replace the inode, and unlinking a mount target gives EBUSY."""
    r = subprocess.run(
        ["docker", "inspect", container, "--format",
         "{{range .Mounts}}{{.Destination}}\t{{.Source}}\n{{end}}"],
        capture_output=True, text=True)
    for line in r.stdout.splitlines():
        if "\t" in line:
            d, s = line.split("\t", 1)
            if d.strip() == dest:
                return pathlib.Path(s.strip())
    return None


def _canonical_udf_dest(container: str) -> str | None:
    """The bind-mounted *.udf path. Unlike the versioned copies under
    PREPROC_DIR it survives `compose down/up`, so it is the safe fallback."""
    r = subprocess.run(
        ["docker", "inspect", container, "--format",
         "{{range .Mounts}}{{.Destination}}\n{{end}}"], capture_output=True, text=True)
    return next((d.strip() for d in r.stdout.splitlines() if d.strip().endswith(".udf")), None)


def _preprocessor_body() -> tuple[str, str]:
    """(python body, build tag) from the repo's preprocessor. The source is
    header-less (no Exasol `CREATE ... PREPROCESSOR SCRIPT ... AS` line), which
    MaxScale's internal preprocessor must not see; the strip below is a guard."""
    text = PREPROC_SRC.read_text()
    body = text.split("\n", 1)[1] if text.startswith("CREATE") else text
    ast.parse(body)  # never ship a body that cannot even parse
    if "def adapter_call" not in body:
        raise ValueError(f"{PREPROC_SRC} defines no adapter_call()")
    m = re.search(r'^_PREPROCESSOR_BUILD\s*=\s*"([^"]+)"', body, re.M)
    return body, (m.group(1) if m else "unknown")


def deploy_preprocessor(container: str) -> tuple[int, pathlib.Path | None, str | None]:
    """Upload the repo's preprocessor body under a build+timestamp name and point
    maxscale.cnf at it. Returns (rc, cnf_host_path, previous_target) so the
    caller can roll the config back if MaxScale fails to come up.

    The canonical bind-mounted .udf is refreshed with the same content too: the
    versioned copies live only in the container, so if it is ever recreated the
    host-side cnf would point at a path that no longer exists. Keeping the mount
    current means --restore can always fall back to something real.
    """
    try:
        body, build = _preprocessor_body()
    except (OSError, SyntaxError, ValueError) as e:
        print(f"[deploy] preprocessor source unusable: {e}", file=sys.stderr)
        return 3, None, None

    cnf_host = _mount_source(container, CNF_DEST)
    if cnf_host is None or not cnf_host.exists():
        print(f"[deploy] {CNF_DEST} is not a bind mount; cannot repoint it", file=sys.stderr)
        return 3, None, None
    cnf_text = cnf_host.read_text()
    m = CNF_PREPROC_RE.search(cnf_text)
    if not m:
        print(f"[deploy] no `preprocessor=internal:` line in {cnf_host}", file=sys.stderr)
        return 3, None, None
    previous = m.group(2)

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    target = f"{PREPROC_DIR}/sqlglot.custom.{build}.{stamp}.udf"

    _dexec_root(container, f"mkdir -p {PREPROC_DIR}")
    up = subprocess.run(["docker", "exec", "-u", "0", "-i", container, "sh", "-c",
                         f"cat > {target}"], input=body, text=True, capture_output=True)
    if up.returncode != 0:
        print(f"[deploy] upload failed: {up.stderr.strip()}", file=sys.stderr)
        return 3, None, None
    _dexec_root(container, f"chmod a+r {target}")
    print(f"[deploy] preproc: uploaded {target} (build {build}, {len(body.splitlines())} lines)")

    # Refresh the bind-mounted copy in place -- write through, never unlink.
    # Located from the mount table, not from `previous`: once cnf is pinned to a
    # versioned path `previous` is no longer a mount, and keying off it would
    # silently stop refreshing the one copy that survives a container recreate.
    canon = _mount_source(container, _canonical_udf_dest(container) or "")
    if canon and canon.exists():
        canon.write_text(body)
        print(f"[deploy] preproc: refreshed mounted {canon.name} to the same build")

    cnf_host.write_text(CNF_PREPROC_RE.sub(lambda mm: mm.group(1) + target, cnf_text, count=1))
    print(f"[deploy] preproc: {cnf_host.name} now points at {target} (was {previous})")
    return 0, cnf_host, previous


def _repoint_cnf(cnf_host: pathlib.Path, target: str) -> None:
    text = cnf_host.read_text()
    cnf_host.write_text(CNF_PREPROC_RE.sub(lambda mm: mm.group(1) + target, text, count=1))


def _preproc_ok(container: str, cnf_host: pathlib.Path) -> bool:
    """The configured body must exist in the container, or MaxScale starts
    without a preprocessor and every rewritten statement silently passes through."""
    m = CNF_PREPROC_RE.search(cnf_host.read_text())
    if not m:
        return False
    return _dexec_root(container, f"[ -r {m.group(2)} ]").returncode == 0


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
    # Restarting is the caller's job: the preprocessor half is deployed after
    # this, and one restart should pick up both.
    if restart:
        _restart_and_wait(container)
        print(f"[deploy] loaded : sqlglot in {container} = {_container_version(container)}")
    return 0


def restore(container: str, restart: bool) -> int:
    # Un-pin the config first: point it back at the bind-mounted .udf, which
    # survives container recreation, rather than a versioned copy that does not.
    cnf_host = _mount_source(container, CNF_DEST)
    if cnf_host is not None and cnf_host.exists():
        m = CNF_PREPROC_RE.search(cnf_host.read_text())
        canon = _canonical_udf_dest(container)
        if m and canon and m.group(2) != canon:
            _repoint_cnf(cnf_host, canon)
            print(f"[deploy] preproc: {cnf_host.name} repointed back to {canon}")

    dst = f"{SITE_PACKAGES}/sqlglot"
    if _dexec_root(container, f"[ -e {dst}.bak ]").returncode != 0:
        print(f"[deploy] no {dst}.bak to restore", file=sys.stderr)
        if restart:
            _restart_and_wait(container)
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
    ap.add_argument("--no-preprocessor", action="store_true",
                    help="deploy sqlglot only; leave the preprocessor body and maxscale.cnf alone")
    ap.add_argument("--preprocessor-only", action="store_true",
                    help="deploy the preprocessor body + repoint maxscale.cnf; skip the sqlglot package")
    args = ap.parse_args()
    try:
        if args.restore:
            return restore(args.container, restart=not args.no_restart)

        rc = 0
        # Both halves are copied first, then a single restart picks them up
        # together: MaxScale reads the preprocessor body at process start, so
        # stopping/starting the service alone does NOT reload it.
        if not args.preprocessor_only:
            rc = deploy(args.source.resolve(), args.container, restart=False)
            if rc:
                return rc

        cnf_host = previous = None
        if not args.no_preprocessor:
            rc, cnf_host, previous = deploy_preprocessor(args.container)
            if rc:
                return rc

        if args.no_restart:
            print("[deploy] --no-restart: MaxScale keeps the OLD module and preprocessor "
                  "until it is restarted")
            return 0

        _restart_and_wait(args.container)
        print(f"[deploy] loaded : sqlglot in {args.container} = "
              f"{_container_version(args.container)}")

        if cnf_host is not None and not _preproc_ok(args.container, cnf_host):
            print("[deploy] configured preprocessor body is missing -- rolling "
                  f"maxscale.cnf back to {previous}", file=sys.stderr)
            _repoint_cnf(cnf_host, previous)
            _restart_and_wait(args.container)
            return 2
        return rc
    except FileNotFoundError:
        print("docker not found on PATH", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
