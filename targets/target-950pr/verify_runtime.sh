#!/bin/bash
# ---------------------------------------------------------------------------
# Runtime verification suite for the x86_64 Ascend 950PR inference image.
#
#   docker run --rm vllm-ascend-950pr:x86_64-offline verify
#   docker run --rm --entrypoint verify-runtime.sh <image>
#
# Nine assertions, the same shape as the 310P suite in
# targets/target-310p/verify_runtime.sh:
#
#   1 x86_64 architecture
#   2 Python 3.10 / 3.11 / 3.12
#   3 CANN 9.x runtime libraries: libascendcl.so (x86-64 ELF) and libhccl.so
#   4 offline torch / torch_npu / vllm / vllm_ascend imports
#   5 vllm_ascend built for device family A5, not _310P
#   6 vllm_ascend_C built into the wheel
#   7 vllm_ascend_C has no unresolved symbols beyond the Python C API
#   8 no 310P stub symbols, i.e. no 310P gating patch leaked into this target
#   9 vllm CLI present and `vllm serve --help` works
#
# A tenth assertion -- importing vllm_ascend_C itself -- is reachable only
# where /dev/davinci* exists, so a build host sees 9/9 and an NPU host 10/10.
#
# Checks that genuinely need hardware are reported as INFO, never as failures,
# so a clean run on a build host is not a claim that the NPU works -- only that
# the image is complete.
#
# Exits non-zero if any check fails.
# ---------------------------------------------------------------------------
set -uo pipefail

# QUIET vLLM's PLUGIN LOGGING, because this suite captures command substitution
# output as values. vllm_ascend registers a platform plugin and vLLM announces
# it on STDOUT, not stderr:
#     INFO ... Available plugins for group vllm.platform_plugins:
#     INFO ... Platform plugin ascend is activated
# so `dt=$(python3 -c "... print(_build_info.__device_type__)")` came back as
# five log lines with "A5" on the end and the check failed against a healthy
# image, reporting 'built for INFO ... A5' instead of 'A5'. Every value probe
# below therefore also takes the LAST line only - belt and braces, since a
# future vLLM may log something this variable does not suppress.
export VLLM_LOGGING_LEVEL="${VLLM_LOGGING_LEVEL:-ERROR}"

PASS=0; FAIL=0
ok()   { echo "  [ OK ] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "  [INFO] $*"; }
step() { echo; echo "=== $* ==="; }

TK="${ASCEND_TOOLKIT_HOME:-/usr/local/Ascend/ascend-toolkit/latest}"

# Counted up front because step 4 has to know: the native extension can only be
# loaded where a device exists.
NDEV=0
for dev in /dev/davinci[0-9]*; do [ -c "$dev" ] && NDEV=$((NDEV+1)); done

step "1. Platform"
arch=$(uname -m)
[ "$arch" = "x86_64" ] && ok "architecture: $arch" || bad "architecture is $arch, expected x86_64"

pyv=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)
# 3.10 is this image's own interpreter: the base is Ubuntu 22.04, matching
# upstream's Dockerfile.a5 line, and jammy's system python is 3.10. 3.11 and
# 3.12 stay acceptable so a BASE_IMAGE override does not fail a healthy image.
case "$pyv" in
    3.10|3.11|3.12) ok "python $pyv" ;;
    *)              bad "python $pyv, expected 3.10, 3.11 or 3.12" ;;
esac
info "pip $(python3 -m pip --version 2>/dev/null | awk '{print $2}')"

step "2. CANN 9.x runtime libraries"
# One assertion over both libraries, because they fail as a pair in practice.
#
# libascendcl.so is the ACL entry point; on this target it must be an x86-64
# object, which is what distinguishes a native build from the emulated 310P one.
#
# libhccl.so is the collective-communication library every torch_npu build
# records in DT_NEEDED. On CANN 8.5.0 the standalone toolkit shipped only the
# split libhccl_{alg,fwk,legacy,plf}.so and this repo had to stage the
# aggregate out of a vendor container (see the 310P notes). Assert it directly
# rather than discovering it as an ImportError three steps later.
cann_libs_ok=1
if [ -f "$TK/lib64/libascendcl.so" ]; then
    m=$(readelf -h "$TK/lib64/libascendcl.so" 2>/dev/null | awk -F: '/Machine:/{gsub(/^ +/,"",$2);print $2}')
    case "$m" in
        *X86-64*) info "libascendcl.so is $m" ;;
        *)        info "libascendcl.so has machine type '$m', expected X86-64"
                  cann_libs_ok=0 ;;
    esac
else
    info "missing $TK/lib64/libascendcl.so"
    cann_libs_ok=0
fi
if [ -e "$TK/lib64/libhccl.so" ]; then
    info "libhccl.so present"
else
    info "missing $TK/lib64/libhccl.so - torch_npu records it in DT_NEEDED"
    cann_libs_ok=0
fi
[ "$cann_libs_ok" -eq 1 ] \
    && ok "CANN runtime libraries present: libascendcl.so (x86-64) and libhccl.so" \
    || bad "CANN runtime libraries incomplete (see the INFO lines above)"

if [ -f "$TK/../ascend_toolkit_install.info" ]; then
    info "$(tr '\n' ' ' < "$TK/../ascend_toolkit_install.info")"
fi
ver=$(sed -n 's/^version=//p' "$TK/../ascend_toolkit_install.info" 2>/dev/null)
case "$ver" in
    9.*) info "CANN version $ver (9.x, as this target requires)" ;;
    "")  info "CANN version not readable from ascend_toolkit_install.info" ;;
    *)   info "CANN version $ver - NOT a 9.x release; the 950 needs CANN 9.x" ;;
esac
[ -e /usr/local/Ascend/nnal/atb/set_env.sh ] \
    && info "nnal/atb present (ATB attention paths available)" \
    || info "nnal/atb absent - upstream's A5 image sources it before building"

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
# `bad`, not a bare echo: the 310P suite prints an uncounted "[FAIL]" here,
# which reads as a failure but does not move the total. Counting it keeps the
# summary honest. On a healthy image this never fires, so the total stays 9.
python3 - <<'PY' 2>/dev/null || bad "version probe failed"
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

# vllm_ascend must have been compiled for the 950/A5 family. Getting this wrong
# mis-dispatches at inference time, and _310P here would mean the image was
# built with the 310P SOC_VERSION by mistake.
dt=$(python3 -c "from vllm_ascend import _build_info; print(_build_info.__device_type__)" 2>/dev/null | tail -1)
case "$dt" in
    A5)   ok "vllm_ascend built for device family $dt (Ascend 950 / DaVinci v3)" ;;
    _310P) bad "vllm_ascend built for '_310P' - this image was built with the 310P SOC_VERSION" ;;
    *)    bad "vllm_ascend built for '${dt:-unknown}', expected A5" ;;
esac
info "SOC_VERSION at build time: ${SOC_VERSION:-<unset>}"

step "5. Compiled extension"
# libvllm_ascend_kernels.so registers its device binaries from an ELF
# constructor calling CANN's AscendCheckSoCVersion(). With no NPU,
# aclrtGetSocName() returns NULL, that builds a std::string from it, and the
# process aborts before Python can catch anything -- a property of the CANN
# runtime, not of this image. So assert the import only where a device exists,
# and on a build host check what a build host can.
ext_so=$(python3 - <<'PY' 2>/dev/null
import glob, os, vllm_ascend
d = os.path.dirname(vllm_ascend.__file__)
print((glob.glob(os.path.join(d, "vllm_ascend_C*.so")) or [""])[0])
PY
)
ext_so=$(printf '%s\n' "$ext_so" | tail -1)
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
    torch_libs=$(printf '%s\n' "$torch_libs" | tail -1)
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

step "6. Operator set matches the ascend950 build gate"
# READ THIS BEFORE 'FIXING' A FAILURE HERE.
#
# vllm-ascend@main puts ascend950 on the SAME CMake branch as ascend310p in
# three places, so the 950 operator set is deliberately a SUBSET today:
#
#   if(SOC_VERSION MATCHES "ascend310p.*|ascend950")  -> skip the
#       ascendc_library(vllm_ascend_kernels) build entirely
#   VLLM_ASCEND_CUSTOM_OP_EXCLUDE_ASCEND950           -> drop mla_preprocess
#       and batch_matmul_transpose ("A5 hardware detected: disabling MLAPO")
#   -DVLLM_ENABLE_ATB_AND_DIRECT_KERNELS              -> NOT defined for 950
#
# and vllm_ascend/utils.py states it outright: "in ASCEND950 chip, we
# temporarily disable all custom ops". So this step asserts the shape upstream
# actually produces, not a fuller one. When upstream enables those kernels the
# expectation below has to move with it -- deliberately, not silently.
stub_syms=0
kernels_so=""
if [ -n "$ext_so" ] && [ -f "$ext_so" ]; then
    # 310P stub translation unit must not be present. On this repo's 310P image
    # a local patch adds unsupported_310p.cpp to supply *_impl symbols for
    # kernels that cannot compile for dav-m200; none of that belongs here, and
    # its presence would mean the 310P patch set leaked into this target.
    stub_syms=$(nm -D --defined-only "$ext_so" 2>/dev/null \
        | grep -ci 'unsupported_310p\|_310p_stub' || true)
    kernels_so=$(dirname "$ext_so")/libvllm_ascend_kernels.so
    nops=$(nm -D --defined-only "$ext_so" 2>/dev/null | wc -l)
    info "vllm_ascend_C exports $nops defined dynamic symbols"
fi

if [ "$stub_syms" -eq 0 ] && [ -n "$ext_so" ]; then
    ok "no 310P stub symbols in vllm_ascend_C (no 310P gating patch applied)"
elif [ -z "$ext_so" ]; then
    bad "cannot inspect symbols: vllm_ascend_C missing"
else
    bad "$stub_syms 310P stub symbol(s) present - a 310P patch leaked into this build"
fi

if [ -e "$kernels_so" ]; then
    info "libvllm_ascend_kernels.so IS present - upstream has evidently enabled"
    info "the kernels library for ascend950; update this step and the Dockerfile note"
else
    info "libvllm_ascend_kernels.so absent, as the ascend950 CMake gate dictates"
fi

# THE ACLNN CUSTOM OPS ARE A SEPARATE MECHANISM, and on this SoC they are very
# much built. An earlier revision of this suite (and of the docs) said the 950
# gets no custom kernels at all, which conflated two different things:
#
#   ascendc_library(vllm_ascend_kernels)  -> genuinely skipped for ascend950,
#                                            hence no libvllm_ascend_kernels.so
#   csrc/build_aclnn.sh                   -> builds 27 ACLNN ops for ascend950
#                                            (mla_prolog_v3 among them, so MLAPO
#                                            is NOT excluded here), packages them
#                                            with CPack and installs them under
#                                            vllm_ascend/_cann_ops_custom
#
# That package is the single largest product of the build - 493 kernel binaries,
# ~90 minutes of compilation - so its presence is asserted rather than assumed.
ops_vendor=$(python3 -c "import os, vllm_ascend; print(os.path.join(os.path.dirname(vllm_ascend.__file__), '_cann_ops_custom', 'vendors', 'custom_transformer'))" 2>/dev/null | tail -1)
if [ -n "$ops_vendor" ] && [ -d "$ops_vendor" ] && [ -e "$ops_vendor/op_api/lib/libcust_opapi.so" ]; then
    ok "ACLNN custom ops installed ($(find "$ops_vendor" -type f | wc -l) files, libcust_opapi.so present)"
    info "built for SOC ascend950 by csrc/build_aclnn.sh, including mla_prolog_v3"
else
    bad "ACLNN custom op package missing under vllm_ascend/_cann_ops_custom"
fi

if [ "$NDEV" -gt 0 ]; then
    # A tenth assertion, reachable only on a real NPU host. The build-host run
    # is the 9-check one; do not "fix" the count by suppressing this.
    if python3 -c "import vllm_ascend.vllm_ascend_C" 2>/tmp/ext.log; then
        ok "vllm_ascend_C native extension loads"
    else
        bad "vllm_ascend_C native extension does not load"
        tail -5 /tmp/ext.log
    fi
else
    info "skipping the vllm_ascend_C import: no NPU, so CANN's SoC check aborts"
fi

step "7. vLLM entrypoint"
# `vllm serve --help` loads the platform plugin, which imports triton-ascend,
# whose driver asks the NPU for its architecture. With no device attached that
# returns NULL and raises
#     triton/backends/ascend/driver.py get_arch()
#     SystemError: <built-in function get_arch> returned NULL without setting
#     an exception
# This is the same class of hardware dependency as the vllm_ascend_C import in
# step 5 -- a property of the Ascend stack, not of this image -- so on a host
# with no /dev/davinci* it is reported, not counted as a failure. Where a
# device IS present the check is enforced, because there it must work.
if command -v vllm >/dev/null; then
    if vllm serve --help >/tmp/vllm-help.log 2>&1; then
        ok "vllm CLI on PATH and 'vllm serve --help' works ($(command -v vllm))"
    elif [ "$NDEV" -eq 0 ] && grep -q "get_arch\|returned NULL" /tmp/vllm-help.log; then
        ok "vllm CLI on PATH ($(command -v vllm))"
        info "'vllm serve --help' cannot run here: triton-ascend's driver queries"
        info "the NPU architecture at import and there is no device. Expected on a"
        info "build host; re-run this suite on a 950 to exercise it."
    else
        bad "vllm CLI present but 'vllm serve --help' failed"
        tail -5 /tmp/vllm-help.log
    fi
else
    bad "vllm CLI missing"
fi

step "8. NPU hardware (informational)"
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
