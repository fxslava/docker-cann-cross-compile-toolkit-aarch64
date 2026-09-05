#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build the native AArch64 Ascend 310P3 inference image under QEMU emulation.
#
#   ./build_aarch64.sh                       build and load into the local daemon
#   ./build_aarch64.sh --save image.tar      build, then export for air-gapped copy
#   ./build_aarch64.sh --no-cache            anything unrecognised goes to buildx
#
# Environment:
#   TAG        image tag        (default vllm-ascend-310p:aarch64-offline)
#   CONTEXT    build context    (default the directory holding this script)
#   DEPS_DIR   offline payload  (default $CONTEXT/deps)
#
# The RUN steps are executed with --network=none, so a successful build is
# itself the proof that deps/ is complete. Only two things are fetched from a
# registry, and only if they are not already cached locally: the arm64
# ubuntu:22.04 base image and the BuildKit dockerfile frontend.
# ---------------------------------------------------------------------------
set -euo pipefail

CONTEXT="${CONTEXT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DEPS_DIR="${DEPS_DIR:-$CONTEXT/deps}"
TAG="${TAG:-vllm-ascend-310p:aarch64-offline}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:22.04}"

SAVE_TO=""
EXTRA=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --save) SAVE_TO="$2"; shift 2 ;;
        *)      EXTRA+=("$1"); shift ;;
    esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
echo "=== preflight ==="
command -v docker >/dev/null || die "docker not on PATH"

if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo "  registering QEMU binfmt handlers"
    docker run --rm --privileged multiarch/qemu-user-static --reset -p yes >/dev/null
fi
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || die "qemu-aarch64 binfmt handler missing"
echo "  binfmt   : registered ($(sed -n 2p /proc/sys/fs/binfmt_misc/qemu-aarch64))"

docker buildx ls | grep -q 'linux/arm64' || die "buildx does not offer linux/arm64"
echo "  buildx   : linux/arm64 available"

# The FROM line is --platform=linux/arm64, so the arm64 variant of $BASE_IMAGE
# must be resolvable. --network=none governs RUN steps only, so BuildKit can
# still reach a registry to fetch it; on a genuinely air-gapped builder, cache
# it first. Note that `docker pull --platform linux/arm64 ubuntu:22.04` REPLACES
# the local ubuntu:22.04 tag with the arm64 image, which would break the x86_64
# ./Dockerfile - so pre-pull arm64v8/ubuntu:22.04 and pass it through instead:
#   BASE_IMAGE=arm64v8/ubuntu:22.04 ./build_aarch64.sh
if ! docker image inspect "$BASE_IMAGE" --format '{{.Architecture}}' 2>/dev/null | grep -q arm64; then
    echo "  base     : $BASE_IMAGE (arm64) not cached locally; BuildKit will fetch it"
else
    echo "  base     : $BASE_IMAGE (arm64) cached"
fi

# Not optional: vllm-ascend v0.13.0 does not build for a 310P without these, and
# a missing directory would surface as an opaque mount error hours in.
ls "$CONTEXT"/patches/*.patch >/dev/null 2>&1 \
    || die "no $CONTEXT/patches/*.patch; the 310P build needs them (see README.aarch64.md)"
echo "  patches  : $(ls "$CONTEXT"/patches/*.patch | wc -l) for vllm-ascend"

missing=()
[ -f "$DEPS_DIR"/Ascend-cann-toolkit_*_linux-aarch64.run ] 2>/dev/null || missing+=("CANN aarch64 .run")
[ -f "$DEPS_DIR/apt_debs/Packages.gz" ]        || missing+=("deps/apt_debs/Packages.gz")
ls "$DEPS_DIR"/python_wheels/vllm-*.whl >/dev/null 2>&1 || missing+=("deps/python_wheels/vllm-*.whl")
[ -f "$DEPS_DIR/src/vllm-ascend/setup.py" ]    || missing+=("deps/src/vllm-ascend")
[ -d "$DEPS_DIR/src/vllm-ascend/csrc/third_party/catlass/include" ] \
    || missing+=("deps/src/vllm-ascend catlass submodule")
if [ "${#missing[@]}" -gt 0 ]; then
    printf 'ERROR: offline payload incomplete:\n' >&2
    printf '  - %s\n' "${missing[@]}" >&2
    die "run ./provision_deps_aarch64.sh ${DEPS_DIR} first"
fi
echo "  deps     : $(du -sh "$DEPS_DIR" | cut -f1) in $DEPS_DIR"
[ -f "$DEPS_DIR/MANIFEST.txt" ] && sed 's/^/             /' "$DEPS_DIR/MANIFEST.txt"

# --- build -----------------------------------------------------------------
echo
echo "=== building $TAG (linux/arm64, --network=none) ==="
echo "    expect hours, not minutes: every instruction runs under QEMU"
start=$(date +%s)

docker buildx build \
    --platform linux/arm64 \
    --network=none \
    --progress=plain \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    -f "$CONTEXT/Dockerfile.aarch64" \
    -t "$TAG" \
    --load \
    "${EXTRA[@]}" \
    "$CONTEXT"

echo
echo "=== built in $(( ($(date +%s) - start) / 60 )) min ==="
docker image ls "$TAG"

# --- export ----------------------------------------------------------------
if [ -n "$SAVE_TO" ]; then
    echo
    echo "=== saving $TAG -> $SAVE_TO ==="
    docker save "$TAG" -o "$SAVE_TO"
    echo "  $(du -h "$SAVE_TO" | cut -f1)  $SAVE_TO"
    echo "  copy to the target host, then: docker load -i $(basename "$SAVE_TO")"
fi
