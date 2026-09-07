#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build the native x86_64 Ascend 950PR inference image.
#
#   ./targets/target-950pr/build.sh                        build and load into the daemon
#   ./targets/target-950pr/build.sh --save out.tar.gz      build, then export via pigz
#   ./targets/target-950pr/build.sh --no-cache             anything unrecognised goes to buildx
#
# The release deliverable, built and exported in one go:
#   ./targets/target-950pr/build.sh --no-cache \
#       --save artifacts/vllm-ascend-950pr-x86_64-offline.tar.gz
#
# Environment:
#   TAG          image tag       (default vllm-ascend-950pr:x86_64-offline)
#   CONTEXT      build context   (default the repository root, two levels up)
#   DEPS_DIR     offline payload (default $CONTEXT/deps/950pr-x86_64)
#   TARGET_DIR   image assets    (default $CONTEXT/targets/target-950pr)
#   SOC_VERSION  build SoC       (default ascend950dt_9582)
#   BASE_IMAGE   base            (default ubuntu:22.04)
#   CANN_VERSION CANN release    (default 9.2.0; must match the staged payload
#                                 AND the driver on the target host)
#   CANN_APT_VERSION exact Debian version of the CANN packages
#                                 (default 9.2.0-beta.2). CANN_VERSION is the
#                                 release LINE and drives on-disk paths;
#                                 CANN_APT_VERSION is the package version and
#                                 drives the staged filenames and the sha256
#                                 pins. A beta makes the two differ.
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
CANN_VERSION="${CANN_VERSION:-9.2.0}"
CANN_APT_VERSION="${CANN_APT_VERSION:-9.2.0-beta.2}"

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
#
# THE PR/DT SPLIT IS SEPARATE FROM THE CASE TRAP AND EASIER TO MISS. CANN 9.1.0
# treats 950PR and 950DT as distinct SoC families - ascend950_list carries both
# name spaces and platform_config has its own .ini for each part - and the
# ACLNN kernel binaries this image compiles are keyed on the exact SOC_VERSION.
# This target is named 950PR while upstream's default (inherited here) is a DT
# part, so a DT value gets a warning: it may well be what you want on a DT
# board, but on PR silicon it should be derived rather than inherited.
case "$SOC_VERSION" in
    ascend950dt_*)
        echo "  soc      : $SOC_VERSION"
        echo "             NOTE: that is a 950-DT part, and this target is named 950PR."
        echo "             CANN 9.1.0 lists nine PR parts - ascend950pr_{9579,957b,957c,"
        echo "             957d,9589,958a,958b,9599,950z} - with their own platform configs."
        echo "             On a 950PR derive the value from the board instead:"
        echo "                 npu-smi info -t board -i 0"
        echo "             then (Chip Name + '_' + NPU Name), lowercased."
        ;;
    ascend950*) echo "  soc      : $SOC_VERSION" ;;
    *) die "SOC_VERSION='$SOC_VERSION' does not start with lowercase 'ascend950'.
       vllm-ascend's CMake gates are case-sensitive; 'Ascend950PR' silently
       matches nothing. On real silicon derive the value from
       'npu-smi info -t board -i 0' as (Chip Name + \"_\" + NPU Name) lowercased,
       e.g. ascend950dt_9582 (what upstream's Dockerfile.a5 ships)." ;;
esac

# NO vllm-ascend PATCHES for this target, by design: at the pinned ref
# (releases/v0.27.1rc) it handles ascend950 in its own CMake gates and
# csrc/kernels/unsupported_310p.cpp does not exist there. Fail loudly if someone
# copies the 310P patch set in.
#
# ONE PATCH IS EXPECTED, AND IT IS NOT A vllm-ascend PATCH. It targets catlass -
# vllm-ascend's third-party submodule - and it is applied by provision.sh when
# the tree is STAGED, not here at build time, because that is where the catlass
# checkout lives. It backports upstream catlass c89fe73d so the ascend950 flash
# attention epilogues compile against CANN 9.2.0's Bisheng, which now requires
# __attribute__((cce_simd_vf)) functions to be static. Without it three ops die
# in the kernel compile. See the CATLASS_PATCH note in provision.sh.
#
# So the allowlist is by name: the catlass backport is known and expected, and
# anything else in patches/ is still refused.
CATLASS_PATCH_NAME="0001-catlass-simd-vf-static.patch"
unexpected=""
if [ -d "$TARGET_DIR/patches" ]; then
    unexpected=$(find "$TARGET_DIR/patches" -maxdepth 1 -name '*.patch' \
                 ! -name "$CATLASS_PATCH_NAME" -printf '%f\n' 2>/dev/null | sort)
fi
if [ -n "$unexpected" ]; then
    echo "ERROR: unexpected patches in $TARGET_DIR/patches/:" >&2
    echo "$unexpected" | sed 's/^/  - /' >&2
    die "the 950 target applies no vllm-ascend patches - see the stage 6 note in
       Dockerfile.x86_64. Remove them, or move them behind an explicit flag."
fi
if [ -f "$TARGET_DIR/patches/$CATLASS_PATCH_NAME" ]; then
    # It is applied at staging time, so assert the RESULT here rather than the
    # patch's presence: a payload staged before the patch existed would build
    # unpatched sources and fail forty minutes later in the kernel compile.
    if grep -rqE '^[[:space:]]+__simd_vf__ (inline|void)' \
         "$DEPS_DIR/src/vllm-ascend/csrc/third_party/catlass/include" 2>/dev/null; then
        die "the staged catlass still has non-static __simd_vf__ members, which
       CANN $CANN_APT_VERSION's Bisheng rejects. The catlass backport was not
       applied to this payload. Re-stage it:
           $TARGET_DIR/provision.sh src"
    fi
    echo "  patches  : catlass simd_vf backport (applied at staging; verified)"
else
    echo "  patches  : none"
fi

# --- offline payload, checked against the staging manifest ------------------
MANIFEST="$TARGET_DIR/deps.manifest"
[ -f "$MANIFEST" ] || die "missing $MANIFEST"

# @CANN_VERSION@ IS EXPANDED BEFORE PARSING. The manifest used to name 9.1.0 in
# four literal places, so moving the CANN line meant editing it as well as the
# Dockerfile - and forgetting produced a build that checked for one release's
# artefacts and then installed another's. One substitution keeps the two in step
# by construction.
manifest_expanded=$(sed -e "s/@CANN_APT_VERSION@/${CANN_APT_VERSION}/g" \
                        -e "s/@CANN_VERSION@/${CANN_VERSION}/g" "$MANIFEST")

missing=()
pinned=0
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
        pin)
            # pin|<cann-apt-version>|<file>|<bytes>|<sha256>. The columns shift
            # by one relative to the rows above, so they are read under their own
            # names: `path` is the version, `bytes` the filename, `sha` the size
            # and `src` the hash.
            #
            # KEYED ON CANN_APT_VERSION, NOT CANN_VERSION: a hash identifies one
            # artefact, and 9.2.0-beta.1 and 9.2.0-beta.2 are different artefacts
            # of the same 9.2.0 line. Keying on the line would apply beta.1's
            # hashes to beta.2's files and fail the build for the wrong reason.
            [ "${path}" = "$CANN_APT_VERSION" ] || continue
            full="$DEPS_DIR/${bytes// /}"
            if [ ! -f "$full" ]; then
                missing+=("${bytes// /}  (pinned for CANN $path, not staged)")
                continue
            fi
            if [ "$(stat -c%s "$full")" != "${sha// /}" ]; then
                missing+=("${bytes// /}  (size $(stat -c%s "$full"), pinned $sha)")
                continue
            fi
            # sha256sum over the 4.4 GB of CANN packages costs a few seconds
            # and is the only thing standing between a truncated or substituted
            # package and a ninety-minute build that fails at the very end.
            actual=$(sha256sum "$full" | cut -d' ' -f1)
            if [ "$actual" != "${src// /}" ]; then
                missing+=("${bytes// /}  (sha256 $actual, pinned ${src// /})")
                continue
            fi
            pinned=$((pinned + 1))
            ;;
    esac
done <<< "$manifest_expanded"

if [ "${#missing[@]}" -gt 0 ]; then
    printf 'ERROR: offline payload incomplete in %s\n' "$DEPS_DIR" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    echo >&2
    echo "  The staging plan and the exact download URLs are in" >&2
    echo "  $MANIFEST and docs/target-950pr-x86_64.md." >&2
    echo "  Stage it with:  CANN_VERSION=$CANN_VERSION \\" >&2
    echo "                  CANN_APT_VERSION=$CANN_APT_VERSION $TARGET_DIR/provision.sh" >&2
    exit 1
fi
echo "  deps     : $(du -sh "$DEPS_DIR" | cut -f1) in $DEPS_DIR (manifest satisfied)"

# --- one CANN release in the payload, and it is the one being built ---------
# The toolkit, NNAL and the cann_extra libraries all land in a single lib64 and
# are resolved by one loader. A payload carrying two releases produces an image
# whose libraries disagree about their own ABI, and that surfaces as `undefined
# symbol` at import time - not as anything the build log calls an error.
stray_debs=$(find "$DEPS_DIR/cann_debs" -maxdepth 1 -name '*.deb' \
             ! -name "*_${CANN_APT_VERSION}_*" -printf '%f\n' 2>/dev/null | sort)
if [ -n "$stray_debs" ]; then
    echo "ERROR: packages from another CANN release are staged next to ${CANN_APT_VERSION}:" >&2
    echo "$stray_debs" | sed 's/^/  - /' >&2
    die "remove them, or build with CANN_APT_VERSION set to the release you mean"
fi
if [ "$pinned" -gt 0 ]; then
    echo "  cann     : $CANN_VERSION (apt $CANN_APT_VERSION, $pinned artefact(s) sha256-verified)"
else
    echo "  cann     : $CANN_VERSION (apt $CANN_APT_VERSION - NO sha256 pin in"
    echo "             deps.manifest for this version; size-checked only. Add a"
    echo "             'pin|$CANN_APT_VERSION|...' row once the artefacts are"
    echo "             known-good - provision.sh prints the hashes.)"
fi

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
    --build-arg CANN_APT_VERSION="$CANN_APT_VERSION" \
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
