#!/bin/sh
# Guarantees an aggregate libhccl.so is resolvable. Run once, after the CANN
# toolkit and any cann_extra staging, before anything imports torch_npu.
#
#   ASCEND_TOOLKIT_HOME=<path> sh hccl_devlib_fallback.sh
#
# FAILURE MODE - every torch_npu build records `libhccl.so` in DT_NEEDED (in
# _C*.so, libtorch_npu.so, libop_plugin_atb.so and libtensorpipe.so). CANN's
# toolkit package installs the collective library split as
# libhccl_{alg,legacy,plf,v2}.so plus libhcomm.so and ships no aggregate; the
# toolkit's own manifest (share/info/hcomm/script/filelist.csv) lists the split
# set and nothing else. Absent an aggregate:
#     ImportError: libhccl.so: cannot open shared object file
#
# PREFERRED RESOLUTION is the real library, staged from the vendor image by the
# target's provision.sh (cann_extra). This script takes that branch when lib64
# already carries it and does nothing.
#
# The fallback link is a LAST RESORT and is deliberately placed in devlib, not
# lib64. LD_LIBRARY_PATH keeps /usr/local/Ascend/driver/lib64 first and
# ${ASCEND_TOOLKIT_HOME}/devlib last, so a bind-mounted host driver always wins
# over it. libhcomm.so is not the aggregate - HcclCommListEv is absent from
# every split library - so a link built on it satisfies the loader and fails at
# the first collective call, on hardware, far from the cause.
set -eu
TK="${ASCEND_TOOLKIT_HOME:-/usr/local/Ascend/ascend-toolkit/latest}"

if [ -e "${TK}/lib64/libhccl.so" ]; then
    echo "libhccl.so present in lib64; no driver stub needed"
    ls -l "${TK}/lib64/libhccl.so"
    exit 0
fi

[ -e "${TK}/lib64/libhcomm.so" ] || {
    echo "neither libhccl.so nor libhcomm.so in ${TK}/lib64; re-stage cann_extra" >&2
    exit 1
}
mkdir -p "${TK}/devlib"
ln -sfn "${TK}/lib64/libhcomm.so" "${TK}/devlib/libhccl.so"
echo "devlib/libhccl.so -> libhcomm.so (driver stub, overridden by a real driver)"
ls -l "${TK}/devlib/libhccl.so"
