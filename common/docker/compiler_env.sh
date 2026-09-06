#!/bin/bash
# Ascend C build environment for an out-of-Dockerfile compile. Source; do not
# execute.
#
#   . /usr/local/lib/ascend/compiler_env.sh
#
# The images carry the same values as ENV so that `docker run <image> python3`
# works without sourcing anything. This file is for interactive and dev-shell
# use (run_dev.sh), where the vendor set_env.sh scripts must also be sourced and
# the build-only variables are not in the image environment.
#
# PRECONDITIONS
#   SOC_VERSION           lowercase, and NOT the vendor-facing spelling.
#                         vllm-ascend gates every 950 path on the case-sensitive
#                         CMake regex SOC_VERSION MATCHES "ascend950" and
#                         setup.py asserts a value starting with "ascend950";
#                         "Ascend950PR" matches nothing and builds the wrong
#                         branch silently. Derive it on real silicon as
#                         (Chip Name + "_" + NPU Name).lower() from
#                         `npu-smi info -t board -i 0`.
#   ASCEND_AICORE_ARCH    core architecture for the kernel compile. Confirm
#                         against the toolkit's own table before trusting a
#                         kernel build:
#                           grep -nE '^set\((ascend|kirin)[a-z0-9_]*_list' \
#                             <toolkit>/ascendc_kernel_cmake/legacy_modules/host_config.cmake
#
# CANN_3RD_LIB_PATH is left at csrc/build.sh's default of csrc/third_party,
# which is where common/patches/cmake_fetchcontent_local.sh stages the archives.
: "${ASCEND_BASE:=/usr/local/Ascend}"
: "${ASCEND_TOOLKIT_HOME:=${ASCEND_BASE}/ascend-toolkit/latest}"
export ASCEND_BASE ASCEND_TOOLKIT_HOME

# shellcheck source=../patches/ascend_setenv_nounset.sh
. /usr/local/lib/ascend/setenv.sh
ascend_source_setenv

export CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
export CMAKE_PREFIX_PATH="${ASCEND_TOOLKIT_HOME}/lib64/cmake:${ASCEND_TOOLKIT_HOME}/toolkit/tools/tikicpulib/lib/cmake${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"

echo "[compiler-env] $(uname -m) SOC_VERSION=${SOC_VERSION:-unset} ASCEND_AICORE_ARCH=${ASCEND_AICORE_ARCH:-unset}"
echo "[compiler-env] toolkit ${ASCEND_TOOLKIT_HOME}"
command -v ccec >/dev/null && echo "[compiler-env] ccec $(command -v ccec)" \
    || echo "[compiler-env] WARNING: ccec not on PATH; the kernel compile will fail"
