# syntax=docker/dockerfile:1.7
# ============================================================================
#  CANN 8.5.0 cross-compilation image for Huawei Ascend 310P3
#
#  Host   : x86_64 (Ubuntu 22.04)
#  Target : aarch64 / Ascend310P3 (AI Core arch dav-m200)
#
#  Provides both halves of an Ascend cross build:
#    * host side   - aarch64-linux-gnu GCC toolchain + CANN aarch64 sysroot
#    * device side - CANN Bisheng/ccec compiler for Ascend C kernels
#
#  Build context is the REPOSITORY ROOT; deps/ must contain (see download_deps.sh):
#    deps/Ascend-cann-toolkit_8.5.0_linux-x86_64.run
#    deps/Ascend-cann-toolkit_8.5.0_linux-aarch64.run
#    deps/torch-2.10.0+cpu-cp310-cp310-manylinux_2_28_aarch64.whl   (optional)
#
#  The .run files are bind-mounted at build time, so ~2.2 GB of installer
#  never lands in an image layer.
#
#  Build, from the repository root:
#    DOCKER_BUILDKIT=1 docker build -f builders/builder-x86_64/Dockerfile -t cann85-cross-310p:latest .
# ============================================================================
FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG CANN_VERSION=8.5.0
ARG ASCEND_BASE=/usr/local/Ascend
# Set to 1 to bake the aarch64 LibTorch sysroot into the image.
ARG WITH_LIBTORCH=0
# Set to 0 for the cross-compilation image alone, with no Ascend 310P operator
# package and no CAModel wiring. At 1 (the default) the build needs
# deps/builder-x86_64/, which builders/builder-x86_64/provision.sh stages.
ARG WITH_SIMULATOR=1
# The part the simulator models. It is also the literal directory name under
# tools/simulator/, so it must be CANN's capitalised spelling.
ARG SIM_SOC_VERSION=Ascend310P3

# ---------------------------------------------------------------------------
# 1. System toolchain + CANN runtime dependencies
# ---------------------------------------------------------------------------
# ccache is here because every rebuild of csrc/tests recompiles the same
# googletest translation units; the native C compiler that build-essential
# brings in is what compiles common/patches/soc_shim.c in section 9.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        gcc-aarch64-linux-gnu \
        g++-aarch64-linux-gnu \
        binutils-aarch64-linux-gnu \
        libc6-dev-arm64-cross \
        pkg-config \
        cmake \
        ninja-build \
        make \
        ccache \
        git \
        python3 \
        python3-pip \
        python3-dev \
        libpci3 \
        pciutils \
        libxml2 \
        ca-certificates \
        zlib1g-dev \
        xz-utils \
        unzip \
        curl \
        wget \
        file \
        binutils \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu 22.04 (jammy) has NO `pkg-config-aarch64-linux-gnu` package - it only
# appears from 24.04 (pkgconf era). Install the standard Debian cross wrapper
# by hand so target .pc files resolve during cross builds.
RUN printf '%s\n' \
        '#!/bin/sh' \
        'PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig' \
        'export PKG_CONFIG_LIBDIR' \
        'exec pkg-config "$@"' \
        > /usr/bin/aarch64-linux-gnu-pkg-config \
    && chmod 0755 /usr/bin/aarch64-linux-gnu-pkg-config

# ---------------------------------------------------------------------------
# 2. Python prerequisites checked by the CANN installer and the TBE/op compilers
# ---------------------------------------------------------------------------
# numpy is pinned <2: CANN 8.x op tooling is validated against the 1.x ABI.
RUN python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel \
    && python3 -m pip install --no-cache-dir \
        "numpy<2" \
        attrs \
        decorator \
        sympy \
        scipy \
        cffi \
        psutil \
        pyyaml \
        requests \
        protobuf \
        absl-py

# ---------------------------------------------------------------------------
# 3. CANN toolkit, x86_64 host side (ccec/Bisheng, ATC, TBE, op compilers)
# ---------------------------------------------------------------------------
RUN --mount=type=bind,source=deps/Ascend-cann-toolkit_${CANN_VERSION}_linux-x86_64.run,target=/tmp/cann-x86_64.run \
    bash /tmp/cann-x86_64.run --full --quiet --install-path=${ASCEND_BASE} --install-for-all \
    && rm -rf /root/toolkit_tmp /root/var/log/ascend_seclog/* /root/log 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Newer CMake for downstream consumers
# ---------------------------------------------------------------------------
# jammy ships cmake 3.22.1. That satisfies csrc/tests (needs 3.16), but the
# vllm-ascend wheel build declares cmake>=3.26 in pyproject.toml/requirements.
# Deliberately a separate layer AFTER the CANN install so the expensive toolkit
# layer stays cached when this pin moves. pip installs to /usr/local/bin, which
# precedes /usr/bin on PATH.
RUN python3 -m pip install --no-cache-dir "cmake>=3.26" \
    && cmake --version

# ---------------------------------------------------------------------------
# 5. Environment
# ---------------------------------------------------------------------------
ENV ASCEND_TOOLKIT_HOME=/usr/local/Ascend/ascend-toolkit/latest
ENV ASCEND_HOME_PATH=${ASCEND_TOOLKIT_HOME}
ENV ASCEND_OPP_PATH=${ASCEND_TOOLKIT_HOME}/opp
ENV ASCEND_AICPU_PATH=${ASCEND_TOOLKIT_HOME}
# ccec IS AT tools/ccec_compiler/bin. There is no compiler/ccec_compiler/bin in
# the 8.5.0 toolkit on either architecture - that path is from an older layout,
# and pointing PATH at it leaves `ccec` unresolved with no diagnostic until a
# kernel compile dies on "command not found".
ENV PATH=${ASCEND_TOOLKIT_HOME}/bin:${ASCEND_TOOLKIT_HOME}/tools/ccec_compiler/bin:${PATH}
# devlib LAST, and it is not optional. libascendcl.so reaches libascend_hal.so
# through its dependency chain; that library ships with the host *driver*, and
# devlib is where CANN keeps the link-time stubs for a machine without one.
# GNU ld resolves a shared library's own DT_NEEDED entries through
# LD_LIBRARY_PATH, so leaving it off breaks the LINK as well as the run:
#     ld: warning: libascend_hal.so, needed by lib64/libascend_dump.so, not found
#     ld: lib64/libruntime.so: undefined reference to `halGetDeviceInfo'
# Last on the path on purpose, so a bind-mounted real driver always wins.
ENV LD_LIBRARY_PATH=${ASCEND_TOOLKIT_HOME}/lib64:${ASCEND_TOOLKIT_HOME}/aarch64-linux/lib64:${ASCEND_TOOLKIT_HOME}/devlib:${LD_LIBRARY_PATH}
ENV PYTHONPATH=${ASCEND_TOOLKIT_HOME}/python/site-packages:${PYTHONPATH}
ENV CC_aarch64_linux_gnu=aarch64-linux-gnu-gcc
ENV CXX_aarch64_linux_gnu=aarch64-linux-gnu-g++
# Ascend310P3 -> SoC family ascend310p -> AI Core arch dav-m200
ENV SOC_VERSION=Ascend310P3
ENV ASCEND_AICORE_ARCH=dav-m200
# The CAModel is a single virtual part, so device 0 is the only device there
# is. Set globally because it is inert without a runtime that opens a device,
# and it saves every test harness and helper from having to set it.
ENV ASCEND_DEVICE_ID=0
# Read by common/patches/soc_shim.c on every halGetSocVersion call, so another
# 310P variant needs no rebuild. Safe as a global ENV because it is inert
# without the shim, and the shim is only ever loaded by ascend-sim-env.sh.
# LD_PRELOAD is deliberately NOT set globally: it would apply to apt, dpkg,
# cmake and every compiler in the image.
ARG SIM_SOC_VERSION
ENV ASCEND_SIM_SOC_VERSION=${SIM_SOC_VERSION}
# Directly consumable as -DCANN_AARCH64_ROOT by cmake/aarch64-toolchain.cmake
ENV CANN_AARCH64_ROOT=${ASCEND_TOOLKIT_HOME}/aarch64-linux
ENV ASCEND_CROSS_SYSROOT=${ASCEND_TOOLKIT_HOME}/aarch64-linux

# ---------------------------------------------------------------------------
# 6. aarch64 target sysroot
# ---------------------------------------------------------------------------
# The aarch64 .run cannot run its installer on x86_64, so the payload is
# extracted and re-laid-out. Afterwards the aarch64 devlib shipped inside the
# x86_64 package fills anything still missing.
COPY builders/builder-x86_64/assemble_sysroot.sh /usr/local/bin/assemble_sysroot.sh
RUN --mount=type=bind,source=deps/Ascend-cann-toolkit_${CANN_VERSION}_linux-aarch64.run,target=/tmp/cann-aarch64.run \
    chmod +x /usr/local/bin/assemble_sysroot.sh \
    && /usr/local/bin/assemble_sysroot.sh /tmp/cann-aarch64.run "${CANN_AARCH64_ROOT}" \
    && cp -an "${ASCEND_TOOLKIT_HOME}/x86_64-linux/devlib/aarch64/." \
              "${CANN_AARCH64_ROOT}/lib64/" 2>/dev/null || true \
    && ldconfig -n "${CANN_AARCH64_ROOT}/lib64" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. Optional: aarch64 LibTorch sysroot (only needed for the wheel build;
#    csrc/tests deliberately builds without Python/PyTorch/torch_npu)
# ---------------------------------------------------------------------------
# The whole context is bind-mounted rather than a single file, so the build
# still succeeds when the wheel was not downloaded.
ENV LIBTORCH_AARCH64_ROOT=/opt/libtorch-aarch64
RUN --mount=type=bind,target=/ctx \
    if [ "${WITH_LIBTORCH}" = "1" ]; then \
        whl=$(ls /ctx/deps/torch-*-cp310-cp310-manylinux_2_28_aarch64.whl 2>/dev/null | head -1); \
        if [ -n "$whl" ]; then \
            mkdir -p /tmp/lt && unzip -q "$whl" 'torch/lib/*' 'torch/include/*' -d /tmp/lt && \
            mkdir -p "${LIBTORCH_AARCH64_ROOT}" && \
            mv /tmp/lt/torch/lib /tmp/lt/torch/include "${LIBTORCH_AARCH64_ROOT}/" && \
            rm -rf /tmp/lt && \
            echo "libtorch aarch64: $(find ${LIBTORCH_AARCH64_ROOT}/lib -name '*.so' | wc -l) libs"; \
        else \
            echo "WITH_LIBTORCH=1 but no aarch64 torch wheel in context" >&2; exit 1; \
        fi; \
    else \
        echo "libtorch not requested (WITH_LIBTORCH=0)"; \
    fi

# ---------------------------------------------------------------------------
# 8. Ascend 310P operator package
# ---------------------------------------------------------------------------
# THE TOOLKIT .run IS NOT A COMPLETE CANN INSTALL. It ships libopapi_oam.so and
# no libopapi.so, and an opp/built-in that contains op_impl and nothing else -
# 15 MB against the 1.6 GB the vendor image carries.
#
# csrc/tests dlopens libopapi.so (common/aclnn_runtime.cpp) and resolves every
# operator out of it, so against the bare toolkit the whole suite skips:
#     [ascend-test] failed to load libopapi.so; source the CANN set_env.sh first
#
# TWO HALVES, AND THE SECOND IS THE ONE THAT IS EASY TO MISS. Staging the
# binary kernels alone is not enough - aclnn resolves a HOST-SIDE TILING
# FUNCTION per operator out of op_tiling/lib/linux/x86_64/liboptiling.so, and
# the toolkit has no op_tiling directory at all. Without it every device case
# fails at plan time, which reads like a missing kernel and is not:
#     aclnnRmsNormGetWorkspaceSize failed with status 561002
#     AclNN_Inner_Error(EZ9999): Do not find tiling func of RmsNorm!
#
# AND THE opp TREE GOES IN WHOLE, ops_legacy INCLUDED. It is tempting to drop
# ops_legacy: it is 3.8 GB of the 3.9 GB ascend310p kernel tree, and the aclnn
# entry points the suite calls all live in ops_nn and ops_transformer. But the
# entry point is not the kernel. aclnnMatmul lowers to a graph that launches
# TransData around MatMul, and both are legacy ops, so a trimmed tree fails at
# run time - one operator at a time, with an error that names a file:
#     aclnnMatmulGetWorkspaceSize failed with status 561103
#     cannot open op kernel bin json file [], reason : No such file or directory
#     failed to get op kenrel bin json [.../ops_legacy/trans_data/TransData_*.json]
# The closure is not readable off the operator names, so the whole tree ships.
# That is what takes the image from ~7 GB to ~13 GB.
#
# The operator package that fills this is Ascend-cann-kernels-310p_8.5.0_*.run
# and Huawei does not publish it: every kernels .run 403s from the OBS bucket
# while the toolkit and NNAL answer 206. provision.sh lifts the same bytes out
# of the vendor image instead - the route targets/target-310p already takes for
# libhccl.so and targets/target-950pr for its 26 cann_extra libraries.
#
# The whole context is bind-mounted rather than a single path, so a
# WITH_SIMULATOR=0 build still succeeds with no deps/builder-x86_64 present.
# Nothing is COPYed, so neither the installer nor the staging tree lands in a
# layer - only what this RUN writes into the toolkit.
ARG WITH_SIMULATOR
RUN --mount=type=bind,target=/ctx \
    set -eux; \
    TK="${ASCEND_TOOLKIT_HOME}"; \
    if [ "${WITH_SIMULATOR}" != "1" ]; then \
        echo "operator package not requested (WITH_SIMULATOR=0)"; \
    else \
        payload=/ctx/deps/builder-x86_64; \
        run="$(ls "$payload"/Ascend-cann-kernels-310p_*.run 2>/dev/null | head -1 || true)"; \
        if [ -n "$run" ]; then \
            echo "installing $(basename "$run")"; \
            bash "$run" --quiet --install --install-path="${ASCEND_BASE}" --install-for-all; \
        elif [ -d "$payload/kernels-310p" ]; then \
            echo "staging the operator package lifted from the vendor image"; \
            cp -a "$payload/kernels-310p/lib64/." "${TK}/lib64/"; \
            cp -a "$payload/kernels-310p/opp/."   "${TK}/opp/"; \
            chmod 0755 "${TK}"/lib64/libopapi*.so; \
        else \
            echo "WITH_SIMULATOR=1 but deps/builder-x86_64 has neither a kernels" >&2; \
            echo ".run nor kernels-310p/. Run ./builders/builder-x86_64/provision.sh" >&2; \
            exit 1; \
        fi; \
        ldconfig; \
        K="${TK}/opp/built-in/op_impl/ai_core/tbe/kernel/ascend310p"; \
        test -f "${TK}/lib64/libopapi.so"; \
        test -d "$K"; \
        test -f "${TK}/opp/built-in/op_impl/ai_core/tbe/op_tiling/lib/linux/x86_64/liboptiling.so"; \
        test -d "$K/ops_legacy/mat_mul"; \
        test -d "$K/ops_legacy/trans_data"; \
        nm -D "${TK}/lib64/libopapi.so" > /tmp/opapi.syms; \
        grep -q aclnnRmsNorm /tmp/opapi.syms; \
        rm -f /tmp/opapi.syms; \
        echo "operator package: $(ls "${TK}"/lib64/libopapi*.so | wc -l) libopapi libraries," \
             "$(find "$K" -type f | wc -l) kernels," \
             "$(find "$K/ops_legacy" -maxdepth 1 -mindepth 1 -type d | wc -l) legacy operators"; \
    fi

# ---------------------------------------------------------------------------
# 9. CAModel simulator wiring
# ---------------------------------------------------------------------------
# The toolkit already ships the simulator at tools/simulator/<SoC>/lib on BOTH
# architectures; nothing is downloaded here. Two pieces are staged so that
# /usr/local/bin/ascend-sim-env.sh can put them in front of the real runtime:
#
#   libsocshim.so   one function. See common/patches/soc_shim.c: CANN reads the
#                   part number through halGetSocVersion, the only
#                   libascend_hal.so on a machine with no NPU is devlib's stub,
#                   and that stub returns SUCCESS without writing the buffer.
#
#   libruntime.so -> libruntime_camodel.so
#                   for anything that dlopens the runtime by name instead of
#                   inheriting the preload. Note this symlink is NOT how the
#                   swap is done - preloading libruntime_camodel.so is; a
#                   symlink-only setup boots the model and then crashes the
#                   RT_RECV heartbeat thread in DriverFactory::GetDriver. The
#                   measured matrix is in ascend-sim-env.sh.
#
# The activation script is installed under both names: ascend-sim-env.sh, which
# is what the repository and verify.sh call it, and enable-cann-sim.sh, which
# reads more obviously at a shell prompt. Same file, either spelling works
# sourced or as a wrapper.
#
# -Werror is not decoration. The first revision of the shim omitted <stdlib.h>,
# getenv was implicitly int, and the truncated pointer segfaulted the process
# inside the dynamic loader before main(), with no diagnostic at all.
COPY common/patches/soc_shim.c /opt/ascend-sim/src/soc_shim.c
COPY builders/builder-x86_64/ascend-sim-env.sh /usr/local/bin/ascend-sim-env.sh
RUN set -eux; \
    chmod 0755 /usr/local/bin/ascend-sim-env.sh; \
    ln -sf /usr/local/bin/ascend-sim-env.sh /usr/local/bin/enable-cann-sim.sh; \
    SIM="${ASCEND_TOOLKIT_HOME}/tools/simulator/${ASCEND_SIM_SOC_VERSION}/lib"; \
    test -f "${SIM}/libruntime_camodel.so"; \
    test -f "${SIM}/libnpu_drv_camodel.so"; \
    mkdir -p /opt/ascend-sim/lib; \
    gcc -m64 -shared -fPIC -O2 -Wall -Wextra -Werror \
        -o /opt/ascend-sim/lib/libsocshim.so /opt/ascend-sim/src/soc_shim.c; \
    nm -D --defined-only /opt/ascend-sim/lib/libsocshim.so > /tmp/shim.syms; \
    grep -q halGetSocVersion /tmp/shim.syms; \
    rm -f /tmp/shim.syms; \
    ln -sf "${SIM}/libruntime_camodel.so" /opt/ascend-sim/lib/libruntime.so; \
    ls -l /opt/ascend-sim/lib

# ---------------------------------------------------------------------------
# 10. googletest, unpacked
# ---------------------------------------------------------------------------
# csrc/tests declares googletest with GIT_REPOSITORY, so a plain configure
# clones from github.com. FETCHCONTENT_SOURCE_DIR_GOOGLETEST short-circuits
# that to a local tree. CMake reads it from the cache, not the environment, so
# it has to be passed on the configure line; README.md documents the flag and
# verify.sh exercises it.
ENV GOOGLETEST_SOURCE_DIR=/opt/googletest
RUN --mount=type=bind,target=/ctx \
    set -eux; \
    tgz="$(ls /ctx/deps/builder-x86_64/googletest-*.tar.gz 2>/dev/null | head -1 || true)"; \
    if [ -z "$tgz" ]; then \
        echo "no googletest tarball staged; csrc/tests will need network or"; \
        echo "-DVLLM_ASCEND_TESTS_FETCH_GTEST=OFF with a system install"; \
    else \
        mkdir -p "${GOOGLETEST_SOURCE_DIR}"; \
        tar xzf "$tgz" -C "${GOOGLETEST_SOURCE_DIR}" --strip-components=1; \
        test -f "${GOOGLETEST_SOURCE_DIR}/googletest/CMakeLists.txt"; \
        echo "googletest staged at ${GOOGLETEST_SOURCE_DIR}"; \
    fi

# ---------------------------------------------------------------------------
# 11. Verification
# ---------------------------------------------------------------------------
# Last, so editing the suite rebuilds in seconds instead of re-running the CANN
# install, the sysroot assembly and the 1.8 GB operator staging.
COPY builders/builder-x86_64/verify.sh /usr/local/bin/verify-cann-cross.sh
RUN chmod +x /usr/local/bin/verify-cann-cross.sh

WORKDIR /work
CMD ["/bin/bash"]
