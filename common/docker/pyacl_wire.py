#!/usr/bin/env python3
"""Locate CANN's pyACL, put it on sys.path for good, and prove `import acl`.

    python3 pyacl_wire.py --install   wire it up (build time, needs write access)
    python3 pyacl_wire.py --check     report only  (run time, read-only)

WHAT pyACL IS AND WHY IT IS NOT A PIP PACKAGE
---------------------------------------------
`acl` is the Python binding CANN ships with the toolkit, built against that
exact release's libascendcl.so. It is installed under the toolkit tree, not
into the interpreter, and there is no wheel for it - anything on PyPI called
"acl" is an unrelated project. Installing one would shadow the real module with
something that cannot talk to an NPU, so this script never installs anything:
it finds what the toolkit already put on disk and makes the interpreter see it.

WHY IT MATTERS ON THIS IMAGE
----------------------------
vllm-ascend imports it unconditionally on the inference path:

    vllm_ascend/device_allocator/camem.py:27
        from acl.rt import memcpy

at module scope, for the CANN-mem sleep-mode allocator. A missing pyACL is an
ImportError during engine start-up, not a degraded mode.

WHY A .pth AND NOT JUST PYTHONPATH
----------------------------------
The Dockerfile does set PYTHONPATH, and that is the primary wiring. But it is a
single environment string: `docker run -e PYTHONPATH=...` REPLACES it rather
than appending, and any wrapper that scrubs the environment (env -i, a
supervisor, a spawn worker started from a sanitised parent) loses it. A .pth
file in the interpreter's own purelib is read by `site` at every start-up, so
the module resolves for every process the image ever runs, with no cooperation
from whoever invoked it.

WHAT COUNTS AS A FAILURE
------------------------
Three outcomes are distinguished, because they mean very different things:

  module not found          the toolkit did not install pyACL - a --full scene
                            installs it, --run and --devel do not. FATAL.
  undefined symbol          pyACL loaded but its symbols do not match the CANN
                            libraries next to it: the extension and the runtime
                            are from different releases. FATAL, and it is the
                            exact failure mode a CANN version migration exists
                            to remove.
  missing driver library    libascendcl.so pulls in driver-side objects
                            (libascend_hal.so and friends) that live in
                            /usr/local/Ascend/driver/lib64, which is EMPTY in
                            the image and bind-mounted from the host at run
                            time. Expected on a build host; NOT a failure there.
                            On a host with /dev/davinci* it is a failure, and
                            --check enforces that.
"""

from __future__ import annotations

import argparse
import glob
import os
import subprocess
import sys
import sysconfig

PTH_NAME = "ascend-pyacl.pth"

# Substrings that identify "the host driver is not mounted" rather than a broken
# image. libascend_hal is the one that actually appears; the rest are the other
# driver-side objects in the same directory, listed so a differently-worded
# loader message is still classified correctly.
DRIVER_LIBS = ("libascend_hal", "libdrvdsmi", "libdrv_dfx", "libascend_ml", "libmmpa")


def toolkit_home() -> str:
    return os.environ.get(
        "ASCEND_TOOLKIT_HOME", "/usr/local/Ascend/ascend-toolkit/latest"
    )


def candidates(tk: str) -> list[str]:
    """Where pyACL may live, most specific first.

    Which of these physically holds the module depends on how the release lays
    out its symlinks: `latest/` is a symlink farm over `<arch>-linux/`, and
    whether `latest/python` is among the links has varied. Upstream references
    the first spelling directly (tests/e2e/conftest.py:245), so it leads; the
    glob is the backstop that makes this survive a layout change.
    """
    out = [
        os.path.join(tk, "python", "site-packages"),
        os.path.join(tk, "x86_64-linux", "python", "site-packages"),
        os.path.join(tk, "aarch64-linux", "python", "site-packages"),
    ]
    out += sorted(
        os.path.dirname(p)
        for p in glob.glob(os.path.join(tk, "**", "site-packages", "acl"), recursive=True)
    )
    seen: set[str] = set()
    return [d for d in out if not (d in seen or seen.add(d))]


def holds_pyacl(d: str) -> bool:
    return (
        os.path.isdir(os.path.join(d, "acl"))
        or bool(glob.glob(os.path.join(d, "acl*.so")))
        or os.path.isfile(os.path.join(d, "acl.py"))
    )


def find_pyacl(tk: str) -> tuple[str | None, list[str]]:
    tried = candidates(tk)
    return next((d for d in tried if holds_pyacl(d)), None), tried


def run_probe(code: str, scrub_pythonpath: bool) -> subprocess.CompletedProcess:
    """Run a probe in a fresh interpreter.

    PYTHONPATH is scrubbed for the --install probes on purpose: the point of the
    .pth is that it works WITHOUT the environment variable, and probing with it
    set would only re-prove that PYTHONPATH works.
    """
    env = dict(os.environ)
    if scrub_pythonpath:
        env.pop("PYTHONPATH", None)
    return subprocess.run(
        [sys.executable, "-c", code], env=env, capture_output=True, text=True
    )


def classify_import(proc: subprocess.CompletedProcess) -> str:
    """-> 'ok' | 'undefined-symbol' | 'no-driver' | 'broken'"""
    if proc.returncode == 0:
        return "ok"
    err = proc.stderr
    if "undefined symbol" in err:
        return "undefined-symbol"
    if any(lib in err for lib in DRIVER_LIBS):
        return "no-driver"
    return "broken"


def npu_present() -> bool:
    return bool(glob.glob("/dev/davinci[0-9]*"))


IMPORT_CODE = "import acl; from acl.rt import memcpy; print('import acl + acl.rt.memcpy OK')"
SPEC_CODE = (
    "import importlib.util as u, sys;"
    "s = u.find_spec('acl');"
    "print('acl resolves to:', s.origin or (s.submodule_search_locations and list(s.submodule_search_locations)[0]) if s else None);"
    "sys.exit(0 if s else 3)"
)


def do_install() -> int:
    tk = toolkit_home()
    found, tried = find_pyacl(tk)
    if found is None:
        print(
            "ERROR: pyACL was not found under %s\n  looked in:\n    %s\n"
            "  The CANN toolkit installs pyACL with the --full scene; --run and\n"
            "  --devel do not. Re-check the toolkit install step." % (tk, "\n    ".join(tried)),
            file=sys.stderr,
        )
        return 1
    print("pyACL module directory: %s" % found)

    pth = os.path.join(sysconfig.get_paths()["purelib"], PTH_NAME)
    with open(pth, "w", encoding="utf-8") as fh:
        fh.write(found + "\n")
    print("wrote %s -> %s" % (pth, found))

    spec = run_probe(SPEC_CODE, scrub_pythonpath=True)
    sys.stdout.write(spec.stdout)
    if spec.returncode:
        print(
            "ERROR: pyACL still does not resolve with PYTHONPATH unset; the .pth\n"
            "  did not take. purelib=%s\n%s"
            % (sysconfig.get_paths()["purelib"], spec.stderr),
            file=sys.stderr,
        )
        return 1

    imp = run_probe(IMPORT_CODE, scrub_pythonpath=True)
    sys.stdout.write(imp.stdout)
    verdict = classify_import(imp)
    if verdict == "ok":
        return 0
    if verdict == "undefined-symbol":
        print(
            "ERROR: pyACL loaded but has unresolved symbols. The extension and the\n"
            "  CANN libraries beside it are from different releases - re-stage the\n"
            "  payload so the toolkit, NNAL and cann_extra are all one version.\n%s"
            % imp.stderr,
            file=sys.stderr,
        )
        return 1
    if verdict == "no-driver":
        print(
            "import acl deferred to run time: it needs the host driver, and\n"
            "  /usr/local/Ascend/driver/lib64 is empty in the image by design.\n"
            "  The module and its path wiring are correct; verify-runtime.sh\n"
            "  enforces the full import on a host with /dev/davinci*."
        )
        return 0
    print("ERROR: import acl failed, and not for want of the driver:\n%s" % imp.stderr,
          file=sys.stderr)
    return 1


def do_check() -> int:
    """Read-only. Prints one line per finding; exit 0 means pyACL is usable here."""
    tk = toolkit_home()
    found, tried = find_pyacl(tk)
    if found is None:
        print("pyacl: NOT FOUND under %s" % tk)
        return 1
    print("pyacl: module directory %s" % found)

    pth = os.path.join(sysconfig.get_paths()["purelib"], PTH_NAME)
    print("pyacl: %s %s" % (pth, "present" if os.path.isfile(pth) else "ABSENT"))

    # Not scrubbed here: --check reports what THIS image actually does at run
    # time, environment included.
    spec = run_probe(SPEC_CODE, scrub_pythonpath=False)
    sys.stdout.write("pyacl: " + spec.stdout)
    if spec.returncode:
        print("pyacl: does not resolve on sys.path")
        return 1

    imp = run_probe(IMPORT_CODE, scrub_pythonpath=False)
    sys.stdout.write("pyacl: " + imp.stdout)
    verdict = classify_import(imp)
    if verdict == "ok":
        return 0
    if verdict == "no-driver" and not npu_present():
        print("pyacl: import needs the host driver; no /dev/davinci* here, so deferred")
        return 2  # distinct code: wiring is right, hardware is absent
    print("pyacl: import FAILED (%s)\n%s" % (verdict, imp.stderr.strip()))
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--install", action="store_true", help="wire pyACL into the interpreter")
    g.add_argument("--check", action="store_true", help="report whether pyACL is usable")
    args = ap.parse_args()
    return do_install() if args.install else do_check()


if __name__ == "__main__":
    sys.exit(main())
