#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Populate ./deps/ so that Dockerfile.aarch64 can be built with
# `--network=none`. This is the ONLY step that touches the network.
#
#   ./provision_deps_aarch64.sh [deps-dir]      (default: <repo>/deps)
#
# Produces:
#
#   deps/
#     Ascend-cann-toolkit_8.5.0_linux-aarch64.run   CANN toolkit, AArch64
#     apt_debs/                                     arm64 .deb + Packages index
#     python_wheels/                                cp310 aarch64 wheelhouse
#     src/vllm/                                     vLLM source (wheel build)
#     src/vllm-ascend/                              vllm-ascend + catlass submodule
#     MANIFEST.txt                                  inventory of the above
#
# Everything that must run as AArch64 (pip resolution honours
# `platform_machine == "aarch64"` markers, apt honours `Architecture: arm64`)
# is executed inside a throwaway arm64v8/ubuntu:22.04 container under QEMU
# user-mode emulation, so the artefacts match the target image exactly.
#
# Seeding: if you already have any of these locally, point the matching
# variable at it and the download/build is skipped:
#
#   CANN_RUN_SRC=~/cann-build/Ascend-cann-toolkit_8.5.0_linux-aarch64.run \
#   TORCH_WHEEL_SRC=~/cann-build/torch-2.10.0+cpu-cp310-cp310-manylinux_2_28_aarch64.whl \
#   VLLM_WHEEL=~/vllm-build/dist/vllm-0.27.1+empty-cp310-cp310-manylinux2014_aarch64.whl \
#   VLLM_SRC=~/vllm-build/vllm  VLLM_ASCEND_SRC=~/vllm-build/vllm-ascend \
#   ./provision_deps_aarch64.sh ~/aarch64-offline/deps
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPS="${1:-${DEPS_DIR:-$REPO_DIR/deps}}"

CANN_VERSION="${CANN_VERSION:-8.5.0}"
TORCH_VERSION="${TORCH_VERSION:-2.10.0}"
ARM_BASE="${ARM_BASE:-arm64v8/ubuntu:22.04}"

VLLM_REPO="${VLLM_REPO:-https://github.com/vllm-project/vllm.git}"
VLLM_TAG="${VLLM_TAG:-v0.27.1}"
VLLM_ASCEND_REPO="${VLLM_ASCEND_REPO:-https://github.com/vllm-project/vllm-ascend.git}"
VLLM_ASCEND_REF="${VLLM_ASCEND_REF:-main}"

WHEELS="$DEPS/python_wheels"
DEBS="$DEPS/apt_debs"
SRC="$DEPS/src"
PROV="$DEPS/.provision"

step() { echo; echo "##### $* #####"; }
warn() { echo "  WARN: $*" >&2; }
die()  { echo "  ERROR: $*" >&2; exit 1; }

# Every docker run below is x86_64 host tooling driving an aarch64 guest.
drun() { docker run --rm --platform linux/arm64 "$@"; }

mkdir -p "$DEPS" "$WHEELS" "$DEBS" "$SRC" "$PROV"

# ---------------------------------------------------------------------------
step "0. host prerequisites"
# ---------------------------------------------------------------------------
command -v docker >/dev/null || die "docker not on PATH"
command -v git    >/dev/null || die "git not on PATH"

if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo "  registering QEMU binfmt handlers (needs --privileged)"
    docker run --rm --privileged multiarch/qemu-user-static --reset -p yes >/dev/null
fi
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] \
    || die "qemu-aarch64 binfmt handler still absent; is binfmt_misc mounted?"

# The F (fix binary) flag is what lets the handler work inside a container that
# does not itself ship qemu-aarch64-static.
grep -q "^flags:.*F" /proc/sys/fs/binfmt_misc/qemu-aarch64 \
    || warn "qemu-aarch64 registered without the F flag; container runs may fail"

echo "  binfmt: $(sed -n 2p /proc/sys/fs/binfmt_misc/qemu-aarch64)"
docker image inspect "$ARM_BASE" >/dev/null 2>&1 || docker pull --platform linux/arm64 "$ARM_BASE"
echo "  emulated arch: $(drun "$ARM_BASE" uname -m)"

# ---------------------------------------------------------------------------
step "1. CANN AArch64 toolkit + torch AArch64 wheel"
# ---------------------------------------------------------------------------
CANN_RUN="$DEPS/Ascend-cann-toolkit_${CANN_VERSION}_linux-aarch64.run"
TORCH_WHL_NAME="torch-${TORCH_VERSION}+cpu-cp310-cp310-manylinux_2_28_aarch64.whl"

if [ -n "${CANN_RUN_SRC:-}" ] && [ ! -f "$CANN_RUN" ]; then
    echo "  seeding CANN .run from ${CANN_RUN_SRC}"
    cp "$CANN_RUN_SRC" "$CANN_RUN"
fi
if [ -n "${TORCH_WHEEL_SRC:-}" ] && [ ! -f "$DEPS/$TORCH_WHL_NAME" ]; then
    echo "  seeding torch wheel from ${TORCH_WHEEL_SRC}"
    cp "$TORCH_WHEEL_SRC" "$DEPS/$TORCH_WHL_NAME"
fi

DEPS_ONLY=aarch64 "$REPO_DIR/download_deps.sh" "$DEPS"
[ -f "$CANN_RUN" ] || die "missing $CANN_RUN"

# The wheelhouse must see the torch wheel. pip prefers 2.10.0+cpu over the plain
# 2.10.0 on PyPI because PEP 440 sorts a local version higher.
[ -f "$WHEELS/$TORCH_WHL_NAME" ] || cp "$DEPS/$TORCH_WHL_NAME" "$WHEELS/$TORCH_WHL_NAME"

# ---------------------------------------------------------------------------
step "2. source checkouts"
# ---------------------------------------------------------------------------
seed_or_clone() {   # <dest> <seed-path-or-empty> <repo> <ref> <recurse yes|no>
    local dest="$1" seed="$2" repo="$3" ref="$4" recurse="$5"
    if [ -e "$dest/setup.py" ]; then
        echo "  $(basename "$dest"): already present"
        return 0
    fi
    if [ -n "$seed" ]; then
        echo "  $(basename "$dest"): seeding from $seed"
        cp -a "$seed" "$dest"
        return 0
    fi
    echo "  $(basename "$dest"): cloning $repo @ $ref"
    if [ "$recurse" = yes ]; then
        git clone --depth 1 --branch "$ref" --recurse-submodules --shallow-submodules \
            "$repo" "$dest"
    else
        git clone --depth 1 --branch "$ref" "$repo" "$dest"
    fi
}

# vllm-ascend is always needed: the offline image builds it from source.
# The vLLM source is only needed when its wheel still has to be built, so it is
# fetched lazily in step 4.
seed_or_clone "$SRC/vllm-ascend" "${VLLM_ASCEND_SRC:-}" "$VLLM_ASCEND_REPO" "$VLLM_ASCEND_REF" yes

# csrc/build_aclnn.sh runs `git submodule update --init` when this directory is
# missing, which would need the network during the offline image build.
[ -d "$SRC/vllm-ascend/csrc/third_party/catlass/include" ] \
    || die "catlass submodule missing under $SRC/vllm-ascend; clone with --recurse-submodules"
echo "  catlass submodule: present ($(du -sh "$SRC/vllm-ascend/csrc/third_party/catlass" | cut -f1))"

# ---------------------------------------------------------------------------
step "3. arm64 apt archive (deps/apt_debs)"
# ---------------------------------------------------------------------------
if [ -f "$DEBS/Packages.gz" ]; then
    echo "  already populated: $(find "$DEBS" -name '*.deb' | wc -l) debs"
else
    cp -f "$REPO_DIR/packages.aarch64.txt" "$PROV/packages.txt"
    cat "$REPO_DIR/scripts/fetch_debs.sh" > "$PROV/fetch_debs.sh"
    drun -v "$PROV:/prov:ro" -v "$DEBS:/out" "$ARM_BASE" bash /prov/fetch_debs.sh
fi

# ---------------------------------------------------------------------------
step "4. vLLM AArch64 wheel (VLLM_TARGET_DEVICE=empty)"
# ---------------------------------------------------------------------------
# vLLM publishes an aarch64 wheel on PyPI, but it is a CUDA build. The Ascend
# backend lives entirely in vllm-ascend, so vLLM itself must be built with
# VLLM_TARGET_DEVICE=empty exactly as upstream's Dockerfile.310p does.
if ls "$WHEELS"/vllm-*.whl >/dev/null 2>&1; then
    echo "  already present: $(basename "$(ls "$WHEELS"/vllm-*.whl | head -1)")"
elif [ -n "${VLLM_WHEEL:-}" ]; then
    echo "  seeding vLLM wheel from ${VLLM_WHEEL}"
    cp "$VLLM_WHEEL" "$WHEELS/"
else
    seed_or_clone "$SRC/vllm" "${VLLM_SRC:-}" "$VLLM_REPO" "$VLLM_TAG" no
    echo "  building under emulation; this takes a while"
    cat "$REPO_DIR/scripts/build_vllm_wheel.sh" > "$PROV/build_vllm_wheel.sh"
    drun -v "$PROV:/prov:ro" -v "$SRC:/src" -v "$WHEELS:/out" "$ARM_BASE" \
        bash /prov/build_vllm_wheel.sh
fi
VLLM_WHEEL_IN_HOUSE="$(ls "$WHEELS"/vllm-*.whl | head -1)"
echo "  vLLM wheel: $(basename "$VLLM_WHEEL_IN_HOUSE")"

# ---------------------------------------------------------------------------
step "5. AArch64 wheelhouse (deps/python_wheels)"
# ---------------------------------------------------------------------------
cp -f "$REPO_DIR/requirements.aarch64.txt" "$PROV/requirements.aarch64.txt"
cp -f "$REPO_DIR/requirements-optional.aarch64.txt" "$PROV/requirements-optional.aarch64.txt"
cp -f "$REPO_DIR/constraints.aarch64.txt" "$PROV/constraints.aarch64.txt"
cat "$REPO_DIR/scripts/fetch_wheels.sh" > "$PROV/fetch_wheels.sh"
drun -v "$PROV:/prov:ro" -v "$SRC:/src:ro" -v "$WHEELS:/wheels" "$ARM_BASE" \
    bash /prov/fetch_wheels.sh

# ---------------------------------------------------------------------------
step "6. manifest"
# ---------------------------------------------------------------------------
{
    echo "# deps/ inventory generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "cann_run          $(basename "$CANN_RUN") ($(stat -c%s "$CANN_RUN") bytes)"
    echo "torch_wheel       $TORCH_WHL_NAME"
    echo "vllm_wheel        $(basename "$VLLM_WHEEL_IN_HOUSE")"
    echo "wheels            $(find "$WHEELS" -name '*.whl' | wc -l) wheels, $(du -sh "$WHEELS" | cut -f1)"
    echo "apt_debs          $(find "$DEBS" -name '*.deb' | wc -l) debs, $(du -sh "$DEBS" | cut -f1)"
    echo "vllm_src          $(git -C "$SRC/vllm" rev-parse --short HEAD 2>/dev/null || echo "not needed (wheel seeded)")"
    echo "vllm_ascend_src   $(git -C "$SRC/vllm-ascend" rev-parse --short HEAD 2>/dev/null || echo n/a)"
    if [ -s "$WHEELS/.optional-missing" ]; then
        echo "optional_missing  $(tr '\n' ' ' < "$WHEELS/.optional-missing")"
    fi
} | tee "$DEPS/MANIFEST.txt"

echo
echo "deps/ total: $(du -sh "$DEPS" | cut -f1)"
echo "ready: ./build_aarch64.sh"
