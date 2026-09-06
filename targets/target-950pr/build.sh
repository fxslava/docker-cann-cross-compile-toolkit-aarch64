#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build the native x86_64 Ascend 950PR inference image.
#
#   ./targets/target-950pr/build.sh                        build and load into the daemon
#   ./targets/target-950pr/build.sh --save out.tar.gz      build, then export via pigz
#   ./targets/target-950pr/build.sh --no-cache             anything unrecognised goes to buildx
#
# Environment:
#   TAG         image tag        (default vllm-ascend-950pr:x86_64-offline)
#   CONTEXT     build context    (default the repository root, two levels up)
#   DEPS_DIR    offline payload  (default $CONTEXT/deps/950pr-x86_64)
#   TARGET_DIR  image assets     (default $CONTEXT/targets/target-950pr)
#   SOC_VERSION build SoC        (default ascend950dt_9582)
#   BASE_IMAGE  base             (default ubuntu:22.04)
#
# UNLIKE targets/target-310p/build.sh THERE IS NO QEMU HERE. Host and target are both
# x86_64, so there is no binfmt registration, no emulation tax and no
# host-architecture unpacker stage - the CANN installer runs natively.
#
# The base is Ubuntu 22.04: jammy is what upstream's Dockerfile.a5 builds on
# (via quay.io/ascend/cann:9.1.0-950-ubuntu22.04-py3.12) and the only Ubuntu
# line Huawei ships 950 CANN images for. Its interpreter is python3.10, so the
# staged wheelhouse must be cp310.
#
# The RUN steps execute with --network=none, so a successful build is itself
# the proof that the payload is complete. Only the base image and the BuildKit
# frontend are fetched from a registry, and only when not already cached.
# ---------------------------------------------------------------------------
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT="${CONTEXT:-$(cd "$SELF_DIR/../.." && pwd)}"
COMMON_DIR="${COMMON_DIR:-$CONTEXT/common}"
DEPS_DIR="${DEPS_DIR:-$CONTEXT/deps/950pr-x86_64}"
TARGET_DIR="${TARGET_DIR:-$CONTEXT/targets/target-950pr}"
TAG="${TAG:-vllm-ascend-950pr:x86_64-offline}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:22.04}"
SOC_VERSION="${SOC_VERSION:-ascend950dt_9582}"
CANN_VERSION="${CANN_VERSION:-9.1.0}"

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

host_arch=$(uname -m)
if [ "$host_arch" = "x86_64" ]; then
    echo "  host     : $host_arch (native build, no emulation)"
else
    echo "  host     : $host_arch - this target is linux/amd64, so every step"
    echo "             below would run under emulation. Expect a large slowdown."
fi

# `docker buildx ls` abbreviates the platform column ("linux/amd64 (+4)"),
# so grepping it reports a platform as absent when the builder does offer it.
# `inspect --bootstrap` prints the full list.
docker buildx inspect --bootstrap 2>/dev/null | grep -qE "^Platforms:.*\blinux/amd64\b" \
    || die "buildx does not offer linux/amd64"
echo "  buildx   : linux/amd64 available"

if docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    echo "  base     : $BASE_IMAGE cached"
else
    echo "  base     : $BASE_IMAGE not cached locally; BuildKit will fetch it"
fi

# THE CASE TRAP, CHECKED EARLY. vllm-ascend gates every 950 code path on the
# CMake regex `SOC_VERSION MATCHES "ascend950"`, which is case-sensitive, and
# setup.py demands a value starting with ascend950. The vendor spelling
# "Ascend950PR" matches nothing and produces a wrong-but-quiet build, so refuse
# it here rather than three hundred seconds into a wheel compile.
case "$SOC_VERSION" in
    ascend950*) echo "  soc      : $SOC_VERSION" ;;
    *) die "SOC_VERSION='$SOC_VERSION' does not start with lowercase 'ascend950'.
       vllm-ascend's CMake gates are case-sensitive; 'Ascend950PR' silently
       matches nothing. On real silicon derive the value from
       'npu-smi info -t board -i 0' as (Chip Name + \"_\" + NPU Name) lowercased,
       e.g. ascend950dt_9582 (what upstream's Dockerfile.a5 ships)." ;;
esac

# No patches for this target, by design: vllm-ascend@main handles ascend950 in
# its own CMake gates and csrc/kernels/unsupported_310p.cpp does not exist
# there. Fail loudly if someone copies the 310P patch set in.
if [ -d "$TARGET_DIR/patches" ] && ls "$TARGET_DIR"/patches/*.patch >/dev/null 2>&1; then
    die "$TARGET_DIR/patches/ contains patches. The 950 target applies none -
       see the stage 6 note in Dockerfile.x86_64. Remove them or move them
       behind an explicit flag before building."
fi
echo "  patches  : none (correct for this target)"

# --- offline payload, checked against the staging manifest ------------------
MANIFEST="$TARGET_DIR/deps.manifest"
[ -f "$MANIFEST" ] || die "missing $MANIFEST"

missing=()
while IFS='|' read -r kind path bytes sha src; do
    case "${kind// /}" in ''|'#'*) continue ;; esac
    path="${path// /}"; bytes="${bytes// /}"
    full="$DEPS_DIR/$path"
    case "$kind" in
        file)
            if [ ! -f "$full" ]; then
                missing+=("$path  <- ${src%% *}")
            elif [ "${bytes:-0}" != "0" ] && [ "$(stat -c%s "$full")" != "$bytes" ]; then
                missing+=("$path  (size $(stat -c%s "$full"), expected $bytes)")
            fi
            ;;
        dir)
            [ -d "$full" ] || missing+=("$path/  <- ${src%% *}")
            ;;
        glob)
            # shellcheck disable=SC2086
            ls $full >/dev/null 2>&1 || missing+=("$path  <- ${src%% *}")
            ;;
    esac
done < "$MANIFEST"

if [ "${#missing[@]}" -gt 0 ]; then
    printf 'ERROR: offline payload incomplete in %s\n' "$DEPS_DIR" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    echo >&2
    echo "  The staging plan and the exact download URLs are in" >&2
    echo "  $MANIFEST and docs/target-950pr-x86_64.md." >&2
    exit 1
fi
echo "  deps     : $(du -sh "$DEPS_DIR" | cut -f1) in $DEPS_DIR (manifest satisfied)"

# --- CUDA gate: no NVIDIA wheels may enter an Ascend image ------------------
# PyPI's x86_64 torch 2.10.0 declares fifteen nvidia-*-cu12 requirements gated
# on `platform_machine == "x86_64"`, so any resolve that escaped
# targets/target-950pr/constraints.x86_64.txt leaves them here. None of it is
# usable on an Ascend NPU, it adds gigabytes to the image, and a CUDA torch
# shadows the CPU build torch_npu is compiled against.
#
# The wheelhouse is checked before the build starts rather than after, because
# --network=none means whatever is staged is exactly what gets installed.
# Only wheels are inspected. Matching every file matched thirty Helion
# autotuning configs in the vLLM source tree (vllm/kernels/helion/configs/
# .../nvidia_h100.json and friends) - JSON named after the GPU it was tuned on,
# not CUDA code, and not even in the build context. A CUDA *wheel* is the thing
# that could actually be installed, so that is what is checked.
cuda_artefacts=$(find "$DEPS_DIR" -type f -name '*.whl' \
    \( -iname 'nvidia_*' -o -iname 'nvidia-*' \
       -o -iname '*cudnn*' -o -iname '*cublas*' \) | sort)
if [ -n "$cuda_artefacts" ]; then
    echo "ERROR: NVIDIA/CUDA artefacts staged in $DEPS_DIR" >&2
    echo "$cuda_artefacts" | sed 's/^/  - /' >&2
    echo >&2
    echo "  An Ascend payload must contain none. Re-stage the wheelhouse with" >&2
    echo "  ./targets/target-950pr/provision.sh wheels, which applies" >&2
    echo "  $TARGET_DIR/constraints.x86_64.txt (torch==2.10.0+cpu)." >&2
    exit 1
fi

torch_whl=$(ls "$DEPS_DIR"/python_wheels/torch-*.whl 2>/dev/null | head -1 || true)
case "$(basename "${torch_whl:-none}")" in
    torch-*+cpu-*) echo "  cuda gate: clean; torch is $(basename "$torch_whl")" ;;
    none)          die "no torch wheel in $DEPS_DIR/python_wheels" ;;
    *)             die "torch wheel is not a +cpu build: $(basename "$torch_whl").
       PyPI's x86_64 torch is a CUDA build; stage the +cpu wheel from
       https://download.pytorch.org/whl/cpu instead." ;;
esac

# The AI Core arch string is the one value here this repo has never verified
# against a real CANN 9.x payload. If the toolkit has been extracted next to
# the payload, check it now; otherwise say so rather than implying it is known.
hc=$(find "$DEPS_DIR" -maxdepth 6 -name host_config.cmake -path '*ascendc_kernel_cmake*' 2>/dev/null | head -1)
if [ -n "$hc" ]; then
    if grep -qE '^set\(ascend950[a-z0-9_]*_list' "$hc"; then
        echo "  soc list : ascend950 present in $(basename "$hc")"
    else
        echo "  soc list : WARNING - no ascend950 list in $hc" >&2
    fi
else
    echo "  soc list : not checked (toolkit not extracted); ASCEND_AICORE_ARCH is"
    echo "             unverified for this CANN release - see docs/target-950pr-x86_64.md"
fi

# --- build -----------------------------------------------------------------
echo
echo "=== building $TAG (linux/amd64, --network=none) ==="
start=$(date +%s)

docker buildx build \
    --platform linux/amd64 \
    --network=none \
    --progress=plain \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --build-arg CANN_VERSION="$CANN_VERSION" \
    --build-arg SOC_VERSION="$SOC_VERSION" \
    -f "$TARGET_DIR/Dockerfile.x86_64" \
    -t "$TAG" \
    --load \
    "${EXTRA[@]}" \
    "$CONTEXT"

elapsed=$(( $(date +%s) - start ))
echo
printf '=== built in %dm %ds ===\n' $((elapsed / 60)) $((elapsed % 60))
docker image ls "$TAG"

# --- export ----------------------------------------------------------------
if [ -n "$SAVE_TO" ]; then
    echo
    echo "=== saving $TAG -> $SAVE_TO ==="
    mkdir -p "$(dirname "$SAVE_TO")"
    case "$SAVE_TO" in
        # A .gz destination streams through pigz instead of landing a multi-GB
        # tar on disk first. docker load reads gzip natively, so the archive
        # needs no separate decompression step on the target host.
        *.gz)
            command -v pigz >/dev/null || die "pigz not on PATH (apt-get install pigz)"
            docker save "$TAG" | pigz -p "$(nproc)" > "$SAVE_TO"
            ;;
        *)
            docker save "$TAG" -o "$SAVE_TO"
            ;;
    esac
    echo "  $(stat -c %s "$SAVE_TO") bytes  ($(du -h "$SAVE_TO" | cut -f1))  $SAVE_TO"
    echo "  sha256: $(sha256sum "$SAVE_TO" | cut -d" " -f1)"
    echo "  copy to the target host, then: docker load -i $(basename "$SAVE_TO")"
fi
