#!/bin/bash
# ---------------------------------------------------------------------------
# Runtime verification suite for the AArch64 Ascend 310P3 inference image.
#
#   docker run --rm vllm-ascend-310p:aarch64-offline verify
#   docker run --rm --entrypoint verify-runtime.sh <image>
#
# The script runs on the x86_64 build host under QEMU as well as on the target
# Ascend server. Checks that genuinely need hardware are reported as INFO, never
# as failures, so a clean run on the build host is not a claim that the NPU
# works -- only that the image is complete.
#
# Exits non-zero if any check fails.
# ---------------------------------------------------------------------------
set -uo pipefail
PASS=0; FAIL=0
ok()   { echo "  [ OK ] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "  [INFO] $*"; }
step() { echo; echo "=== $* ==="; }

TK="${ASCEND_TOOLKIT_HOME:-/usr/local/Ascend/ascend-toolkit/latest}"

# Counted up front because step 5 has to know: the native extension can only be
# loaded where a device exists.
NDEV=0
for dev in /dev/davinci[0-9]*; do [ -c "$dev" ] && NDEV=$((NDEV+1)); done

step "1. Platform"
arch=$(uname -m)
[ "$arch" = "aarch64" ] && ok "architecture: $arch" || bad "architecture is $arch, expected aarch64"

pyv=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)
[ "$pyv" = "3.10" ] && ok "python $pyv" || bad "python $pyv, expected 3.10"
info "pip $(python3 -m pip --version 2>/dev/null | awk '{print $2}')"

step "2. CANN toolkit"
if [ -f "$TK/lib64/libascendcl.so" ]; then
    m=$(readelf -h "$TK/lib64/libascendcl.so" 2>/dev/null | awk -F: '/Machine:/{gsub(/^ +/,"",$2);print $2}')
    [ "$m" = "AArch64" ] \
        && ok "libascendcl.so present and is $m" \
        || bad "libascendcl.so has machine type $m"
else
    bad "missing $TK/lib64/libascendcl.so"
fi
[ -f /usr/local/Ascend/ascend-toolkit/set_env.sh ] \
    && ok "set_env.sh present" || bad "set_env.sh missing"
if [ -f "$TK/../ascend_toolkit_install.info" ]; then
    info "$(tr '\n' ' ' < "$TK/../ascend_toolkit_install.info")"
fi

step "3. Offline runtime imports"
# This is the acceptance check: every one of these must resolve with no network
# and no NPU attached.
if python3 -c "import torch; import torch_npu; import vllm; import vllm_ascend; print('ALL RUNTIME IMPORTS SUCCEEDED')" 2>/tmp/imports.log; then
    ok "torch / torch_npu / vllm / vllm_ascend all import"
else
    bad "runtime imports failed"
    tail -20 /tmp/imports.log
fi

step "4. Versions and build info"
python3 - <<'PY' 2>/dev/null || echo "  [FAIL] version probe failed"
import importlib


def show(name, attr="__version__"):
    try:
        mod = importlib.import_module(name)
        print("  [INFO] %-12s %s" % (name, getattr(mod, attr, "?")))
    except Exception as exc:                       # noqa: BLE001
        print("  [INFO] %-12s import error: %s" % (name, exc))


show("torch")
show("torch_npu")
show("vllm")
show("vllm_ascend")
try:
    from vllm_ascend import _build_info
    print("  [INFO] built for   %s" % _build_info.__device_type__)
except Exception as exc:                           # noqa: BLE001
    print("  [INFO] _build_info unavailable: %s" % exc)
PY

# vllm_ascend must have been compiled for the 310P family, not for A2/A3.
dt=$(python3 -c "from vllm_ascend import _build_info; print(_build_info.__device_type__)" 2>/dev/null)
[ "$dt" = "_310P" ] \
    && ok "vllm_ascend built for device family $dt (Ascend 310P)" \
    || bad "vllm_ascend built for '${dt:-unknown}', expected _310P"

step "5. Compiled extension"
# libvllm_ascend_kernels.so, which vllm_ascend_C pulls in, registers its device
# binaries from an ELF constructor that first calls AscendCheckSoCVersion(). On
# a host with no NPU aclrtGetSocName() returns NULL, that check builds a
# std::string from it, and the process dies with
#   terminate called after throwing an instance of 'std::logic_error'
#   what():  basic_string::_S_construct null not valid
# before Python sees anything it could catch. That is a property of the CANN
# runtime, not of this image, so only assert the import where a device exists.
# It is also why nothing in Dockerfile.aarch64 imports vllm_ascend_C: the build
# host has no NPU. `ldd -r` still proves the module has no unresolved symbols
# of its own, which is the part a build host can honestly check.
ext_so=$(python3 - <<'PY' 2>/dev/null
import glob, os, vllm_ascend
d = os.path.dirname(vllm_ascend.__file__)
print((glob.glob(os.path.join(d, "vllm_ascend_C*.so")) or [""])[0])
PY
)
if [ -n "$ext_so" ] && [ -f "$ext_so" ]; then
    ok "vllm_ascend_C built into the wheel ($(basename "$ext_so"))"
    # libtorch/libtorch_npu live in the wheels, not on the default search path,
    # so tell ldd where they are or every torch symbol reads as unresolved.
    torch_libs=$(python3 - <<'PY' 2>/dev/null
import os, torch, torch_npu
print(":".join(os.path.join(os.path.dirname(m.__file__), "lib")
                for m in (torch, torch_npu)))
PY
)
    unresolved=$(LD_LIBRARY_PATH="$torch_libs:$(dirname "$ext_so"):${LD_LIBRARY_PATH:-}" \
        ldd -r "$ext_so" 2>&1 | grep "undefined symbol" | grep -vcE "undefined symbol: _?Py")
    if [ "${unresolved:-1}" -eq 0 ]; then
        ok "vllm_ascend_C has no unresolved symbols beyond the Python API"
    else
        bad "vllm_ascend_C has $unresolved unresolved non-Python symbols"
    fi
else
    bad "vllm_ascend_C native extension was not built"
fi

if [ "$NDEV" -gt 0 ]; then
    if python3 -c "import vllm_ascend.vllm_ascend_C" 2>/tmp/ext.log; then
        ok "vllm_ascend_C native extension loads"
    else
        bad "vllm_ascend_C native extension does not load"
        tail -5 /tmp/ext.log
    fi
else
    info "skipping the vllm_ascend_C import: no NPU, so CANN's SoC check aborts"
fi

step "6. vLLM entrypoint"
if command -v vllm >/dev/null; then
    ok "vllm CLI on PATH ($(command -v vllm))"
else
    bad "vllm CLI missing"
fi

step "7. NPU hardware (informational)"
if [ "$NDEV" -gt 0 ]; then
    info "$NDEV NPU device node(s) visible"
    python3 -c "import torch, torch_npu; print('  [INFO] torch_npu device_count:', torch.npu.device_count())" 2>/dev/null \
        || info "torch.npu.device_count() unavailable (driver not mounted?)"
else
    info "no /dev/davinci* node - expected on the build host, not on a target server"
fi

step "Summary"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "  ALL RUNTIME VERIFICATION CHECKS PASSED"
