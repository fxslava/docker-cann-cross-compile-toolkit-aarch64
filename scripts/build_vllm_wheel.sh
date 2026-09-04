#!/bin/bash
# ---------------------------------------------------------------------------
# Runs INSIDE an arm64v8/ubuntu:22.04 container (under QEMU) with network.
# Builds the upstream vLLM source checkout at /src/vllm into an aarch64 wheel
# and drops it in /out (deps/python_wheels).
#
# VLLM_TARGET_DEVICE=empty makes vllm's _build_custom_ops() a no-op, so no
# CUDA/HIP extension is compiled. The whole Ascend backend lives in
# vllm-ascend, exactly as upstream's Dockerfile.310p arranges it. The aarch64
# wheel published on PyPI is a CUDA build and is deliberately NOT used.
#
#   docker run --platform linux/arm64 -v <prov>:/prov:ro -v <src>:/src \
#       -v <wheels>:/out arm64v8/ubuntu:22.04 bash /prov/build_vllm_wheel.sh
# ---------------------------------------------------------------------------
set -eu
export DEBIAN_FRONTEND=noninteractive

cp -aL /usr/sbin/ldconfig /usr/sbin/ldconfig.orig
printf '#!/bin/sh\nexit 0\n' > /usr/sbin/ldconfig
chmod 0755 /usr/sbin/ldconfig
apt-get update -qq
apt-get install -y --no-install-recommends \
    build-essential git python3 python3-dev python3-pip ca-certificates >/dev/null
mv -f /usr/sbin/ldconfig.orig /usr/sbin/ldconfig

python3 -m pip install --no-cache-dir -q --upgrade pip setuptools setuptools-scm wheel

# vLLM's setup.py does `import torch` at module scope even for the empty target
# (it reads the version to stamp the wheel), so torch has to be present before
# bdist_wheel runs. It is pinned to the same +cpu build the image installs, via
# the shared constraints file, so the wheel is stamped against the stack it will
# actually run on.
python3 -m pip install --no-cache-dir -q \
    --extra-index-url https://download.pytorch.org/whl/cpu \
    --constraint /prov/constraints.aarch64.txt \
    torch cmake ninja packaging jinja2 regex

cd /src/vllm
export VLLM_TARGET_DEVICE=empty
git config --global --add safe.directory /src/vllm || true
echo "[vllm] torch $(python3 -c 'import torch; print(torch.__version__)')"

echo "[vllm] building $(git describe --tags 2>/dev/null || echo unknown) on $(uname -m)"
python3 setup.py bdist_wheel --plat-name "${PLAT_NAME:-manylinux2014_aarch64}" -d /out

ls -la /out
