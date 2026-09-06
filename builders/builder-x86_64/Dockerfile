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

# ---------------------------------------------------------------------------
# 1. System toolchain + CANN runtime dependencies
# ---------------------------------------------------------------------------
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
ENV PATH=${ASCEND_TOOLKIT_HOME}/bin:${ASCEND_TOOLKIT_HOME}/compiler/ccec_compiler/bin:${PATH}
ENV LD_LIBRARY_PATH=${ASCEND_TOOLKIT_HOME}/lib64:${ASCEND_TOOLKIT_HOME}/aarch64-linux/lib64:${LD_LIBRARY_PATH}
ENV PYTHONPATH=${ASCEND_TOOLKIT_HOME}/python/site-packages:${PYTHONPATH}
ENV CC_aarch64_linux_gnu=aarch64-linux-gnu-gcc
ENV CXX_aarch64_linux_gnu=aarch64-linux-gnu-g++
# Ascend310P3 -> SoC family ascend310p -> AI Core arch dav-m200
ENV SOC_VERSION=Ascend310P3
ENV ASCEND_AICORE_ARCH=dav-m200
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

COPY builders/builder-x86_64/verify.sh /usr/local/bin/verify-cann-cross.sh
RUN chmod +x /usr/local/bin/verify-cann-cross.sh

WORKDIR /work
CMD ["/bin/bash"]
