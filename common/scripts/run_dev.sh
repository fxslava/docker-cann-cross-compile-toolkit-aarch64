#!/usr/bin/env bash
# Host-side interactive shell in a built target image. Exec'd by each target
# run_dev.sh, which sets the contract below; not run directly.
#
#   TAG          image to run                        (required)
#   PLATFORM     linux/amd64 | linux/arm64           (required)
#   TARGET_NAME  target directory name               (required)
#   CONTEXT      repository root                     (required)
#   DEPS_DIR     offline payload for this target     (required)
#   DEV_NETWORK  docker --network value              [none]
#
# Mounts, all read-only except /work:
#   /repo             the checkout, for editing scripts against a live image
#   /src/vllm-ascend  plugin source, for out-of-image kernel work
#   /third_party      the archives CMake would otherwise fetch
#   /patches          common/patches, incl. cmake_fetchcontent_local.sh
#   /work             scratch, writable, discarded with the container
#
# --network=none by default, matching the build. The image installs nothing at
# run time; a resolve that only succeeds with egress is a payload defect.
#
# NPU passthrough is best-effort. With no /dev/davinci* the shell still starts
# under ALLOW_NO_NPU=1 and everything except device work behaves as in the
# verify suite - see each target's verify_runtime.sh for what a build host can
# and cannot prove.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

: "${TAG:?TAG must be set by the target run_dev.sh}"
: "${PLATFORM:?PLATFORM must be set by the target run_dev.sh}"
: "${TARGET_NAME:?TARGET_NAME must be set by the target run_dev.sh}"
: "${CONTEXT:?CONTEXT must be set by the target run_dev.sh}"
: "${DEPS_DIR:?DEPS_DIR must be set by the target run_dev.sh}"
DEV_NETWORK="${DEV_NETWORK:-none}"

command -v docker >/dev/null || die "docker not on PATH"
docker image inspect "$TAG" >/dev/null 2>&1 \
    || die "image $TAG not built. Run ./targets/$TARGET_NAME/build.sh first."

# -t only when stdout is a terminal: `run_dev.sh verify` from a script
# or a CI step has no TTY, and docker refuses -t outright there.
args=(--rm -i --platform "$PLATFORM" --network "$DEV_NETWORK")
[ -t 0 ] && [ -t 1 ] && args+=(-t)

# Compute devices, then the three control nodes. The control nodes are as
# mandatory as the compute device: without them the runtime cannot open a
# context and the failure surfaces much later as an opaque ACL error.
ndev=0
for dev in /dev/davinci[0-9]*; do
    [ -c "$dev" ] || continue
    args+=(--device "$dev"); ndev=$((ndev + 1))
done
for ctl in /dev/davinci_manager /dev/devmm_svm /dev/hisi_hdc; do
    [ -e "$ctl" ] && args+=(--device "$ctl")
done
[ "$ndev" -eq 0 ] && args+=(-e ALLOW_NO_NPU=1)

# The host driver, when present, is bind-mounted over the empty directory the
# image ships. LD_LIBRARY_PATH puts it first, so a real driver always wins over
# anything staged in the image.
if [ -d /usr/local/Ascend/driver ]; then
    args+=(-v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro)
fi

args+=(-v "$CONTEXT:/repo:ro")
[ -d "$DEPS_DIR/src/vllm-ascend" ] && args+=(-v "$DEPS_DIR/src/vllm-ascend:/src/vllm-ascend:ro")
[ -d "$DEPS_DIR/third_party" ]     && args+=(-v "$DEPS_DIR/third_party:/third_party:ro")
[ -d "$CONTEXT/common/patches" ]   && args+=(-v "$CONTEXT/common/patches:/patches:ro")
args+=(-v "$TARGET_NAME-dev-work:/work" -w /work)

echo "=== $TARGET_NAME dev shell ==="
echo "  image    : $TAG ($PLATFORM)"
echo "  npus     : $ndev"
echo "  network  : $DEV_NETWORK"
echo "  driver   : $([ -d /usr/local/Ascend/driver ] && echo mounted || echo absent)"
echo
echo "  . /usr/local/lib/ascend/compiler_env.sh   build environment"
echo "  verify-runtime.sh                         the image's own check suite"
echo "  THIRD_PARTY=/third_party sh /patches/cmake_fetchcontent_local.sh <tree>"
echo "                                            stage the offline CMake archives"
echo

# The entrypoint sources the CANN environment and exec's anything that is
# neither `serve` nor `verify`.
if [ "$#" -eq 0 ]; then
    exec docker run "${args[@]}" "$TAG" bash
fi
exec docker run "${args[@]}" "$TAG" "$@"
