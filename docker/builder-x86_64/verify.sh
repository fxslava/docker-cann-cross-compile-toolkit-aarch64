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
if aarch64-linux-gnu-g++ "$TMP/acl_app.cpp" -o "$TMP/acl_app" \
        -I"$SR/include" -L"$SR/lib64" \
        -Wl,-rpath-link,"$SR/lib64:$SR/devlib/linux/aarch64" \
        -lascendcl 2>"$TMP/link.log"; then
    f=$(readelf -h "$TMP/acl_app" | awk -F: '/Machine:/{gsub(/^ +/,"",$2);print $2}')
    ok "ARM64 ACL application linked; ELF machine: $f"
else
    bad "ARM64 ACL link failed"
    sed -n '1,30p' "$TMP/link.log"
fi

step "Summary"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "  ALL VERIFICATION CHECKS PASSED"
