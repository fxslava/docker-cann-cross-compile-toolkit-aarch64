#!/usr/bin/env bash
# Interactive dev shell in the built 950PR image.
#
#   ./targets/target-950pr/run_dev.sh              bash in the image
#   ./targets/target-950pr/run_dev.sh verify       the image check suite
#   ./targets/target-950pr/run_dev.sh <cmd> [...]  anything else, exec'd as-is
#
# Environment:
#   TAG          image tag       (default vllm-ascend-950pr:x86_64-offline)
#   CONTEXT      repository root (default two levels above this script)
#   DEPS_DIR     offline payload (default $CONTEXT/deps/950pr-x86_64)
#   DEV_NETWORK  docker network  (default none)
#
# The shell is x86_64 native. A build host reaches 13/13 in the verify suite;
# the device-bound checks need /dev/davinci* and report [INFO] without it. On a
# 950PR with the driver mounted the suite is 14/14, and pyACL tightens there
# from "resolves on sys.path" to "imports".
# Behaviour, mounts and the NPU passthrough rules are in common/scripts/run_dev.sh.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT="${CONTEXT:-$(cd "$SELF_DIR/../.." && pwd)}"

export TAG="${TAG:-vllm-ascend-950pr:x86_64-offline}"
export PLATFORM="linux/amd64"
export TARGET_NAME="target-950pr"
export CONTEXT
export DEPS_DIR="${DEPS_DIR:-$CONTEXT/deps/950pr-x86_64}"

exec bash "$CONTEXT/common/scripts/run_dev.sh" "$@"
