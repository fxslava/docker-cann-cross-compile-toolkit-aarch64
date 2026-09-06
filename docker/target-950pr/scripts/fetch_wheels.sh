#!/bin/bash
# ---------------------------------------------------------------------------
# Runs INSIDE an ubuntu:22.04 container (natively on amd64) with network.
# Fills /wheels with a cp310 / manylinux-x86_64 wheelhouse big enough for
#
#     pip install --no-index --find-links=/opt/wheels torch torch_npu vllm ...
#
# to succeed with no network at all.
#
# cp310 because jammy's system interpreter is python3.10 and that is what the
# image runs. Resolution happens in the same container image the build uses, so
# environment markers (python_version, platform_machine, glibc) are evaluated
# against the real target rather than guessed at.
#
#   docker run --platform linux/amd64 -v <prov>:/prov:ro -v <src>:/src:ro \
#       -v <wheels>:/wheels ubuntu:22.04 bash /prov/fetch_wheels.sh
# ---------------------------------------------------------------------------
set -eu
export DEBIAN_FRONTEND=noninteractive

# Prefer IPv4 - see the long note in build_vllm_wheel.sh. Short version: this
# host advertises AAAA records it cannot route, and pip waits out its full
# timeout on them where curl fails over immediately. Without this the resolve
# crawls for reasons that look like a slow link and are not.
printf 'precedence ::ffff:0:0/96  100\n' >> /etc/gai.conf

# Same as build_vllm_wheel.sh: install from the staged .deb archive when it is
# mounted, so this step needs no apt network at all.
if [ -f /debs/Packages.gz ]; then
    echo "[wheels] apt: using the staged local archive at /debs"
    mv /etc/apt/sources.list /etc/apt/sources.list.online 2>/dev/null || true
    mv /etc/apt/sources.list.d /etc/apt/sources.list.d.online 2>/dev/null || true
    mkdir -p /etc/apt/sources.list.d
    echo 'deb [trusted=yes] file:/debs ./' > /etc/apt/sources.list.d/offline.list
    apt-get update -qq
    apt-get install -y --no-install-recommends python3 python3-pip ca-certificates >/dev/null
    rm -f /etc/apt/sources.list.d/offline.list
    mv /etc/apt/sources.list.online /etc/apt/sources.list 2>/dev/null || true
    rm -rf /etc/apt/sources.list.d
    mv /etc/apt/sources.list.d.online /etc/apt/sources.list.d 2>/dev/null || true
else
    apt-get update -qq
    apt-get install -y --no-install-recommends python3 python3-pip ca-certificates >/dev/null
fi
# Many short attempts rather than a few long ones - see build_vllm_wheel.sh for
# the reasoning. This is the longest-running network step in provisioning, so
# abandoning a dead peer in 20 s instead of 60 s compounds over hundreds of
# files.
PIP_NET="--retries 20 --timeout 20"

# PIP_INDEX_URL comes from the provisioning script (it probes pypi.org and falls
# back to upstream's default mirror when the index is unreachable). pip reads the
# environment variable directly.
echo "[wheels] pip index: ${PIP_INDEX_URL:-https://pypi.org/simple (default)}"

python3 -m pip install --no-cache-dir -q $PIP_NET --upgrade pip

W=/wheels
VLLM_WHL=$(ls "$W"/vllm-*.whl 2>/dev/null | head -1 || true)
[ -n "$VLLM_WHL" ] || { echo "[wheels] ERROR: no vllm-*.whl in $W - build it first" >&2; exit 1; }

# THE EXTRA INDEX, AND WHY IT IS THERE
#   mirrors.huaweicloud.com/...    triton-ascend 3.2.2, which is mirror-only
#                                  (PyPI stops at 3.2.0). NOTE the index is
#                                  served at the ROOT of that path - appending
#                                  /simple/ there returns 404.
#
# download.pytorch.org is deliberately NOT listed. The +cpu wheels it serves are
# pre-seeded into $W by the provisioning step, and its per-project pages list
# every build ever published - megabytes of HTML re-fetched on every resolve,
# which timed out repeatedly on this link for a wheel already on disk.
# --find-links "$W" covers them.
#
# --constraint is the load-bearing flag. Without it an unconstrained resolve
# takes PyPI's x86_64 torch 2.10.0, whose metadata declares fifteen
# nvidia-*-cu12 requirements gated on platform_machine == "x86_64", and drags
# several GB of CUDA runtime into a wheelhouse destined for an Ascend NPU.
pipdl() {
    python3 -m pip download --dest "$W" --find-links "$W" $PIP_NET \
        --extra-index-url https://mirrors.huaweicloud.com/ascend/repos/pypi \
        --constraint /prov/constraints.x86_64.txt \
        --only-binary=:all: --no-cache-dir "$@"
}

echo "[wheels] python $(python3 -V 2>&1) on $(python3 -c 'import platform; print(platform.machine())')"
echo "[wheels] pip    $(python3 -m pip --version)"
echo "[wheels] vllm   $(basename "$VLLM_WHL")"

# vLLM and vllm-ascend are resolved SEPARATELY, and installed separately later,
# because vllm-ascend pins the same packages more tightly than vLLM does and
# must be the side that wins -- the order upstream's own Dockerfiles use. At
# some version pairings the two are outright incompatible rather than merely
# tighter, and then a single joint resolve fails instead of picking a side.
echo
echo "[wheels] pass 1/3: vLLM runtime closure"
pipdl "$VLLM_WHL"

echo
echo "[wheels] pass 2/3: torch stack + vllm-ascend build/runtime closure"
# triton-ascend is resolved on its own in pass 3: it lives only on the Ascend
# mirror, and a mirror outage should cost that one wheel, not the whole pass.
grep -vEi '^[[:space:]]*(triton[-_]ascend|memfabric[-_]hybrid|memcache[-_]hybrid|arctic-inference)([[:space:]]|=|<|>|$)' \
    /src/vllm-ascend/requirements.txt > /tmp/va-req.txt
grep -vEi '^[[:space:]]*triton[-_]ascend([[:space:]]|=|<|>|$)' \
    /prov/python_wheels.txt > /tmp/own-req.txt
pipdl -r /tmp/own-req.txt -r /tmp/va-req.txt

echo
echo "[wheels] pass 3/3: Ascend-mirror-only wheels (a miss here is reported, not fatal)"
: > "$W/.optional-missing"
grep -Ei '^[[:space:]]*triton[-_]ascend' /prov/python_wheels.txt | while read -r line; do
    if pipdl "$line" >/tmp/opt.log 2>&1; then
        echo "  ok      $line"
    else
        echo "  MISSING $line"
        echo "$line" >> "$W/.optional-missing"
        tail -3 /tmp/opt.log | sed 's/^/          /'
    fi
done

# ---------------------------------------------------------------------------
# HARD GATE: no CUDA wheels may reach an Ascend payload.
# ---------------------------------------------------------------------------
# The constraint above is what prevents them; this is what proves it. Anything
# named nvidia_* (or a stray cuda/cudnn/cublas wheel pulled in transitively)
# means the resolve escaped the +cpu pin, so fail here rather than shipping a
# multi-GB CUDA runtime the NPU cannot use.
echo
echo "[wheels] CUDA gate"
# PLAIN `triton` IS NOT CHECKED FOR HERE, deliberately. An earlier version of
# this gate rejected triton-2*/triton-3* as CUDA artefacts and would have failed
# a perfectly good resolve: `triton` is a hard dependency of the vLLM wheel, so
# it must be present in the wheelhouse for the offline `pip install vllm` to
# resolve at all. Upstream's own Dockerfile.a5 installs it and then runs
# `pip uninstall -y triton` because it does not work on Ascend, and
# Dockerfile.x86_64 does the same - so the right place to assert its absence is
# the finished image, not the wheelhouse. What is banned here is the CUDA
# *runtime*: nvidia_*, cudnn, cublas.
bad=$(find "$W" -maxdepth 1 -type f \( -iname 'nvidia_*' -o -iname 'nvidia-*' \
        -o -iname '*cudnn*' -o -iname '*cublas*' \) | sort)
if [ -n "$bad" ]; then
    echo "[wheels] FAIL: CUDA / NVIDIA artefacts in the wheelhouse:" >&2
    echo "$bad" | sed 's/^/          /' >&2
    exit 1
fi
echo "  no nvidia_* / cudnn / cublas wheels present"
torchwhl=$(ls "$W"/torch-*.whl 2>/dev/null | head -1 || true)
case "$(basename "${torchwhl:-none}")" in
    torch-*+cpu-*) echo "  torch is the +cpu build: $(basename "$torchwhl")" ;;
    none)          echo "[wheels] FAIL: no torch wheel staged" >&2; exit 1 ;;
    *)             echo "[wheels] FAIL: torch is not a +cpu build: $(basename "$torchwhl")" >&2; exit 1 ;;
esac

echo
echo "[wheels] total: $(find "$W" -maxdepth 1 -name '*.whl' | wc -l) wheels, $(du -sh "$W" | cut -f1)"
notwheel=$(find "$W" -maxdepth 1 -type f ! -name '*.whl' ! -name '.optional-missing' | wc -l)
if [ "$notwheel" -ne 0 ]; then
    echo "[wheels] NOTE: $notwheel non-wheel files (sdists) present:"
    find "$W" -maxdepth 1 -type f ! -name '*.whl' ! -name '.optional-missing' -printf '          %f\n'
fi
