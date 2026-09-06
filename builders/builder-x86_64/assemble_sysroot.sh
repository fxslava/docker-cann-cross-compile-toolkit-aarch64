#!/bin/bash
# ---------------------------------------------------------------------------
# Assemble an aarch64 CANN target sysroot from the aarch64 toolkit run package.
#
# WHY NOT JUST `--install`?
#   The aarch64 .run refuses to install on an x86_64 host: its payload binaries
#   and the post-install steps its installer runs are ARM64. Makeself's
#   --noexec skips the embedded install script entirely and --extract= drops the
#   raw payload, which is all a cross sysroot needs.
#
# LAYOUT PRODUCED (deliberately matches cmake/aarch64-toolchain.cmake in
# vllm-ascend, so this directory can be passed as -DCANN_AARCH64_ROOT):
#
#   <DEST>/
#     include -> ../include          (headers are arch-independent)
#     lib64/                         flat aggregate of every AArch64 ELF .so
#     devlib/linux/aarch64/          driver link-time stubs (drvHdc*, hal*)
#
#   $1 = path to Ascend-cann-toolkit_<ver>_linux-aarch64.run
#   $2 = destination, e.g. /usr/local/Ascend/ascend-toolkit/latest/aarch64-linux
# ---------------------------------------------------------------------------
set -euo pipefail

RUN_PKG="$1"
DEST="$2"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# NOTE: never pre-create an extraction target. The outer Huawei wrapper
# (label=ASCEND_RUN_PACKAGE) tolerates an existing directory, but the inner
# component packages are stock makeself 2.5.0 and abort with
#   "Target directory <path> already exists, aborting."  (exit 1)
echo "[sysroot] extracting outer package ..."
bash "$RUN_PKG" --noexec --extract="$WORK/outer" >/dev/null 2>&1

echo "[sysroot] extracting CANN components ..."
for run in "$WORK"/outer/run_package/cann-*aarch64.run \
           "$WORK"/outer/run_package/pyACL_*aarch64.run; do
    [ -e "$run" ] || continue
    name="$(basename "$run" .run)"
    bash "$run" --noexec --extract="$WORK/comp/$name" >/dev/null 2>&1 \
        || echo "[sysroot] WARN: could not extract $name"
done

DEVLIB="$DEST/devlib/linux/aarch64"
mkdir -p "$DEST/lib64" "$DEVLIB"

# Paths that must not contribute to the CANN target sysroot.
#
#   hcc/      -> cann-bisheng-compiler ships a COMPLETE private GCC 7.3.0
#                aarch64 cross toolchain here, including its own glibc sysroot,
#                253 gconv charset modules, and target runtime libraries.
#                Excluding only hcc/sysroot/ is NOT enough: hcc/aarch64-target-
#                linux-gnu/lib64/ holds libstdc++.so.6.0.24 (GLIBCXX_3.4.24).
#                Copied into the sysroot it shadows the Ubuntu 22.04 cross
#                toolchain's libstdc++.so.6.0.30 and the link dies with
#                  undefined reference to `std::__throw_bad_array_new_length()'
#                  undefined reference to `std::__cxx11::basic_stringstream...'
#                because that symbol only exists from GCC 11 / GLIBCXX_3.4.29.
#   simulator -> per-SoC instruction-set simulators, not link targets
is_excluded() {
    case "$1" in
        */hcc/*|*/tools/simulator/*|*/gconv/*) return 0 ;;
    esac
    # Belt and braces: the C/C++ runtime must ALWAYS come from the cross
    # toolchain, never from CANN, whatever path it was found at.
    case "$(basename "$1")" in
        libstdc++.so*|libgcc_s.so*|libgomp.so*|libatomic.so*|libssp.so*|\
        libitm.so*|libasan.so*|libtsan.so*|liblsan.so*|libubsan.so*|\
        libquadmath.so*|libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*)
            return 0 ;;
    esac
    return 1
}

# Authoritative arch test. Do not trust directory names: the aarch64 package
# also ships runtime/devlib/linux/x86_64/, and the x86_64 package ships an
# aarch64 devlib. Only the ELF header is trustworthy.
is_aarch64_elf() {
    readelf -h "$1" 2>/dev/null | grep -q 'Machine:.*AArch64'
}

# Pass "real" takes implementation libraries; pass "stub" then fills in only the
# sonames pass 1 did not provide, so a stub never shadows a real library.
#
# CRITICAL: the find predicate must be \( -type f -o -type l \). A bare -type f
# silently drops every versioned symlink -- libascend_protobuf.so ->
# libascend_protobuf.so.3.13.0.0 among them -- which cost 28 of the 212
# libraries on the first attempt. Copies are dereferenced (cp -aL) because the
# sysroot is flat and a preserved symlink could point outside it.
copy_pass() {
    local want="$1" copied=0 src base
    while IFS= read -r src; do
        is_excluded "$src" && continue
        case "$src" in
            */stub/*|*/devlib/*) [ "$want" = "stub" ] || continue ;;
            *)                   [ "$want" = "real" ] || continue ;;
        esac
        is_aarch64_elf "$src" || continue
        base="$(basename "$src")"
        [ -e "$DEST/lib64/$base" ] && continue
        cp -aL "$src" "$DEST/lib64/$base"
        copied=$((copied + 1))
    done < <(find "$WORK/comp" -name '*.so*' \( -type f -o -type l \) | sort)
    echo "[sysroot] $want libraries copied: $copied"
}

copy_pass real
copy_pass stub

# Driver link-time stubs. libascendcl.so pulls in toolkit libraries via
# DT_NEEDED which in turn need driver symbols (drvHdcGetCapacity, hal*). The
# driver lives on the device, not in the toolkit, so without these the cross
# link fails with "undefined reference to drvHdc*".
while IFS= read -r src; do
    is_excluded "$src" && continue
    is_aarch64_elf "$src" || continue
    base="$(basename "$src")"
    [ -e "$DEVLIB/$base" ] || cp -aL "$src" "$DEVLIB/$base"
done < <(find "$WORK/comp" -path '*devlib/linux/aarch64/*' -name '*.so*' \
              \( -type f -o -type l \) | sort)

# CANN headers are arch-independent and already installed by the x86_64 side;
# symlink rather than duplicate ~100 MB. Relative so the toolkit stays movable.
if [ ! -e "$DEST/include" ]; then
    ln -sfn ../include "$DEST/include"
fi

echo "[sysroot] lib64 : $(find "$DEST/lib64" -name '*.so*' | wc -l) libraries"
echo "[sysroot] devlib: $(find "$DEVLIB" -name '*.so*' | wc -l) driver stubs"
echo "[sysroot] include -> $(readlink -f "$DEST/include" 2>/dev/null || echo MISSING)"
