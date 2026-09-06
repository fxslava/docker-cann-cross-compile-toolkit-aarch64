#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Populate deps/ so builders/builder-x86_64/Dockerfile can build with the
# Ascend 310P operator package and the CAModel simulator wired in. The only
# step in this repository that touches the network, together with the
# download_deps.sh it calls.
#
#   ./builders/builder-x86_64/provision.sh [deps-dir]   (default: <repo>/deps)
#
# Produces:
#
#   deps/
#     Ascend-cann-toolkit_8.5.0_linux-x86_64.run     host toolkit + CAModel
#     Ascend-cann-toolkit_8.5.0_linux-aarch64.run    cross sysroot
#     torch-2.10.0+cpu-...-aarch64.whl               optional, WITH_LIBTORCH=1
#     builder-x86_64/
#       kernels-310p/lib64/                          the 22 libraries the
#                                                    toolkit package omits
#       kernels-310p/opp/                            the COMPLETE operator
#                                                    package, ~5.4 GB: binary
#                                                    kernels for every op
#                                                    including ops_legacy, plus
#                                                    the host-side tiling libs
#       googletest-1.14.0.tar.gz                     csrc/tests' only fetch
#       MANIFEST.txt
#
# ---------------------------------------------------------------------------
# WHY THE OPERATOR PACKAGE IS LIFTED FROM A CONTAINER IMAGE
#
# The natural source is Ascend-cann-kernels-310p_8.5.0_linux-x86_64.run, and it
# is not downloadable. Probed against the OBS bucket on 2026-09-06, where 403
# means "this key does not exist" rather than "you are blocked":
#
#   Ascend-cann-kernels-310p_8.5.0_linux-aarch64.run   403
#   Ascend-cann-kernels-310p_8.5.0_linux-x86_64.run    403
#   Ascend-cann-kernels-310p_8.5.0_linux.run           403
#   Ascend-cann-nnrt_8.5.0_linux-aarch64.run           403
#   Ascend-cann-nnal_8.5.0_linux-aarch64.run           206
#   Ascend-cann-toolkit_8.5.0_linux-aarch64.run        206
#
# The same holds on the 9.1.0 line for -950, -a5, -910b and -nnrt. Huawei
# publishes the toolkit and NNAL and withholds every kernels package, so the
# published carrier for these bytes is the vendor container image - the route
# targets/target-310p/provision.sh already takes for libhccl.so and the opapi
# family, and targets/target-950pr/provision.sh for its 26 cann_extra libs.
#
# Set KERNELS_RUN to a copy of the real .run if you have one from a support
# channel; the Dockerfile bind-mounts and runs it instead.
# ---------------------------------------------------------------------------
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${CONTEXT:-$(cd "$SELF_DIR/../.." && pwd)}"
DEPS="${1:-${DEPS_DIR:-$REPO_DIR/deps}}"
OUT="$DEPS/builder-x86_64"
KERN="$OUT/kernels-310p"

CANN_VERSION="${CANN_VERSION:-8.5.0}"
CANN_IMAGE="${CANN_IMAGE:-quay.io/ascend/cann:${CANN_VERSION}-310p-ubuntu22.04-py3.11}"
CANN_TK="/usr/local/Ascend/ascend-toolkit/latest"

# googletest v1.14.0 is what csrc/tests/CMakeLists.txt pins in its
# FetchContent_Declare. Bump both together or the staged tree is ignored.
GTEST_VERSION="${GTEST_VERSION:-1.14.0}"
GTEST_SHA256="8ad598c73ad796e0d8280b082cebd82a630d73e73cd3c70057938a6501bba5d7"
GTEST_URL="https://github.com/google/googletest/archive/refs/tags/v${GTEST_VERSION}.tar.gz"

# THE WHOLE opp TREE IS STAGED, ops_legacy INCLUDED. An earlier revision
# dropped ops_legacy - 3.8 GB of the 3.9 GB ascend310p kernel tree - on the
# theory that the aclnn entry points the suite calls live in ops_nn and
# ops_transformer. They do; their *kernels* do not stop there. aclnnMatmul
# lowers to a graph that launches TransData around MatMul, and both of those
# are legacy ops, so the trimmed tree fails at run time with
#
#     aclnnMatmulGetWorkspaceSize failed with status 561103
#     cannot open op kernel bin json file [], reason : No such file or directory
#     failed to get op kenrel bin json [.../ops_legacy/trans_data/TransData_*.json]
#
# and then, once trans_data is added, with the same error for ops_legacy/mat_mul.
# There is no way to read the closure off the operator names, and a partial
# tree surfaces one missing operator per run, so the tree is staged whole.
LEGACY_PATH='built-in/op_impl/ai_core/tbe/kernel/ascend310p/ops_legacy'

step() { echo; echo "##### $* #####"; }
warn() { echo "  WARN: $*" >&2; }
die()  { echo "  ERROR: $*" >&2; exit 1; }

mkdir -p "$OUT" "$KERN/lib64" "$KERN/opp"

# ---------------------------------------------------------------------------
step "0. host prerequisites"
# ---------------------------------------------------------------------------
command -v docker >/dev/null || die "docker not on PATH"
command -v curl   >/dev/null || die "curl not on PATH"
command -v tar    >/dev/null || die "tar not on PATH"

# ---------------------------------------------------------------------------
step "1. CANN toolkits and the optional aarch64 LibTorch wheel"
# ---------------------------------------------------------------------------
"$REPO_DIR/download_deps.sh" "$DEPS"
CANN_X86="$DEPS/Ascend-cann-toolkit_${CANN_VERSION}_linux-x86_64.run"
[ -f "$CANN_X86" ] || die "missing $CANN_X86"

# ---------------------------------------------------------------------------
step "2. Ascend 310P operator package"
# ---------------------------------------------------------------------------
# TWO HALVES, AND THE SECOND IS THE ONE THAT IS EASY TO MISS.
#
#   lib64/     libopapi.so and the four libraries it dispatches into. Without
#              them csrc/tests cannot even dlopen the op-api and every device
#              case skips.
#   opp/       the operator package proper. Not just the binary kernels: aclnn
#              resolves a HOST-SIDE TILING FUNCTION per operator out of
#              opp/built-in/op_impl/ai_core/tbe/op_tiling/lib/linux/x86_64/
#              liboptiling.so, and the standalone toolkit ships no op_tiling
#              directory at all. Staging the kernels alone gets you
#                  aclnnRmsNormGetWorkspaceSize failed with status 561002
#                  AclNN_Inner_Error(EZ9999): Do not find tiling func of RmsNorm!
#              which reads like a missing kernel and is not.
#
# The toolkit's opp/built-in holds op_impl only, 15 MB. The vendor image's
# holds data, framework, op_graph, op_impl and op_proto - 5.4 GB, of which
# ops_legacy is 3.8 GB. All of it is staged; see the note above LEGACY_PATH.
if [ -n "${KERNELS_RUN:-}" ]; then
    [ -f "$KERNELS_RUN" ] || die "KERNELS_RUN=$KERNELS_RUN does not exist"
    echo "  staging the vendor installer: $(basename "$KERNELS_RUN")"
    cp -f "$KERNELS_RUN" "$OUT/$(basename "$KERNELS_RUN")"
    echo "  $(stat -c%s "$OUT/$(basename "$KERNELS_RUN")") bytes; the Dockerfile bind-mounts and runs it"
elif [ -s "$KERN/lib64/libopapi.so" ] \
     && [ -d "$KERN/opp/built-in/op_impl/ai_core/tbe/op_tiling" ] \
     && [ -d "$KERN/opp/$LEGACY_PATH/mat_mul" ]; then
    # ops_legacy/mat_mul is the sentinel: a payload staged by the revision of
    # this script that excluded ops_legacy has everything else and would
    # otherwise be reused, then fail at test time with status 561103.
    echo "  already staged: $(du -sh "$KERN" | cut -f1)"
else
    docker image inspect --format '{{.Architecture}}' "$CANN_IMAGE" 2>/dev/null | grep -qx amd64 \
        || docker pull --platform linux/amd64 "$CANN_IMAGE" \
        || die "could not pull the amd64 $CANN_IMAGE and KERNELS_RUN is unset"

    # The lib64 half is a delta against whatever this toolkit already installs,
    # computed rather than hard-coded so a CANN bump does not silently stage a
    # library that moved into the toolkit, or miss one that moved out.
    echo "  computing the lib64 delta"
    docker run --rm --platform linux/amd64 "$CANN_IMAGE" \
        bash -c "ls $CANN_TK/lib64/ | sort" > "$OUT/.vendor.lib64"
    if docker image inspect cann85-cross-310p:latest >/dev/null 2>&1; then
        docker run --rm cann85-cross-310p:latest \
            bash -c "ls $CANN_TK/lib64/ | sort" > "$OUT/.toolkit.lib64"
    else
        # First build: no toolkit image to diff against yet, so take the
        # libraries the toolkit is known to omit. The Dockerfile re-checks.
        printf '%s\n' libacl_dvpp.so libacl_dvpp_mpi.so libacl_dvpp_op.so \
            libcann_hixl.so libconstant_folding_ops.so libdvpp_cmdlist_v100.so \
            libdvpp_cmdlist_v101.so libdvpp_cmdlist_v102.so libdvpp_cmdlist_v200.so \
            libdvpp_op_base.so libdvpp_rtkernel.so libes_math.so libhccl.so \
            libllm_datadist.so libop_common.so libopapi.so libopapi_cv.so \
            libopapi_math.so libopapi_nn.so libopapi_transformer.so \
            libops_host_cpu.so \
            | sort > "$OUT/.delta.lib64"
        cp "$OUT/.delta.lib64" "$OUT/.toolkit.lib64.none"
    fi
    if [ -s "$OUT/.toolkit.lib64" ]; then
        comm -23 "$OUT/.vendor.lib64" "$OUT/.toolkit.lib64" > "$OUT/.delta.lib64"
    fi
    echo "  vendor $(wc -l < "$OUT/.vendor.lib64"), delta $(wc -l < "$OUT/.delta.lib64") libraries"
    sed 's/^/    /' "$OUT/.delta.lib64"

    # One tar stream, not a docker cp per path: ~9.5k files and 1.8 GB.
    docker run --rm --platform linux/amd64 -v "$OUT/.delta.lib64:/delta:ro" "$CANN_IMAGE" \
        bash -c "cd $CANN_TK/lib64 && tar -cf - -T /delta 2>/dev/null" \
        | tar -xf - -C "$KERN/lib64"

    echo "  staging opp/built-in whole, ops_legacy included (~5.4 GB, minutes)"
    rm -rf "$KERN/opp/built-in"
    docker run --rm --platform linux/amd64 "$CANN_IMAGE" bash -c \
        "cd $CANN_TK && tar -cf - opp/built-in opp/scene.info opp/version.info 2>/dev/null" \
        | tar -xf - -C "$KERN"
    rm -f "$OUT/.vendor.lib64" "$OUT/.toolkit.lib64" "$OUT/.toolkit.lib64.none"
    echo "  staged $(du -sh "$KERN" | cut -f1), $(find "$KERN" -type f | wc -l) files"
fi

# The three assertions the Dockerfile repeats in-image, run here too so a bad
# payload costs seconds rather than a full build.
if [ -s "$KERN/lib64/libopapi.so" ]; then
    [ -d "$KERN/opp/built-in/op_impl/ai_core/tbe/kernel/ascend310p" ] \
        || die "no ascend310p kernels in the staged payload"
    [ -f "$KERN/opp/built-in/op_impl/ai_core/tbe/op_tiling/lib/linux/x86_64/liboptiling.so" ] \
        || die "no op_tiling/liboptiling.so; every aclnn call will fail with 561002"
    [ -d "$KERN/opp/$LEGACY_PATH/mat_mul" ] && [ -d "$KERN/opp/$LEGACY_PATH/trans_data" ] \
        || die "ops_legacy is incomplete; aclnnMatmul will fail with 561103"
    if command -v nm >/dev/null; then
        nm -D "$KERN/lib64/libopapi.so" > "$OUT/.opapi.syms" 2>/dev/null || true
        for sym in aclnnRmsNorm aclnnMatmul aclnnSwiGlu aclnnApplyRotaryPosEmbV2 \
                   aclnnScatterPaKvCache aclnnIncreFlashAttentionV4; do
            grep -q "$sym" "$OUT/.opapi.syms" \
                && printf '  %-32s exported\n' "$sym" \
                || warn "$sym not exported by libopapi.so"
        done
        rm -f "$OUT/.opapi.syms"
    fi
fi

# ---------------------------------------------------------------------------
step "3. googletest source"
# ---------------------------------------------------------------------------
# csrc/tests declares googletest with GIT_REPOSITORY, so a plain
# `cmake -S csrc/tests` clones from github.com at configure time. The tarball
# is unpacked into the image at /opt/googletest and pointed at with
# -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST.
GT="$OUT/googletest-${GTEST_VERSION}.tar.gz"
if [ -s "$GT" ] && [ "$(sha256sum "$GT" | cut -d' ' -f1)" = "$GTEST_SHA256" ]; then
    echo "  already present and verified"
else
    # shellcheck source=../../common/scripts/fetch.sh
    . "$REPO_DIR/common/scripts/fetch.sh"
    fetch_resumable "$GTEST_URL" "$GT" 0
    have="$(sha256sum "$GT" | cut -d' ' -f1)"
    [ "$have" = "$GTEST_SHA256" ] || die "googletest sha256 $have != $GTEST_SHA256"
    echo "  verified sha256 $have"
fi

# ---------------------------------------------------------------------------
step "4. manifest"
# ---------------------------------------------------------------------------
{
    echo "# deps/builder-x86_64 inventory generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "cann_x86_64       ../$(basename "$CANN_X86") ($(stat -c%s "$CANN_X86") bytes)"
    if [ -s "$KERN/lib64/libopapi.so" ]; then
        echo "kernels_source    $CANN_IMAGE (linux/amd64)"
        echo "kernels_lib64     $(ls "$KERN/lib64" | wc -l) libraries, $(du -sh "$KERN/lib64" | cut -f1)"
        echo "kernels_opp       $(du -sh "$KERN/opp" | cut -f1), $(find "$KERN/opp" -type f | wc -l) files"
        echo "kernels_legacy    $(find "$KERN/opp/$LEGACY_PATH" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l) operators, $(du -sh "$KERN/opp/$LEGACY_PATH" 2>/dev/null | cut -f1)"
        echo "op_tiling         $(stat -c%s "$KERN/opp/built-in/op_impl/ai_core/tbe/op_tiling/lib/linux/x86_64/liboptiling.so" 2>/dev/null || echo MISSING) bytes"
    else
        echo "kernels_source    $(ls "$OUT"/Ascend-cann-kernels-*.run 2>/dev/null | head -1 || echo MISSING)"
    fi
    echo "googletest        $(basename "$GT") ($(stat -c%s "$GT") bytes)"
} | tee "$OUT/MANIFEST.txt"

echo
echo "deps/builder-x86_64 total: $(du -sh "$OUT" | cut -f1)"
echo "ready: DOCKER_BUILDKIT=1 docker build -f builders/builder-x86_64/Dockerfile -t cann85-cross-310p:latest ."
