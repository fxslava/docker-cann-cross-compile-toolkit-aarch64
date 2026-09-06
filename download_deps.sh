#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Fetch and verify every large binary dependency of the CANN 8.5.0 / Ascend
# 310P3 cross-compilation image. Idempotent: an already-verified file is
# skipped, a partial file is resumed, a corrupt file is re-fetched once.
#
#   ./download_deps.sh [dest-dir]        (default: ~/cann-build)
#
# Set DEPS_ONLY to an extended regex to fetch a subset. The AArch64 offline
# inference image (targets/target-310p/Dockerfile.aarch64) needs neither the
# x86_64 toolkit nor the cross sysroot, so targets/target-310p/provision.sh calls it as:
#
#   DEPS_ONLY='aarch64|^torch-' ./download_deps.sh ./deps
#
# ---------------------------------------------------------------------------
# VERSION STRING GOTCHA -- READ BEFORE CHANGING CANN_VERSION
#
# The Huawei OBS bucket answers a request for a key that does not exist with
# HTTP 403 Forbidden, NOT 404. A 403 therefore means "wrong version string",
# not "you are blocked" or "geo-restricted". Measured on this bucket:
#
#     CANN 8.5.RC1  x86_64/aarch64 -> 403   <- does not exist
#     CANN 8.5.0    x86_64/aarch64 -> 206   <- real, this is what we use
#     CANN 8.4.RC1  x86_64/aarch64 -> 403   <- does not exist
#     CANN 8.3.RC1  x86_64/aarch64 -> 206
#     CANN 8.2.RC1  x86_64/aarch64 -> 206
#     CANN 8.1.RC1  x86_64/aarch64 -> 206
#
# So the 8.5 line is published as "8.5.0", not "8.5.RC1". If a future version
# 403s, probe the URL shape with a range request before assuming access issues:
#
#   curl -s -o /dev/null -w '%{http_code}\n' -r 0-1023 \
#     "https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/CANN/CANN%20<VER>/Ascend-cann-toolkit_<VER>_linux-x86_64.run"
# ---------------------------------------------------------------------------
set -euo pipefail

DEST="${1:-$HOME/cann-build}"
CANN_VERSION="${CANN_VERSION:-8.5.0}"
TORCH_VERSION="${TORCH_VERSION:-2.10.0}"
# Extended regex matched against the file name; empty means "everything".
DEPS_ONLY="${DEPS_ONLY:-}"

CANN_BASE="https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/CANN/CANN%20${CANN_VERSION}"
TORCH_BASE="https://download.pytorch.org/whl/cpu"

mkdir -p "$DEST"
cd "$DEST"
# Re-anchor to an absolute path: everything below runs from inside $DEST, so a
# relative dest ("./deps") would no longer resolve by the closing `ls`.
DEST="$PWD"

# name | url | sha256 | size-in-bytes
# Hashes and sizes below were computed from the actual downloads on
# 2026-09-03; upstream published the CANN packages on 2026-01-16.
DEPS=(
"Ascend-cann-toolkit_${CANN_VERSION}_linux-x86_64.run|${CANN_BASE}/Ascend-cann-toolkit_${CANN_VERSION}_linux-x86_64.run|2cd6412133f1388761051f94f7f59ce428ba2836335ac37dbfd1b96dc6eca5b9|1118059948"
"Ascend-cann-toolkit_${CANN_VERSION}_linux-aarch64.run|${CANN_BASE}/Ascend-cann-toolkit_${CANN_VERSION}_linux-aarch64.run|bd702440a2b3bf1e0a07d321ed5cb55c181e954a82d0b8edd4b13039b37ef929|1104308866"
# LibTorch for AArch64. PyTorch publishes no libtorch-*.zip for arm64 Linux;
# the manylinux_2_28_aarch64 wheel IS the distribution channel. It carries
# torch/lib/{libtorch,libtorch_cpu,libc10,libarm_compute}.so and 9788 header
# entries under torch/include. Note the '+' in the version must be percent
# encoded as %2B in the URL, which is why a literal '+' 403s.
"torch-${TORCH_VERSION}+cpu-cp310-cp310-manylinux_2_28_aarch64.whl|${TORCH_BASE}/torch-${TORCH_VERSION}%2Bcpu-cp310-cp310-manylinux_2_28_aarch64.whl|d63ee6a80982fd73fe44bb70d97d2976e010312ff6db81d7bfb9167b06dd45b9|146520080"
)

verify() {  # <file> <sha> <size>
    local f="$1" want_sha="$2" want_size="$3" have_size have_sha
    [ -f "$f" ] || return 1
    have_size=$(stat -c%s "$f")
    [ "$have_size" = "$want_size" ] || { echo "  size ${have_size} != ${want_size}"; return 1; }
    have_sha=$(sha256sum "$f" | cut -d' ' -f1)
    [ "$have_sha" = "$want_sha" ] || { echo "  sha256 mismatch"; return 1; }
    return 0
}

probe() {   # <url> -> prints HTTP status of a 1 KiB range request
    curl -s -o /dev/null -w '%{http_code}' -L --max-time 30 -r 0-1023 "$1"
}

rc=0
for entry in "${DEPS[@]}"; do
    name="${entry%%|*}"; rest="${entry#*|}"
    url="${rest%%|*}";   rest="${rest#*|}"
    sha="${rest%%|*}";   size="${rest##*|}"

    if [ -n "$DEPS_ONLY" ] && ! printf '%s' "$name" | grep -Eq "$DEPS_ONLY"; then
        continue
    fi

    echo "=== ${name}"
    if verify "$name" "$sha" "$size" 2>/dev/null; then
        echo "  already present and verified"
        continue
    fi

    code=$(probe "$url")
    if [ "$code" != "206" ] && [ "$code" != "200" ]; then
        echo "  ERROR: upstream returned HTTP ${code} for ${url}" >&2
        echo "  403 from the Huawei OBS bucket means the version string does not exist." >&2
        rc=1
        continue
    fi

    echo "  downloading ($(( size / 1048576 )) MiB) ..."
    wget -c -q --show-progress --progress=dot:giga -O "$name" "$url"

    if verify "$name" "$sha" "$size"; then
        echo "  verified sha256 ${sha}"
    else
        echo "  ERROR: ${name} failed verification after download" >&2
        rc=1
    fi
done

echo
echo "=== contents of ${DEST} ==="
ls -la "$DEST"
exit $rc
