#!/bin/bash
# Builds vLLM from source with VLLM_TARGET_DEVICE=empty.
# Runs inside a container matching the target's base image and interpreter.
#
#   SRC              vLLM source tree                [/src/vllm]
#   OUT              wheel output directory          [/out]
#   CONSTRAINTS      pip constraint file             [/prov/constraints.txt]
#   PLAT_NAME        wheel platform tag              [manylinux_2_28_x86_64]
#   EXTRA_INDEXES    space-separated index URLs      []
#   SETUPTOOLS_SPEC  build-backend pin               [setuptools>=77.0.3,<81.0.0]
#   BUILD_DEPS       module-scope imports of setup.py
#   EMULATED         1 under qemu-user               [0]
#
# The published vllm wheel is a CUDA build on both architectures. It resolves
# cleanly and produces an image that imports and dispatches to nothing; the
# Ascend backend lives entirely in vllm-ascend.
#
# VLLM_TARGET_DEVICE=empty also selects setup.py's _no_device() requirement set,
# which reads requirements/common.txt - naming no torch, nvidia or cuda
# requirement at all. The sdist's PKG-INFO is generated for the CUDA target and
# pins torch far ahead of what torch_npu is compiled against. The empty-target
# wheel stays silent about torch and lets the plugin's pins govern.
set -eu
export DEBIAN_FRONTEND=noninteractive
. /common/container_prelude.sh

SRC="${SRC:-/src/vllm}"
OUT="${OUT:-/out}"
CONSTRAINTS="${CONSTRAINTS:-/prov/constraints.txt}"
PLAT_NAME="${PLAT_NAME:-manylinux_2_28_x86_64}"
EXTRA_INDEXES="${EXTRA_INDEXES:-}"
SETUPTOOLS_SPEC="${SETUPTOOLS_SPEC:-setuptools>=77.0.3,<81.0.0}"
EMULATED="${EMULATED:-0}"

# setup.py imports these at module scope, before it reads VLLM_TARGET_DEVICE.
# Omitting setuptools-rust gives ModuleNotFoundError from
# `from setuptools_rust.build import build_rust` on refs that carry it.
BUILD_DEPS="${BUILD_DEPS:-torch cmake ninja packaging jinja2 regex setuptools-rust>=1.9.0}"

prelude_network
[ "$EMULATED" = "1" ] && prelude_ldconfig_stub on
prelude_apt_install build-essential git python3 python3-dev python3-pip ca-certificates
[ "$EMULATED" = "1" ] && prelude_ldconfig_stub off

idx=""
for u in $EXTRA_INDEXES; do idx="$idx --extra-index-url $u"; done

# SETUPTOOLS_SPEC is bounded because this builds through setup.py directly
# rather than PEP 517, so nothing else enforces vLLM's [build-system] range.
python3 -m pip install --no-cache-dir -q $PIP_NET --upgrade \
    pip "$SETUPTOOLS_SPEC" setuptools-scm wheel

# --find-links $OUT first: the torch stack is pre-seeded into the wheelhouse
# over parallel connections where the target supports it, so pip takes the
# ~180 MB torch off disk. download.pytorch.org is not listed as an index unless
# the target asks for it - its per-project pages list every build ever
# published, several MB re-fetched on each resolve.
python3 -m pip install --no-cache-dir -q $PIP_NET \
    --find-links "$OUT" $idx --constraint "$CONSTRAINTS" $BUILD_DEPS

cd "$SRC"
export VLLM_TARGET_DEVICE=empty

# An sdist has PKG-INFO and no .git, so setuptools-scm cannot discover a
# version; a git checkout has the reverse. Pretend only when PKG-INFO answers,
# otherwise leave setuptools-scm to the checkout it was given.
VLLM_VERSION="${VLLM_VERSION:-$(sed -n 's/^Version: //p' PKG-INFO 2>/dev/null | head -1)}"
if [ -n "$VLLM_VERSION" ]; then
    export SETUPTOOLS_SCM_PRETEND_VERSION="$VLLM_VERSION"
    export SETUPTOOLS_SCM_PRETEND_VERSION_FOR_VLLM="$VLLM_VERSION"
fi
git config --global --add safe.directory "$SRC" || true

echo "[vllm] torch $(python3 -c 'import torch; print(torch.__version__)')"
echo "[vllm] building ${VLLM_VERSION:-$(git describe --tags 2>/dev/null || echo unknown)} for $PLAT_NAME on $(uname -m)"
python3 setup.py bdist_wheel --plat-name "$PLAT_NAME" -d "$OUT"
ls -la "$OUT"/vllm-*.whl
