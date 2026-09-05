#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Populate ./deps/ so that docker/target-310p/Dockerfile.aarch64 can be built
# with `--network=none`. This is the ONLY step that touches the network.
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
#   VLLM_WHEEL=~/vllm-build/dist/vllm-0.13.0+empty-cp310-cp310-manylinux2014_aarch64.whl \
#   VLLM_SRC=~/vllm-build/vllm  VLLM_ASCEND_SRC=~/vllm-build/vllm-ascend \
#   ./provision_deps_aarch64.sh ~/aarch64-offline/deps
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPS="${1:-${DEPS_DIR:-$REPO_DIR/deps}}"
TARGET_DIR="${TARGET_DIR:-$REPO_DIR/docker/target-310p}"

CANN_VERSION="${CANN_VERSION:-8.5.0}"
ARM_BASE="${ARM_BASE:-arm64v8/ubuntu:22.04}"

# vllm-ascend v0.13.0 is the release upstream builds against CANN 8.5.0, and it
# pairs with vLLM v0.13.0 / torch 2.8.0 / torch_npu 2.8.0.post2. Do not bump one
# of these without the others - see the matrix in README.aarch64.md.
VLLM_REPO="${VLLM_REPO:-https://github.com/vllm-project/vllm.git}"
VLLM_TAG="${VLLM_TAG:-v0.13.0}"
VLLM_ASCEND_REPO="${VLLM_ASCEND_REPO:-https://github.com/vllm-project/vllm-ascend.git}"
VLLM_ASCEND_REF="${VLLM_ASCEND_REF:-v0.13.0}"

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

# Staged once, up front: every in-container step below bind-mounts $PROV as
# /prov and reads these.
cp -f "$TARGET_DIR/packages.aarch64.txt"             "$PROV/packages.txt"
cp -f "$TARGET_DIR/requirements.aarch64.txt"         "$PROV/requirements.aarch64.txt"
cp -f "$TARGET_DIR/requirements-optional.aarch64.txt" "$PROV/requirements-optional.aarch64.txt"
cp -f "$TARGET_DIR/constraints.aarch64.txt"          "$PROV/constraints.aarch64.txt"
for s in fetch_debs fetch_wheels build_vllm_wheel; do
    cp -f "$TARGET_DIR/scripts/$s.sh" "$PROV/$s.sh"
done

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
step "1. CANN AArch64 toolkit"
# ---------------------------------------------------------------------------
# Only the AArch64 toolkit is needed here; the x86_64 toolkit and the LibTorch
# wheel in download_deps.sh belong to the cross-compilation image. torch itself
# arrives through the wheelhouse in step 5, pinned to the +cpu build by
# constraints.aarch64.txt.
CANN_RUN="$DEPS/Ascend-cann-toolkit_${CANN_VERSION}_linux-aarch64.run"

if [ -n "${CANN_RUN_SRC:-}" ] && [ ! -f "$CANN_RUN" ]; then
    echo "  seeding CANN .run from ${CANN_RUN_SRC}"
    cp "$CANN_RUN_SRC" "$CANN_RUN"
fi

DEPS_ONLY='^Ascend-cann-toolkit.*aarch64' "$REPO_DIR/download_deps.sh" "$DEPS"
[ -f "$CANN_RUN" ] || die "missing $CANN_RUN"

# ---------------------------------------------------------------------------
step "1b. CANN runtime libraries the toolkit .run omits"
# ---------------------------------------------------------------------------
# The CANN 8.5.0 toolkit package ships HCCL split into
# libhccl_{alg,fwk,legacy,plf}.so and NO aggregate libhccl.so -- verified by
# extracting all 21 component .run files from the installer, none of which
# contains one. But every torch_npu build records libhccl.so in DT_NEEDED (five
# of its libraries do), and torch 2.8 auto-loads the torch_npu backend
# extension, so a plain `import torch` dies with
#     ImportError: libtorch_npu.so: undefined symbol: HcclReduceScatter
# The ten collective symbols torch_npu resolves by name (HcclAllReduce,
# HcclReduceScatter, HcclCommInitRootInfo, ...) are defined by nothing in the
# toolkit; the split libraries together provide only four of them, and the two
# other matches in the tree are profiler interception stubs.
#
# Huawei's own CANN 8.5.0 image does carry the real libhccl.so, in the same
# tree at the same version, and it is small (657 KB) and needs only libhcomm,
# libc_sec, libunified_dlog and libmmpa -- all of which the toolkit install
# already provides. So it is lifted from there. The pull is ~4 GB and happens
# once; nothing about it reaches the image build, which stays --network=none.
CANN_EXTRA="$DEPS/cann_extra"
CANN_IMAGE="${CANN_IMAGE:-quay.io/ascend/cann:${CANN_VERSION}-310p-ubuntu22.04-py3.11}"
CANN_EXTRA_LIB64="/usr/local/Ascend/cann-${CANN_VERSION}/aarch64-linux/lib64"
mkdir -p "$CANN_EXTRA"

want=$(grep -vE '^[[:space:]]*(#|$)' "$TARGET_DIR/cann_extra.aarch64.txt")
missing=""
for lib in $want; do
    [ -f "$CANN_EXTRA/$lib" ] || missing="$missing $lib"
done

if [ -z "$missing" ]; then
    echo "  already staged: $(echo "$want" | wc -w) libraries, $(du -sh "$CANN_EXTRA" | cut -f1)"
elif docker image inspect "$CANN_IMAGE" >/dev/null 2>&1 \
     || docker pull --platform linux/arm64 "$CANN_IMAGE"; then
    echo "  lifting$(echo "$missing" | wc -w) libraries from $CANN_IMAGE"
    cid="$(docker create --platform linux/arm64 "$CANN_IMAGE" true)"
    for lib in $missing; do
        if docker cp "$cid:$CANN_EXTRA_LIB64/$lib" "$CANN_EXTRA/$lib" 2>/dev/null; then
            printf '    %-34s %s bytes\n' "$lib" "$(stat -c%s "$CANN_EXTRA/$lib")"
        else
            warn "$lib not present in $CANN_IMAGE"
        fi
    done
    docker rm -f "$cid" >/dev/null 2>&1 || true
    echo "  staged: $(du -sh "$CANN_EXTRA" | cut -f1)"
else
    warn "could not pull $CANN_IMAGE; the image build will fail loudly on the missing libraries"
fi

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
step "2b. third-party payload for the vllm-ascend op build"
# ---------------------------------------------------------------------------
# The ACLNN op build pulls a handful of third-party sources off gitcode.com,
# which obviously cannot happen inside a --network=none image build. Every one
# of those cmake modules checks a local location first, and they all agree on
# ${CANN_3RD_LIB_PATH}, which csrc/build.sh defaults to csrc/third_party -- the
# same directory the catlass submodule lives in. So staging the payload there
# is the sanctioned way to keep the op build offline:
#
#   csrc/third_party/pkg/<tarball>   abseil-cpp, protobuf, googletest, json
#   csrc/third_party/json/include/   json.cmake wants this one pre-extracted
#   csrc/third_party/makeself/       makeself.sh + makeself-header.sh
#
# The URL list is scraped from the checkout rather than hard-coded here, so it
# tracks whatever vllm-ascend ref was provisioned.
TP="$DEPS/third_party"
MAKESELF_SHA="bfa730a5763cdb267904a130e02b2e48e464986909c0733ff1c96495f620369a"
mkdir -p "$TP/pkg"

TP_CMAKE="$SRC/vllm-ascend/csrc/cmake/third_party"
for url in $(grep -hoE 'https://gitcode\.com/[^"[:space:])]+' "$TP_CMAKE"/*.cmake 2>/dev/null | sort -u); do
    fname="$(basename "$url")"
    case "$fname" in
        makeself-*)
            # Consumed extracted, not as a tarball, and it is the one artefact
            # whose hash the cmake declares - so verify it.
            if [ -f "$TP/makeself/makeself.sh" ] && [ -f "$TP/makeself/makeself-header.sh" ]; then
                echo "  makeself: already present"
                continue
            fi
            tmp="$(mktemp -d)"
            if wget -q -O "$tmp/$fname" "$url"; then
                have="$(sha256sum "$tmp/$fname" | cut -d' ' -f1)"
                if [ "$have" = "$MAKESELF_SHA" ]; then
                    mkdir -p "$TP/makeself"
                    tar xzf "$tmp/$fname" -C "$TP/makeself" --strip-components=1
                    echo "  makeself: fetched and verified"
                else
                    warn "makeself sha256 mismatch ($have); the build will fall back to CANN's copy"
                fi
            else
                warn "makeself download failed; the build will fall back to CANN's copy"
            fi
            rm -rf "$tmp"
            ;;
        *)
            if [ -f "$TP/pkg/$fname" ]; then
                echo "  pkg/$fname: already present"
            elif wget -q -O "$TP/pkg/$fname.part" "$url"; then
                mv -f "$TP/pkg/$fname.part" "$TP/pkg/$fname"
                echo "  pkg/$fname: $(stat -c%s "$TP/pkg/$fname") bytes"
            else
                rm -f "$TP/pkg/$fname.part"
                warn "could not fetch $url"
            fi
            ;;
    esac
done

# json.cmake is the odd one out: it looks for ${CANN_3RD_LIB_PATH}/json/include
# and only falls back to downloading include.zip, so pre-extract it.
if [ -f "$TP/pkg/include.zip" ] && [ ! -d "$TP/json/include" ]; then
    mkdir -p "$TP/json"
    python3 -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
        "$TP/pkg/include.zip" "$TP/json"
    echo "  json: extracted to third_party/json/include"
fi

# ---------------------------------------------------------------------------
step "3. arm64 apt archive (deps/apt_debs)"
# ---------------------------------------------------------------------------
if [ -f "$DEBS/Packages.gz" ]; then
    echo "  already populated: $(find "$DEBS" -name '*.deb' | wc -l) debs"
else
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
    drun -v "$PROV:/prov:ro" -v "$SRC:/src" -v "$WHEELS:/out" "$ARM_BASE" \
        bash /prov/build_vllm_wheel.sh
fi
VLLM_WHEEL_IN_HOUSE="$(ls "$WHEELS"/vllm-*.whl | head -1)"
echo "  vLLM wheel: $(basename "$VLLM_WHEEL_IN_HOUSE")"

# ---------------------------------------------------------------------------
step "5. AArch64 wheelhouse (deps/python_wheels)"
# ---------------------------------------------------------------------------
drun -v "$PROV:/prov:ro" -v "$SRC:/src:ro" -v "$WHEELS:/wheels" "$ARM_BASE" \
    bash /prov/fetch_wheels.sh

# ---------------------------------------------------------------------------
step "6. manifest"
# ---------------------------------------------------------------------------
{
    echo "# deps/ inventory generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "cann_run          $(basename "$CANN_RUN") ($(stat -c%s "$CANN_RUN") bytes)"
    echo "torch_wheel       $(basename "$(ls "$WHEELS"/torch-*.whl 2>/dev/null | head -1)" 2>/dev/null || echo missing)"
    echo "torch_npu_wheel   $(basename "$(ls "$WHEELS"/torch_npu-*.whl 2>/dev/null | head -1)" 2>/dev/null || echo missing)"
    echo "vllm_wheel        $(basename "$VLLM_WHEEL_IN_HOUSE")"
    echo "wheels            $(find "$WHEELS" -name '*.whl' | wc -l) wheels, $(du -sh "$WHEELS" | cut -f1)"
    echo "apt_debs          $(find "$DEBS" -name '*.deb' | wc -l) debs, $(du -sh "$DEBS" | cut -f1)"
    echo "makeself          $([ -f "$TP/makeself/makeself.sh" ] && echo staged || echo "not needed by this ref")"
    echo "libhccl.so        $([ -f "$CANN_EXTRA/libhccl.so" ] && echo "staged ($(stat -c%s "$CANN_EXTRA/libhccl.so") bytes)" || echo MISSING)"
    echo "vllm_src          $(git -C "$SRC/vllm" rev-parse --short HEAD 2>/dev/null || echo "not needed (wheel seeded)")"
    echo "vllm_ascend_src   $(git -C "$SRC/vllm-ascend" rev-parse --short HEAD 2>/dev/null || echo n/a)"
    if [ -s "$WHEELS/.optional-missing" ]; then
        echo "optional_missing  $(tr '\n' ' ' < "$WHEELS/.optional-missing")"
    fi
} | tee "$DEPS/MANIFEST.txt"

echo
echo "deps/ total: $(du -sh "$DEPS" | cut -f1)"
echo "ready: ./build_aarch64.sh"
