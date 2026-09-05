#!/bin/bash
# ---------------------------------------------------------------------------
# Runs INSIDE an arm64v8/ubuntu:22.04 container (under QEMU) with network.
# Fills /wheels with a cp310 / manylinux-aarch64 wheelhouse big enough for
#
#     pip install --no-index --find-links=/opt/wheels torch torch_npu vllm ...
#
# to succeed with no network at all.
#
# Resolution runs natively as aarch64 on purpose: several vLLM requirements are
# gated on `platform_machine == "aarch64"` (llguidance, xgrammar), and pip does
# not evaluate those markers against a cross --platform target reliably.
#
#   docker run --platform linux/arm64 -v <prov>:/prov:ro -v <src>:/src:ro \
#       -v <wheels>:/wheels arm64v8/ubuntu:22.04 bash /prov/fetch_wheels.sh
# ---------------------------------------------------------------------------
set -eu
export DEBIAN_FRONTEND=noninteractive

cp -aL /usr/sbin/ldconfig /usr/sbin/ldconfig.orig
printf '#!/bin/sh\nexit 0\n' > /usr/sbin/ldconfig
chmod 0755 /usr/sbin/ldconfig
apt-get update -qq
apt-get install -y --no-install-recommends python3 python3-pip ca-certificates >/dev/null
mv -f /usr/sbin/ldconfig.orig /usr/sbin/ldconfig

python3 -m pip install --no-cache-dir -q --upgrade pip

W=/wheels
VLLM_WHL=$(ls "$W"/vllm-*.whl | head -1)

# --extra-index-url is download.pytorch.org/whl/cpu: the +cpu local-version
# builds named in constraints.aarch64.txt live there, not on PyPI. Without the
# constraint an unpinned `torch>=2.10.0` resolves to PyPI's CUDA aarch64 build
# and drags ~5 GB of nvidia-*-cu13 wheels into the wheelhouse.
pipdl() {
    python3 -m pip download --dest "$W" --find-links "$W" \
        --extra-index-url https://download.pytorch.org/whl/cpu \
        --constraint /prov/constraints.aarch64.txt \
        --only-binary=:all: --no-cache-dir "$@"
}

echo "[wheels] python $(python3 -V 2>&1) on $(python3 -c 'import platform; print(platform.machine())')"
echo "[wheels] pip    $(python3 -m pip --version)"
echo "[wheels] vllm   $(basename "$VLLM_WHL")"

# vLLM and vllm-ascend are resolved SEPARATELY, and installed separately later,
# because vllm-ascend pins the same packages more tightly than vLLM does
# (numpy<2.0.0, fastapi<0.124.0, opencv-python-headless<=4.11.0.86) and must be
# the one that wins -- the order upstream's own Dockerfile.310p uses. At some
# version pairings the two are outright incompatible rather than merely
# tighter, and then a single joint resolve fails instead of picking a side.
# Resolving in two passes keeps both sets of wheels in the house either way.
echo
echo "[wheels] pass 1/3: vLLM runtime closure"
pipdl "$VLLM_WHL"

echo
echo "[wheels] pass 2/3: torch stack + vllm-ascend build/runtime closure"
# Strip the best-effort entries, which are retried one by one in pass 3.
grep -vEi '^[[:space:]]*(triton[-_]ascend|memfabric[-_]hybrid|memcache[-_]hybrid|arctic-inference)([[:space:]]|=|<|>|$)' \
    /src/vllm-ascend/requirements.txt > /tmp/va-req.txt
pipdl -r /prov/requirements.aarch64.txt -r /tmp/va-req.txt

echo
echo "[wheels] pass 3/3: optional extras (a miss here is not fatal)"
: > "$W/.optional-missing"
while read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    if pipdl "$line" >/tmp/opt.log 2>&1; then
        echo "  ok      $line"
    else
        echo "  MISSING $line"
        echo "$line" >> "$W/.optional-missing"
        tail -3 /tmp/opt.log | sed 's/^/          /'
    fi
done < /prov/requirements-optional.aarch64.txt

echo
echo "[wheels] total: $(find "$W" -maxdepth 1 -name '*.whl' | wc -l) wheels, $(du -sh "$W" | cut -f1)"
notwheel=$(find "$W" -maxdepth 1 -type f ! -name '*.whl' ! -name '.optional-missing' | wc -l)
if [ "$notwheel" -ne 0 ]; then
    echo "[wheels] NOTE: $notwheel non-wheel files (sdists) present:"
    find "$W" -maxdepth 1 -type f ! -name '*.whl' ! -name '.optional-missing' -printf '          %f\n'
fi
