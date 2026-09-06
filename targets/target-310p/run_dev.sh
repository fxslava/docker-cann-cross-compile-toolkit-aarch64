#!/usr/bin/env bash
# Interactive dev shell in the built 310P image.
#
#   ./targets/target-310p/run_dev.sh              bash in the image
#   ./targets/target-310p/run_dev.sh verify       the image check suite
#   ./targets/target-310p/run_dev.sh <cmd> [...]  anything else, exec'd as-is
#
# Environment:
#   TAG          image tag       (default vllm-ascend-310p:aarch64-offline)
#   CONTEXT      repository root (default two levels above this script)
#   DEPS_DIR     offline payload (default $CONTEXT/deps)
#   DEV_NETWORK  docker network  (default none)
#
# PRECONDITION on an x86_64 host: the image is linux/arm64 and every command in
# this shell runs under qemu-user. Register the binfmt handler first -
# provision.sh does it, or:
#   docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
#
# Behaviour, mounts and the NPU passthrough rules are in common/scripts/run_dev.sh.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT="${CONTEXT:-$(cd "$SELF_DIR/../.." && pwd)}"

export TAG="${TAG:-vllm-ascend-310p:aarch64-offline}"
export PLATFORM="linux/arm64"
export TARGET_NAME="target-310p"
export CONTEXT
export DEPS_DIR="${DEPS_DIR:-$CONTEXT/deps}"

exec bash "$CONTEXT/common/scripts/run_dev.sh" "$@"
