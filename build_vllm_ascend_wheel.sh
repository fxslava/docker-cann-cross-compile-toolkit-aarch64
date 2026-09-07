#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Offline cross-build of a vllm-ascend wheel for Ascend 310P3 / AArch64.
#
# Installed into the image as /usr/local/bin/build-vllm-ascend-wheel.sh.
#
#   docker run --rm --network none \
#     -v "$PWD/deps":/opt/offline-deps:ro -v "$PWD/dist":/work/dist \
#     cann85-cross-310p:latest build-vllm-ascend-wheel.sh
#
# NOT ONE BYTE OF NETWORK IS USED. Every pip call carries --no-index and is
# pointed at a --find-links wheelhouse produced by download_deps.sh, and the
# source archive comes from deps/src/. Run the container with --network none
# and it still succeeds; that is the acceptance test, not a slogan.
#
# ---------------------------------------------------------------------------
# HOW A CROSS BUILD OF vllm-ascend IS EVEN POSSIBLE
#
# vllm-ascend's setup.py was written for a native build and does three things
# that a naive cross build trips over:
#
#   1. cmake/utils.cmake runs `import torch; print(torch.__version__)` and
#      `import torch; print(torch.utils.cmake_prefix_path)` with the BUILD
#      interpreter. The build interpreter here is x86_64, so importing the
#      AArch64 torch wheel is impossible - its libtorch_cpu.so is ARM64.
#      => a two-attribute `torch` SHIM is put first on PYTHONPATH. It reports
#         the pinned version and points CMAKE_PREFIX_PATH at the AArch64
#         wheel's share/cmake tree, which is what find_package(Torch) needs.
#         The real .so files are never dlopen()ed on the host.
#
#   2. setup.py shells out to `python3 -m pip show torch-npu` to locate
#      TORCH_NPU_PATH.
#      => the AArch64 torch_npu wheel is unpacked with `pip install --target`
#         into a staging root that is also on PYTHONPATH, so `pip show` finds
#         a real .dist-info and reports that staging root as its Location.
#
#   3. setup.py builds its own cmake command line and never offers
#      -DCMAKE_TOOLCHAIN_FILE.
#      => CMAKE_TOOLCHAIN_FILE is exported as an ENVIRONMENT variable, which
#         CMake honours (documented since 3.21).
#
# SOC_VERSION deserves its own warning. CANN's own tooling spells it
# `Ascend310P3`; vllm-ascend's setup.py looks it up in a lowercase table and
# asserts on a miss, so it needs `ascend310p3`. The image ENV carries the CANN
# spelling, this script exports the vllm-ascend spelling for the build only.
# For SOC_VERSION matching ascend310p*, vllm-ascend's CMakeLists deliberately
# SKIPS the ascendc_library() device-kernel target, so a 310P3 build compiles
# csrc/*.cpp plus csrc/aclnn_torch_adapter/*.cpp into the vllm_ascend_C
# pybind11 extension and nothing else.
# ---------------------------------------------------------------------------
set -euo pipefail

SELF="$(basename "$0")"

# --------------------------- defaults --------------------------------------
OFFLINE_DEPS="${OFFLINE_DEPS:-/opt/offline-deps}"
WHEELS_TARGET="${WHEELS_TARGET:-$OFFLINE_DEPS/python_wheels}"
WHEELS_BUILD="${WHEELS_BUILD:-/opt/build-wheels}"     # baked into the image
SRC_ARG=""
OUT_DIR="${OUT_DIR:-/work/dist}"
WORK_DIR="${WORK_DIR:-/tmp/vllm-ascend-build}"
DRY_RUN=0
KEEP=0
JOBS="${MAX_JOBS:-$(nproc)}"

SOC="${VLLM_ASCEND_SOC:-ascend310p3}"                 # vllm-ascend spelling
AICORE_ARCH="${ASCEND_AICORE_ARCH:-dav-m200}"
PLAT_NAME="${PLAT_NAME:-manylinux_2_28_aarch64}"
PY_TAG="${PY_TAG:-310}"

TORCH_PIN="${TORCH_PIN:-torch==2.10.0}"
TORCH_NPU_PIN="${TORCH_NPU_PIN:-torch-npu==2.10.0.post4}"

TOOLCHAIN="${CROSS_TOOLCHAIN_FILE:-/opt/cross/aarch64-toolchain.cmake}"
CANN_ROOT="${CANN_AARCH64_ROOT:-/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux}"
LIBTORCH_ROOT="${LIBTORCH_AARCH64_ROOT:-/opt/libtorch-aarch64}"
PYSYSROOT="${CROSS_PYTHON_SYSROOT:-/opt/cross/aarch64-python-sysroot}"

usage() {
    sed -n '2,12p' "$0"
    cat <<EOF

Options
  --src <path>        vllm-ascend source: a directory, or an sdist .tar.gz.
                      Default: newest \$OFFLINE_DEPS/src/vllm_ascend-*.tar.gz
  --wheels <dir>      AArch64 target wheelhouse (default \$OFFLINE_DEPS/python_wheels)
  --out <dir>         where the finished wheel is written (default $OUT_DIR)
  --soc <name>        vllm-ascend SoC name, lowercase (default $SOC)
  --jobs <n>          parallel compile jobs (default: nproc)
  --dry-run           stage everything and run the CMake CONFIGURE step, then
                      stop. Proves the bundle is complete and the offline
                      toolchain resolves, without a full compile.
  --keep              keep \$WORK_DIR after the run
  -h, --help          this text
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --src)     SRC_ARG="$2"; shift 2 ;;
        --wheels)  WHEELS_TARGET="$2"; shift 2 ;;
        --out)     OUT_DIR="$2"; shift 2 ;;
        --soc)     SOC="$2"; shift 2 ;;
        --jobs)    JOBS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --keep)    KEEP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         echo "$SELF: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

say()  { echo "[build] $*"; }
step() { echo; echo "=== $*"; }
die()  { echo "[build] ERROR: $*" >&2; exit 1; }

PIP=(python3 -m pip --disable-pip-version-check --no-cache-dir)
# Belt and braces: even if a stray requirement slipped through, pip must not
# be able to reach an index.
export PIP_NO_INDEX=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_ROOT_USER_ACTION=ignore

# ===========================================================================
step "0. offline bundle sanity"
# ===========================================================================
[ -d "$WHEELS_TARGET" ] || die "target wheelhouse not found at $WHEELS_TARGET
Mount it:  -v \$PWD/deps:/opt/offline-deps:ro   (see download_deps.sh)"
nwheels=$(find "$WHEELS_TARGET" -name '*.whl' | wc -l)
[ "$nwheels" -gt 0 ] || die "$WHEELS_TARGET holds no wheels"
say "target wheelhouse : $WHEELS_TARGET ($nwheels wheels)"

if [ -d "$WHEELS_BUILD" ] && [ -n "$(find "$WHEELS_BUILD" -name '*.whl' -print -quit)" ]; then
    say "build wheelhouse  : $WHEELS_BUILD ($(find "$WHEELS_BUILD" -name '*.whl' | wc -l) wheels)"
else
    say "build wheelhouse  : absent; relying on what is already installed in the image"
    WHEELS_BUILD=""
fi

if [ -z "$SRC_ARG" ]; then
    SRC_ARG=$(ls -1t "$OFFLINE_DEPS"/src/vllm_ascend-*.tar.gz 2>/dev/null | head -1 || true)
    [ -n "$SRC_ARG" ] || die "no source given and no sdist under $OFFLINE_DEPS/src/
Run:  ./download_deps.sh . --only src"
fi
say "source            : $SRC_ARG"
say "toolchain         : $TOOLCHAIN"
say "SOC_VERSION       : $SOC   (AI Core $AICORE_ARCH)"

[ -f "$TOOLCHAIN" ] || die "toolchain file missing: $TOOLCHAIN"
[ -d "$CANN_ROOT/lib64" ] || die "CANN AArch64 sysroot missing: $CANN_ROOT/lib64"

# Clear the CONTENTS rather than the directory: WORK_DIR is often a bind mount
# (that is how you keep the build tree around after --rm), and rmdir'ing a
# mount point fails with EBUSY.
mkdir -p "$WORK_DIR" "$OUT_DIR"
find "$WORK_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
[ "$KEEP" = "1" ] || trap 'rm -rf "$WORK_DIR"' EXIT

XROOT="$WORK_DIR/cross-site"       # pip --target staging root (AArch64)
SHIM="$WORK_DIR/shim"              # host-importable torch stand-in
SRC_DIR="$WORK_DIR/src"
mkdir -p "$XROOT" "$SHIM" "$SRC_DIR"

# ===========================================================================
step "1. unpack the source"
# ===========================================================================
if [ -d "$SRC_ARG" ]; then
    cp -a "$SRC_ARG/." "$SRC_DIR/"
else
    tar -xzf "$SRC_ARG" -C "$SRC_DIR" --strip-components=1
fi
[ -f "$SRC_DIR/setup.py" ] || die "no setup.py under $SRC_DIR"
say "unpacked $(du -sh "$SRC_DIR" | cut -f1) of source"

# --------------------------------------------------------------------------
# Build-time third-party sources, staged where the vendored CANN op-project
# build system looks for them BEFORE it decides to download.
#
#   csrc/cmake/third_party/makeself-fetch.cmake:
#     set(MAKESELF_PATH ${CANN_3RD_LIB_PATH}/makeself)
#     if (NOT EXISTS "${MAKESELF_PATH}/makeself.sh") ... FetchContent(URL) ...
#
# and csrc/build_aclnn.sh sets CANN_3RD_LIB_PATH=<src>/csrc/third_party.
# Populating it is upstream's own escape hatch, so the download branch is
# never reached and `--network none` holds. Without this the op build dies at
#   error: downloading '.../makeself-release-2.5.0-patch1.tar.gz' failed
#   make: *** No rule to make target 'prepare_build'.  Stop.
CANN_3RD="$SRC_DIR/csrc/third_party"
mkdir -p "$CANN_3RD"
ms_tar=$(ls -1t "$OFFLINE_DEPS"/src/third_party/makeself-*.tar.gz 2>/dev/null | head -1 || true)
if [ -n "$ms_tar" ]; then
    if [ ! -f "$CANN_3RD/makeself/makeself.sh" ]; then
        mkdir -p "$CANN_3RD/makeself"
        # --strip-components=1: the release tarball wraps everything in a
        # single makeself-release-<ver>/ directory, but the cmake module
        # expects makeself.sh directly under $CANN_3RD_LIB_PATH/makeself.
        tar -xzf "$ms_tar" -C "$CANN_3RD/makeself" --strip-components=1
        chmod +x "$CANN_3RD/makeself"/*.sh 2>/dev/null || true
    fi
    [ -f "$CANN_3RD/makeself/makeself.sh" ] \
        && say "staged makeself   : $CANN_3RD/makeself (offline, no FetchContent)" \
        || die "makeself staging produced no makeself.sh from $ms_tar"
else
    echo "[build] WARN: no makeself tarball under $OFFLINE_DEPS/src/third_party/." >&2
    echo "[build] WARN: the custom-op build will try to download it and fail" >&2
    echo "[build] WARN: under --network none. Run ./download_deps.sh . --only src" >&2
fi

# setuptools_scm refuses to derive a version outside a VCS checkout. The sdist
# already carries PKG-INFO, so pin the version explicitly instead of letting
# scm guess "0.1.dev1".
SDIST_VERSION=$(awk '/^Version: /{print $2; exit}' "$SRC_DIR/PKG-INFO" 2>/dev/null || true)
if [ -n "$SDIST_VERSION" ]; then
    export SETUPTOOLS_SCM_PRETEND_VERSION="$SDIST_VERSION"
    say "version           : $SDIST_VERSION (SETUPTOOLS_SCM_PRETEND_VERSION)"
fi

# ===========================================================================
step "2. host build tools (x86_64) from the offline wheelhouse"
# ===========================================================================
if [ -n "$WHEELS_BUILD" ]; then
    "${PIP[@]}" install --no-index --find-links "$WHEELS_BUILD" \
        pip setuptools setuptools-scm wheel pybind11 "cmake>=3.26" ninja \
        || die "host build tools could not be installed offline from $WHEELS_BUILD"
fi
python3 -m pybind11 --cmakedir >/dev/null 2>&1 \
    || die "pybind11 is not importable; setup.py calls 'python -m pybind11 --cmakedir'"
say "pybind11 cmakedir : $(python3 -m pybind11 --cmakedir)"
say "cmake             : $(cmake --version | head -1)"

# ===========================================================================
step "3. stage the AArch64 target packages (never imported, only unpacked)"
# ===========================================================================
# --target + --platform makes pip unpack a foreign-architecture wheel without
# executing anything from it. --only-binary=:all: is mandatory in that mode.
"${PIP[@]}" install --no-index --find-links "$WHEELS_TARGET" \
    --target "$XROOT" --no-deps --upgrade \
    --only-binary=:all: --python-version "$PY_TAG" --implementation cp \
    --platform manylinux_2_28_aarch64 \
    --platform manylinux_2_17_aarch64 \
    --platform manylinux2014_aarch64 \
    --platform linux_aarch64 \
    "$TORCH_PIN" "$TORCH_NPU_PIN" \
    || die "could not stage $TORCH_PIN / $TORCH_NPU_PIN from $WHEELS_TARGET"

[ -f "$XROOT/torch/share/cmake/Torch/TorchConfig.cmake" ] \
    || die "staged torch has no share/cmake/Torch/TorchConfig.cmake"
say "staged torch      : $XROOT/torch ($(find "$XROOT/torch/lib" -name '*.so' 2>/dev/null | wc -l) libs)"
say "staged torch_npu  : $XROOT/torch_npu"

# Confirm the staged libraries really are AArch64 before anything links them.
_probe=$(find "$XROOT/torch/lib" -name 'libtorch_cpu.so' -print -quit 2>/dev/null || true)
if [ -n "$_probe" ]; then
    _mach=$(readelf -h "$_probe" 2>/dev/null | awk -F: '/Machine:/{gsub(/^ +/,"",$2);print $2}')
    [ "$_mach" = "AArch64" ] || die "staged libtorch_cpu.so is $_mach, expected AArch64"
    say "staged ELF machine: $_mach"
fi

# ===========================================================================
step "4. torch import shim for the x86_64 build interpreter"
# ===========================================================================
mkdir -p "$SHIM/torch/utils"
TORCH_STAGED_VERSION=$(sed -n 's/^Version: //p' \
    "$(ls -d "$XROOT"/torch-*.dist-info 2>/dev/null | head -1)/METADATA" 2>/dev/null | head -1)
TORCH_STAGED_VERSION="${TORCH_STAGED_VERSION:-${TORCH_PIN#*==}}"
# vllm-ascend's CMakeLists does VERSION_EQUAL "2.10.0"; a local version
# segment such as +cpu would fail that comparison, so report the public part.
TORCH_PUBLIC_VERSION="${TORCH_STAGED_VERSION%%+*}"

cat > "$SHIM/torch/__init__.py" <<PYEOF
"""Cross-compilation stand-in for the AArch64 torch wheel.

vllm-ascend's cmake/utils.cmake only ever asks this package two questions:

    import torch; print(torch.__version__)
    import torch; print(torch.utils.cmake_prefix_path)

Answering them here lets find_package(Torch) resolve against the AArch64
wheel staged at ${XROOT} without this x86_64 interpreter having to dlopen an
ARM64 libtorch_cpu.so. Anything beyond those two attributes is a bug in the
assumptions this shim is built on, so it raises loudly rather than lying.
"""
__version__ = "${TORCH_PUBLIC_VERSION}"
__cross_staging_root__ = "${XROOT}"

# NB: __path__ is deliberately left as the import machinery set it, i.e.
# pointing at this shim directory. Repointing it at the staged AArch64 wheel
# would make the line below import the REAL torch.utils, which pulls in
# torch._C and dies on an ARM64 shared object.
from . import utils  # noqa: E402,F401


def __getattr__(name):
    raise AttributeError(
        "torch.%s is not available: this is the cross-compilation shim from "
        "build-vllm-ascend-wheel.sh, not the real AArch64 torch package "
        "(which cannot be imported on an x86_64 host)." % name
    )
PYEOF

cat > "$SHIM/torch/utils/__init__.py" <<PYEOF
cmake_prefix_path = "${XROOT}/torch/share/cmake"
PYEOF

export PYTHONPATH="$SHIM:$XROOT${PYTHONPATH:+:$PYTHONPATH}"
say "shim reports      : torch $(python3 -c 'import torch; print(torch.__version__)')"
say "cmake_prefix_path : $(python3 -c 'import torch; print(torch.utils.cmake_prefix_path)')"
# setup.py resolves TORCH_NPU_PATH through this exact command.
say "pip show torch-npu: $(python3 -m pip show torch-npu 2>/dev/null | sed -n 's/^Location: //p')"
python3 -m pip show torch-npu >/dev/null 2>&1 \
    || die "'pip show torch-npu' fails; setup.py needs it to compute TORCH_NPU_PATH"

# ===========================================================================
step "5. cross-compilation environment for $SOC"
# ===========================================================================
export CMAKE_TOOLCHAIN_FILE="$TOOLCHAIN"
export CANN_AARCH64_ROOT="$CANN_ROOT"
export CROSS_STAGE_ROOT="$XROOT"
export ASCEND_AICORE_ARCH="$AICORE_ARCH"
if [ -d "$LIBTORCH_ROOT/lib" ]; then export LIBTORCH_AARCH64_ROOT="$LIBTORCH_ROOT"; else unset LIBTORCH_AARCH64_ROOT || true; fi
if [ -d "$PYSYSROOT/usr/include" ]; then export CROSS_PYTHON_SYSROOT="$PYSYSROOT"; else unset CROSS_PYTHON_SYSROOT || true; fi

# Read by vllm_ascend/envs.py.
export SOC_VERSION="$SOC"
export CXX_COMPILER="aarch64-linux-gnu-g++"
export C_COMPILER="aarch64-linux-gnu-gcc"
export CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
export MAX_JOBS="$JOBS"

# -std=c++17 is not optional: the Ascend C headers use C++14+ constexpr and
# the torch headers require 17. It is set on the toolchain file too; repeated
# here so a direct compiler invocation from setup.py also gets it.
export CXXFLAGS="-std=c++17 ${CXXFLAGS:-}"

# Any FetchContent() in a transitive CMake dependency would try to clone.
# Point it at a directory that can only ever be a cache hit.
export FETCHCONTENT_BASE_DIR="$WORK_DIR/.deps"
export FETCHCONTENT_FULLY_DISCONNECTED=ON
mkdir -p "$FETCHCONTENT_BASE_DIR"

for v in SOC_VERSION ASCEND_AICORE_ARCH CMAKE_TOOLCHAIN_FILE CANN_AARCH64_ROOT \
         CROSS_STAGE_ROOT LIBTORCH_AARCH64_ROOT CROSS_PYTHON_SYSROOT \
         CXX_COMPILER CXXFLAGS MAX_JOBS; do
    printf '  %-24s %s\n' "$v" "${!v:-<unset>}"
done

if [ -z "${CROSS_PYTHON_SYSROOT:-}" ]; then
    echo "[build] WARN: no AArch64 Python sysroot at $PYSYSROOT." >&2
    echo "[build] WARN: the extension will be compiled against this host's pyconfig.h." >&2
    echo "[build] WARN: run './download_deps.sh . --only apt' and rebuild the image to fix." >&2
fi

# ===========================================================================
step "6. CMake configure"
# ===========================================================================
# Run the configure step by hand first. It is the cheap half of the build and
# it is where every offline / cross problem shows up, so failing here gives a
# far better message than failing 300 objects into `setup.py bdist_wheel`.
CONF_DIR="$WORK_DIR/cmake-probe"
mkdir -p "$CONF_DIR"
set +e
cmake -S "$SRC_DIR" -B "$CONF_DIR" \
    -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DSOC_VERSION="$SOC" \
    -DASCEND_HOME_PATH="${ASCEND_TOOLKIT_HOME:-/usr/local/Ascend/ascend-toolkit/latest}" \
    -DPYTHON_EXECUTABLE="$(command -v python3)" \
    -DPYTHON_INCLUDE_PATH="$(python3 -c 'import sysconfig;print(sysconfig.get_paths()["include"])')" \
    -DTORCH_NPU_PATH="$XROOT/torch_npu" \
    -DCMAKE_PREFIX_PATH="$(python3 -m pybind11 --cmakedir)" \
    > "$WORK_DIR/cmake-configure.log" 2>&1
conf_rc=$?
set -e
if [ "$conf_rc" -ne 0 ]; then
    echo "[build] CMake configure FAILED (exit $conf_rc). Last 40 lines:" >&2
    tail -40 "$WORK_DIR/cmake-configure.log" >&2
    if [ "$KEEP" = "1" ]; then
        echo "[build] full log kept at $WORK_DIR/cmake-configure.log" >&2
    else
        echo "[build] re-run with --keep to retain $WORK_DIR/cmake-configure.log" >&2
    fi
    exit "$conf_rc"
fi
grep -E 'Detected SOC version|Hardware .* detected|TORCH_NPU_PATH' "$WORK_DIR/cmake-configure.log" || true
say "CMake configure succeeded"

if [ "$DRY_RUN" = "1" ]; then
    step "dry run complete"
    say "the offline bundle is complete and the cross toolchain resolves."
    say "drop --dry-run to produce the wheel."
    exit 0
fi

# ===========================================================================
step "7. build the wheel"
# ===========================================================================
cd "$SRC_DIR"
# No build isolation: isolation would make pip create a fresh venv and fetch
# the build backend from an index, which is exactly what must not happen.
set +e
python3 setup.py bdist_wheel --plat-name "$PLAT_NAME" --dist-dir "$OUT_DIR" \
    2>&1 | tee "$WORK_DIR/wheel-build.log"
build_rc=${PIPESTATUS[0]}
set -e

if [ "$build_rc" -ne 0 ]; then
    echo >&2
    # ------------------------------------------------------------------
    # Recognise the one failure that is NOT this repository's to fix, and
    # say so precisely instead of leaving 700 lines of make output.
    # ------------------------------------------------------------------
    if grep -q 'opbuild_gen\|op_build\|build_aclnn' "$WORK_DIR/wheel-build.log"; then
        cat >&2 <<'DIAG'
[build] ================================================================
[build] The vllm_ascend_C extension configured and the op host libraries
[build] cross-compiled, but vllm-ascend's CUSTOM ASCEND OPERATOR step
[build] (csrc/build_aclnn.sh) cannot be cross-compiled. This is a
[build] structural property of CANN's op-project build system, not a
[build] misconfiguration here:
[build]
[build]   <cann>/tools/opbuild/op_build          is an x86-64 executable
[build]   build/prepare_build/libop_host_aclnn.so is what we just built,
[build]                                           and it is AArch64
[build]
[build] op_build has to dlopen() that library to code-generate the aclnn
[build] sources. The op-host library therefore has to be BUILD-arch to be
[build] loadable and TARGET-arch to be shippable, and upstream's build
[build] produces it exactly once.
[build]
[build] What still works, and is verified:
[build]   * build-vllm-ascend-wheel.sh --dry-run  (staging + CMake configure
[build]     of the pybind11 extension, fully offline)
[build]   * verify-cann-cross.sh                 (Ascend C kernel for
[build]     dav-m200 + AArch64 ACL cross link, fully offline)
[build]
[build] To get a wheel with the custom operators, build them NATIVELY on
[build] aarch64 - under qemu/binfmt (docker run --platform linux/arm64) or
[build] on the 310P3 itself - using this same offline wheelhouse.
[build] ================================================================
DIAG
    fi
    die "wheel build failed (full log: $WORK_DIR/wheel-build.log)"
fi

step "8. result"
ls -la "$OUT_DIR"/*.whl
for w in "$OUT_DIR"/*.whl; do
    echo "  $(basename "$w")  $(du -h "$w" | cut -f1)  sha256=$(sha256sum "$w" | cut -c1-16)..."
done
say "copy the wheel AND deps/python_wheels to the 310P3 server, then:"
say "  pip install --no-index --find-links=<wheelhouse> <wheel>"
