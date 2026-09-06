#!/bin/bash
# ---------------------------------------------------------------------------
# Runs INSIDE an ubuntu:22.04 container (natively on amd64) with network.
# Builds the upstream vLLM source checkout at /src/vllm into an x86_64 wheel
# and drops it in /out (deps/950pr-x86_64/python_wheels).
#
# VLLM_TARGET_DEVICE=empty makes vllm's _build_custom_ops() a no-op, so no
# CUDA/HIP extension is compiled. The whole Ascend backend lives in
# vllm-ascend, exactly as upstream's Dockerfile.a5 arranges it.
#
# THE PyPI x86_64 vllm WHEEL IS A CUDA BUILD and is deliberately not used: it
# resolves cleanly and produces an image that imports but dispatches to
# nothing. On aarch64 the 310P pipeline avoids the same trap.
#
#   docker run --platform linux/amd64 -v <prov>:/prov:ro -v <src>:/src \
#       -v <wheels>:/out ubuntu:22.04 bash /prov/build_vllm_wheel.sh
# ---------------------------------------------------------------------------
set -eu
export DEBIAN_FRONTEND=noninteractive

# PREFER IPv4. This host resolves pypi.org to AAAA records first but has no
# working IPv6 egress, and the two clients differ in how they cope: curl does
# happy-eyeballs and falls back in milliseconds, while pip (urllib3) walks
# getaddrinfo in order and sits on the dead IPv6 address until its timeout
# expires - which looked exactly like "the network is slow", with pip stalled
# for minutes having transferred 1.5 kB while the host fetched the same URL in
# under two seconds. One line in gai.conf reorders the preference for every
# glibc client in the container, apt included.
printf 'precedence ::ffff:0:0/96  100\n' >> /etc/gai.conf

# Prefer the .deb archive already staged for the image. deps/950pr-x86_64/apt_debs
# is the closure of packages/sys_packages.txt, which is a superset of what this
# build needs (build-essential, git, python3, python3-dev, python3-pip,
# ca-certificates), so mounting it at /debs makes this step need no network and
# saves re-downloading ~150 MB. Falls back to the network when /debs is absent,
# because the stage can legitimately run before the apt archive exists.
if [ -f /debs/Packages.gz ]; then
    echo "[vllm] apt: using the staged local archive at /debs"
    mv /etc/apt/sources.list.d /etc/apt/sources.list.d.online 2>/dev/null || true
    mkdir -p /etc/apt/sources.list.d
    mv /etc/apt/sources.list /etc/apt/sources.list.online 2>/dev/null || true
    echo 'deb [trusted=yes] file:/debs ./' > /etc/apt/sources.list.d/offline.list
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        build-essential git python3 python3-dev python3-pip ca-certificates >/dev/null
    rm -f /etc/apt/sources.list.d/offline.list
    mv /etc/apt/sources.list.online /etc/apt/sources.list 2>/dev/null || true
    rm -rf /etc/apt/sources.list.d
    mv /etc/apt/sources.list.d.online /etc/apt/sources.list.d 2>/dev/null || true
else
    echo "[vllm] apt: no /debs archive staged, falling back to the network"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        build-essential git python3 python3-dev python3-pip ca-certificates >/dev/null
fi

# MANY SHORT ATTEMPTS, NOT A FEW LONG ONES. pip's default five retries were not
# enough here - a run died on "Temporary failure in name resolution" for
# files.pythonhosted.org after apt had already pulled 135 MB - but simply raising
# the timeout made things worse: a connection that had silently died still held
# the transfer for the full 60 s before pip gave up on it, observed as pip
# sitting on 4.27 MB for six minutes. --timeout is socket *inactivity*, so a slow
# but flowing download is unaffected; 20 s just abandons a dead peer three times
# sooner, and 20 retries keep the budget the same.
PIP_NET="--retries 20 --timeout 20"

# PIP_INDEX_URL is chosen by the provisioning script, which probes pypi.org and
# falls back to the mirror upstream's Dockerfile.a5 defaults to when the index
# (as opposed to the file CDN) is unreachable. pip reads the variable itself, so
# it is only echoed here for the record.
echo "[vllm] pip index: ${PIP_INDEX_URL:-https://pypi.org/simple (default)}"

# setuptools is capped at <81 because that is the range vLLM 0.27.1's
# [build-system] declares (">=77.0.3,<81.0.0"). We build with setup.py directly
# rather than through PEP 517, so nothing enforces that bound for us - an
# unpinned --upgrade quietly installs a newer setuptools than upstream builds
# against.
python3 -m pip install --no-cache-dir -q $PIP_NET --upgrade \
    pip 'setuptools>=77.0.3,<81.0.0' setuptools-scm wheel

# vLLM's setup.py does `import torch` at module scope even for the empty target
# (it reads the version to stamp the wheel), so torch has to be present before
# bdist_wheel runs. The constraint file pins the +cpu build, which keeps the
# fifteen nvidia-*-cu12 requirements of PyPI's x86_64 torch out of this
# container - and stamps the wheel against the stack the image actually runs.
# --find-links /out first: the provisioning step seeds the +cpu torch wheels
# into the wheelhouse over parallel connections beforehand, so pip picks the
# ~180 MB torch up off disk instead of pulling it down one connection here.
# NO --extra-index-url FOR PYTORCH HERE, deliberately. The +cpu wheels are
# already in /out (the provisioning step seeds them over parallel connections),
# and download.pytorch.org/whl/cpu/torch/ is a single HTML page listing every
# torch build ever published - several MB that pip re-fetches on each resolve.
# On this link that page alone timed out repeatedly ("Read timed out" against
# /whl/cpu/torch/) while the wheel it points at was already sitting on disk.
# --find-links /out plus the exact +cpu pins in the constraint file resolve it
# locally instead.
#
# setuptools-rust IS REQUIRED, not optional: vLLM 0.27.1's setup.py does
# `from setuptools_rust.build import build_rust` at module scope, so the build
# dies with ModuleNotFoundError before it reads VLLM_TARGET_DEVICE at all. The
# full module-level third-party import set of that setup.py is torch,
# packaging, setuptools, setuptools_rust and setuptools_scm - everything below
# plus the two installed above.
python3 -m pip install --no-cache-dir -q $PIP_NET \
    --find-links /out \
    --constraint /prov/constraints.x86_64.txt \
    torch cmake ninja packaging jinja2 regex 'setuptools-rust>=1.9.0'

cd /src/vllm
export VLLM_TARGET_DEVICE=empty

# The source is the PyPI sdist, so there is no .git here. setuptools-scm would
# otherwise fail to derive a version; PKG-INFO usually carries it, but the
# pretend-version makes the wheel's version explicit either way and matches the
# ref the payload was staged from.
VLLM_VERSION="${VLLM_VERSION:-$(sed -n 's/^Version: //p' PKG-INFO 2>/dev/null | head -1)}"
export SETUPTOOLS_SCM_PRETEND_VERSION="${VLLM_VERSION:-0.27.1}"
export SETUPTOOLS_SCM_PRETEND_VERSION_FOR_VLLM="$SETUPTOOLS_SCM_PRETEND_VERSION"
git config --global --add safe.directory /src/vllm || true

echo "[vllm] torch $(python3 -c 'import torch; print(torch.__version__)')"
echo "[vllm] building version $SETUPTOOLS_SCM_PRETEND_VERSION on $(uname -m)"

python3 setup.py bdist_wheel --plat-name "${PLAT_NAME:-manylinux_2_28_x86_64}" -d /out

ls -la /out/vllm-*.whl
