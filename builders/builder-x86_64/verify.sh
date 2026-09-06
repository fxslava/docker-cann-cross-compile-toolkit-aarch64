#!/bin/bash
# ---------------------------------------------------------------------------
# Verification suite for the CANN 8.5 / Ascend 310P3 cross-compilation image.
#
#   docker run --rm cann85-cross-310p:latest verify-cann-cross.sh
#
# Exits non-zero if any check fails.
# ---------------------------------------------------------------------------
set -uo pipefail
PASS=0; FAIL=0
ok()   { echo "  [ OK ] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
step() { echo; echo "=== $* ==="; }

TK="${ASCEND_TOOLKIT_HOME:-/usr/local/Ascend/ascend-toolkit/latest}"
SR="${CANN_AARCH64_ROOT:-$TK/aarch64-linux}"
SOC="${SOC_VERSION:-Ascend310P3}"
ARCH="${ASCEND_AICORE_ARCH:-dav-m200}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

step "1. Host cross-toolchain"
if v=$(aarch64-linux-gnu-g++ --version 2>&1 | head -1); then
    ok "aarch64-linux-gnu-g++ -> $v"
else
    bad "aarch64-linux-gnu-g++ not usable"
fi
aarch64-linux-gnu-gcc --version >/dev/null 2>&1 \
    && ok "aarch64-linux-gnu-gcc present" || bad "aarch64-linux-gnu-gcc missing"
command -v aarch64-linux-gnu-pkg-config >/dev/null \
    && ok "aarch64-linux-gnu-pkg-config present (hand-installed wrapper)" \
    || bad "cross pkg-config missing"

# vllm-ascend's pyproject/requirements declare cmake>=3.26.
cmv=$(cmake --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
if [ "$(printf '%s\n3.26.0\n' "$cmv" | sort -V | head -1)" = "3.26.0" ]; then
    ok "cmake $cmv (>= 3.26, satisfies vllm-ascend wheel build)"
else
    bad "cmake $cmv is older than the required 3.26"
fi
echo "  ninja: $(ninja --version)"

step "2. Ascend device compiler (ccec / Bisheng)"
if v=$(ccec --version 2>&1 | head -2 | tr '\n' ' '); then
    ok "ccec -> $v"
else
    bad "ccec not usable"
fi

step "3. aarch64 target sysroot"
ACL="$SR/lib64/libascendcl.so"
if [ -f "$ACL" ]; then
    m=$(readelf -h "$ACL" 2>/dev/null | awk -F: '/Machine:/{gsub(/^ +/,"",$2);print $2}')
    if [ "$m" = "AArch64" ]; then
        ok "libascendcl.so present at expected path and is $m"
    else
        bad "libascendcl.so has wrong machine type: $m"
    fi
else
    bad "missing $ACL"
fi

# NOTE: CANN ships no plain libhccl.so in the toolkit. On aarch64 HCCL is
# libhccl_{alg,plf,legacy}.so (libhccl_fwk.so is x86_64-only in 8.5.0).
for l in libruntime.so libascend_hal.so libgraph.so libhccl_alg.so libnnopbase.so \
         libascendalog.so libascend_protobuf.so libacl_op_compiler.so; do
    if [ -e "$SR/lib64/$l" ]; then ok "$l"; else bad "$l absent from sysroot"; fi
done

# Header tree must resolve; the toolchain file hard-requires include/acl/acl.h.
if [ -f "$SR/include/acl/acl.h" ]; then
    ok "include/acl/acl.h resolves (-> $(readlink -f "$SR/include"))"
else
    bad "$SR/include/acl/acl.h missing"
fi

# Driver link-time stubs, else the cross link dies on drvHdc*/hal* symbols.
nstub=$(find "$SR/devlib/linux/aarch64" -name '*.so*' 2>/dev/null | wc -l)
[ "$nstub" -gt 0 ] \
    && ok "devlib/linux/aarch64 populated ($nstub driver stubs)" \
    || bad "devlib/linux/aarch64 empty - cross link will fail on drvHdc* symbols"

# Nothing but AArch64 may live in the sysroot.
leak=0
for f in "$SR"/lib64/*.so*; do
    m=$(readelf -h "$f" 2>/dev/null | awk -F: '/Machine:/{gsub(/^ +/,"",$2);print $2}')
    [ "$m" = "AArch64" ] || leak=$((leak+1))
done
[ "$leak" -eq 0 ] \
    && ok "no non-AArch64 ELF leaked into sysroot" \
    || bad "$leak non-AArch64 objects in sysroot"
echo "  total sysroot libraries: $(find "$SR/lib64" -name '*.so*' | wc -l)"

step "4a. Ascend C device kernel compile for $SOC"
cat > "$TMP/add_kernel.cce" <<'KERNEL_EOF'
#include "kernel_operator.h"
using namespace AscendC;

constexpr int32_t TOTAL_LEN = 512;
constexpr int32_t BUFFER_NUM = 2;

class KernelAdd {
public:
    __aicore__ inline KernelAdd() {}
    __aicore__ inline void Init(GM_ADDR x, GM_ADDR y, GM_ADDR z)
    {
        xGm.SetGlobalBuffer((__gm__ half *)x, TOTAL_LEN);
        yGm.SetGlobalBuffer((__gm__ half *)y, TOTAL_LEN);
        zGm.SetGlobalBuffer((__gm__ half *)z, TOTAL_LEN);
        pipe.InitBuffer(inQueueX, BUFFER_NUM, TOTAL_LEN * sizeof(half));
        pipe.InitBuffer(inQueueY, BUFFER_NUM, TOTAL_LEN * sizeof(half));
        pipe.InitBuffer(outQueueZ, BUFFER_NUM, TOTAL_LEN * sizeof(half));
    }
    __aicore__ inline void Process()
    {
        LocalTensor<half> xLocal = inQueueX.AllocTensor<half>();
        LocalTensor<half> yLocal = inQueueY.AllocTensor<half>();
        DataCopy(xLocal, xGm, TOTAL_LEN);
        DataCopy(yLocal, yGm, TOTAL_LEN);
        inQueueX.EnQue(xLocal);
        inQueueY.EnQue(yLocal);
        xLocal = inQueueX.DeQue<half>();
        yLocal = inQueueY.DeQue<half>();
        LocalTensor<half> zLocal = outQueueZ.AllocTensor<half>();
        Add(zLocal, xLocal, yLocal, TOTAL_LEN);
        outQueueZ.EnQue<half>(zLocal);
        inQueueX.FreeTensor(xLocal);
        inQueueY.FreeTensor(yLocal);
        zLocal = outQueueZ.DeQue<half>();
        DataCopy(zGm, zLocal, TOTAL_LEN);
        outQueueZ.FreeTensor(zLocal);
    }
private:
    TPipe pipe;
    TQue<QuePosition::VECIN, BUFFER_NUM> inQueueX, inQueueY;
    TQue<QuePosition::VECOUT, BUFFER_NUM> outQueueZ;
    GlobalTensor<half> xGm, yGm, zGm;
};

extern "C" __global__ __aicore__ void add_custom(GM_ADDR x, GM_ADDR y, GM_ADDR z)
{
    KernelAdd op;
    op.Init(x, y, z);
    op.Process();
}
KERNEL_EOF

TIK="$TK/compiler/tikcpp/tikcfw"
# Flags mirror the official ascendc_kernel_cmake m200_intf_pub target.
# -std=c++17 is MANDATORY: the TikCFW headers use C++14+ constexpr and the
# compiler default (C++11) produces -Wc++14-extensions errors.
if ccec -std=c++17 -c "$TMP/add_kernel.cce" -o "$TMP/add_kernel.o" \
        --cce-aicore-arch="$ARCH" --cce-aicore-only --cce-auto-sync --cce-mask-opt \
        -mllvm -cce-aicore-fp-ceiling=2 \
        -I"$TIK" -I"$TIK/impl" -I"$TIK/interface" -I"$TK/include" \
        -O2 >"$TMP/cce.log" 2>&1 && [ -f "$TMP/add_kernel.o" ]; then
    code=$(readelf -h "$TMP/add_kernel.o" 2>/dev/null | awk -F: '/Machine:/{gsub(/^ +/,"",$2);print $2}')
    ok "Ascend C kernel compiled for $ARCH ($SOC); object ELF machine: ${code:-n/a}"
else
    bad "Ascend C kernel compile failed"
    grep -E 'error:' "$TMP/cce.log" | head -20
fi

step "4b. ARM64 host application linked against target libascendcl.so"
cat > "$TMP/acl_app.cpp" <<'APP_EOF'
#include "acl/acl.h"
#include <cstdio>
int main()
{
    if (aclInit(nullptr) != ACL_SUCCESS) { return 1; }
    const char *name = aclrtGetSocName();
    printf("soc=%s\n", name ? name : "(null)");
    aclFinalize();
    return 0;
}
APP_EOF
# --allow-shlib-undefined IS REQUIRED, and it is not papering over a broken
# sysroot. CANN's aarch64 dependency graph is genuinely incomplete by design:
#
#   libascendcl.so -> libmsprofiler.so, whose DT_NEEDED lists libprofapi.so
#   but NOT libprofimpl.so - and libprofimpl.so is what defines the ProfAcl*
#   symbols libmsprofiler.so references. CANN dlopens it at run time.
#
# Adding -lprofimpl by hand does not help; it only moves the failure one level
# down, to halProfSampleRegister / halProfSampleDataReport, which are defined
# by the REAL driver's libascend_hal.so. devlib's link-time stub does not
# define them, and no build host without an NPU has the real one.
#
# So ld's default --no-allow-shlib-undefined asks for something that cannot be
# satisfied off-target. The flag says "these come from a shared library that
# resolves them at run time", which is exactly the situation. What this check
# still proves is what matters: the headers resolve, libascendcl.so is found
# and is AArch64, and a real AArch64 executable comes out the other end.
if aarch64-linux-gnu-g++ "$TMP/acl_app.cpp" -o "$TMP/acl_app" \
        -I"$SR/include" -L"$SR/lib64" \
        -Wl,-rpath-link,"$SR/lib64:$SR/devlib/linux/aarch64" \
        -Wl,--allow-shlib-undefined \
        -lascendcl 2>"$TMP/link.log"; then
    f=$(readelf -h "$TMP/acl_app" | awk -F: '/Machine:/{gsub(/^ +/,"",$2);print $2}')
    ok "ARM64 ACL application linked; ELF machine: $f"
else
    bad "ARM64 ACL link failed"
    sed -n '1,30p' "$TMP/link.log"
fi

step "5. Ascend 310P operator package"
# The toolkit .run ships neither libopapi.so nor an ascend310p kernel tree nor
# an op_tiling directory; builders/builder-x86_64/provision.sh stages all three
# out of the vendor image. Reported as INFO rather than FAIL when the image was
# built WITH_SIMULATOR=0, because then it is absent by request.
if [ -f "$TK/lib64/libopapi.so" ]; then
    ok "libopapi.so present ($(stat -c%s "$TK/lib64/libopapi.so") bytes)"
    # One nm into a file, then grep the file. NOT `nm ... | grep -q "$sym"` in a
    # loop: this script runs under `set -o pipefail`, grep -q exits at the first
    # match, nm then dies of SIGPIPE, and the pipeline reports failure even
    # though the symbol was found. That reads as "libopapi.so exports none of
    # the six operators" on an image where all six are present and the suite
    # runs fine.
    nm -D --defined-only "$TK/lib64/libopapi.so" > "$TMP/opapi.syms" 2>/dev/null
    miss=""
    for sym in aclnnRmsNorm aclnnMatmul aclnnSwiGlu aclnnApplyRotaryPosEmbV2 \
               aclnnScatterPaKvCache aclnnIncreFlashAttentionV4; do
        grep -q "$sym" "$TMP/opapi.syms" || miss="$miss $sym"
    done
    [ -z "$miss" ] \
        && ok "all six operators csrc/tests resolves are exported" \
        || bad "libopapi.so does not export:$miss"

    K="$TK/opp/built-in/op_impl/ai_core/tbe/kernel/ascend310p"
    [ -d "$K" ] \
        && ok "ascend310p binary kernels present ($(find "$K" -type f | wc -l) files)" \
        || bad "no ascend310p kernel tree under $K"

    # ops_legacy is where TransData and MatMul live, and aclnnMatmul lowers
    # onto both. A tree without it passes every check above and then fails the
    # matmul suite with 561103 "cannot open op kernel bin json file".
    if [ -d "$K/ops_legacy/mat_mul" ] && [ -d "$K/ops_legacy/trans_data" ]; then
        ok "ops_legacy staged ($(find "$K/ops_legacy" -maxdepth 1 -mindepth 1 -type d | wc -l) operators, $(du -sh "$K/ops_legacy" | cut -f1))"
    else
        bad "ops_legacy is missing or trimmed; aclnnMatmul will fail with 561103"
    fi

    # The half that is easy to miss. Without it every aclnn call fails at plan
    # time with 561002 "Do not find tiling func of <Op>", which reads like a
    # missing kernel and is not.
    T="$TK/opp/built-in/op_impl/ai_core/tbe/op_tiling/lib/linux/x86_64/liboptiling.so"
    [ -f "$T" ] \
        && ok "host-side tiling functions present ($(stat -c%s "$T") bytes)" \
        || bad "no op_tiling/liboptiling.so; every aclnn call will fail with 561002"
else
    echo "  [INFO] no operator package staged (WITH_SIMULATOR=0);"
    echo "         csrc/tests would skip every device case"
fi

step "6. CAModel simulator, end to end"
# The point of the simulator: a native x86_64 ACL program that opens a device,
# creates a stream and reports the SoC, with no NPU and no driver in the image.
if [ ! -x /usr/local/bin/ascend-sim-env.sh ] || [ ! -f /opt/ascend-sim/lib/libsocshim.so ]; then
    echo "  [INFO] simulator not wired into this image (WITH_SIMULATOR=0)"
else
    SIM="$TK/tools/simulator/${ASCEND_SIM_SOC_VERSION:-$SOC}/lib"
    [ -f "$SIM/libruntime_camodel.so" ] \
        && ok "CAModel runtime present for ${ASCEND_SIM_SOC_VERSION:-$SOC}" \
        || bad "no libruntime_camodel.so under $SIM"

    cat > "$TMP/sim_app.cpp" <<'SIM_EOF'
#include "acl/acl.h"
#include <cstdio>
// set_device and reset_device MUST be paired: CANN's own launcher notes that
// an unpaired pair core dumps the simulator.
int main()
{
    aclrtContext ctx = nullptr;
    aclrtStream  st  = nullptr;
    if (aclInit(nullptr) != ACL_SUCCESS)                 { printf("aclInit\n");   return 1; }
    if (aclrtSetDevice(0) != ACL_SUCCESS)                { printf("setDevice\n"); return 2; }
    if (aclrtCreateContext(&ctx, 0) != ACL_SUCCESS)      { printf("context\n");   return 3; }
    if (aclrtCreateStream(&st) != ACL_SUCCESS)           { printf("stream\n");    return 4; }
    const char *name = aclrtGetSocName();
    printf("SOC=%s\n", name ? name : "(null)");
    aclrtDestroyStream(st);
    aclrtDestroyContext(ctx);
    aclrtResetDevice(0);
    aclFinalize();
    return 0;
}
SIM_EOF
    # Native x86_64, not the cross toolchain: this one has to RUN here.
    if g++ -m64 "$TMP/sim_app.cpp" -o "$TMP/sim_app" \
            -I"$TK/include" -L"$TK/lib64" -lascendcl 2>"$TMP/simlink.log"; then
        ok "native x86_64 ACL application linked against the host libascendcl.so"
        mkdir -p "$TMP/run"
        out=$(cd "$TMP/run" && CAMODEL_LOG_PATH="$TMP/run" \
              timeout -s KILL 300 /usr/local/bin/ascend-sim-env.sh "$TMP/sim_app" 2>&1)
        soc=$(printf '%s\n' "$out" | sed -n 's/^SOC=//p')
        if [ -n "$soc" ]; then
            ok "CAModel came up and reported soc=$soc"
            [ "$soc" = "${ASCEND_SIM_SOC_VERSION:-$SOC}" ] \
                || bad "simulator reports $soc, expected ${ASCEND_SIM_SOC_VERSION:-$SOC}"
        else
            bad "CAModel did not come up"
            printf '%s\n' "$out" | grep -vE 'DRVSTUB_LOG|drvMoveTsReport|config_file.cc' | tail -15
        fi
    else
        bad "native ACL link failed"
        sed -n '1,20p' "$TMP/simlink.log"
    fi
fi

step "Summary"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "  ALL VERIFICATION CHECKS PASSED"
