#!/bin/bash
# Resolves a target's offline wheelhouse in three passes and gates CUDA out of
# it. Runs inside a container matching the target's base image and interpreter,
# so environment markers (python_version, platform_machine, glibc) evaluate
# against the real target rather than a guess.
#
#   WHEELS             wheelhouse directory              [/wheels]
#   CONSTRAINTS        pip constraint file               [/prov/constraints.txt]
#   OWN_REQ            this repository's requirements    [/prov/requirements.txt]
#   PLUGIN_REQ         upstream plugin requirements      [/src/vllm-ascend/requirements.txt]
#   EXTRA_INDEXES      space-separated index URLs        []
#   MIRROR_ONLY        extra best-effort requirement files  []
#   ENFORCE_CPU_TORCH  1 to require a +cpu torch wheel   [1]
#   EMULATED           1 under qemu-user                 [0]
#
# Precondition: a vllm-*.whl already built into WHEELS. vLLM is built, never
# downloaded - the published wheel is a CUDA build on both architectures.
#
# THE CONSTRAINT FILE IS LOAD-BEARING. Both architectures publish CUDA torch on
# PyPI: x86_64 torch 2.10.0 declares fifteen nvidia-*-cu12 requirements gated on
# platform_machine == "x86_64", and the aarch64 wheels target GH200/Jetson. An
# unconstrained resolve stages GB of CUDA runtime no Ascend NPU can use, and its
# torch shadows the CPU build torch_npu is compiled against.
set -eu
export DEBIAN_FRONTEND=noninteractive
. /common/container_prelude.sh

WHEELS="${WHEELS:-/wheels}"
CONSTRAINTS="${CONSTRAINTS:-/prov/constraints.txt}"
OWN_REQ="${OWN_REQ:-/prov/requirements.txt}"
PLUGIN_REQ="${PLUGIN_REQ:-/src/vllm-ascend/requirements.txt}"
EXTRA_INDEXES="${EXTRA_INDEXES:-}"
MIRROR_ONLY="${MIRROR_ONLY:-}"
ENFORCE_CPU_TORCH="${ENFORCE_CPU_TORCH:-1}"
EMULATED="${EMULATED:-0}"

prelude_network
[ "$EMULATED" = "1" ] && prelude_ldconfig_stub on
prelude_apt_install python3 python3-pip ca-certificates
[ "$EMULATED" = "1" ] && prelude_ldconfig_stub off
python3 -m pip install --no-cache-dir -q $PIP_NET --upgrade pip

VLLM_WHL=$(ls "$WHEELS"/vllm-*.whl 2>/dev/null | head -1 || true)
[ -n "$VLLM_WHL" ] || { echo "[wheels] ERROR: no vllm-*.whl in $WHEELS - build it first" >&2; exit 1; }

idx=""
for u in $EXTRA_INDEXES; do idx="$idx --extra-index-url $u"; done

pipdl() {
    python3 -m pip download --dest "$WHEELS" --find-links "$WHEELS" $PIP_NET \
        $idx --constraint "$CONSTRAINTS" --only-binary=:all: --no-cache-dir "$@"
}

echo "[wheels] python $(python3 -V 2>&1) on $(python3 -c 'import platform; print(platform.machine())')"
echo "[wheels] index  ${PIP_INDEX_URL:-https://pypi.org/simple}"
echo "[wheels] vllm   $(basename "$VLLM_WHL")"

# vLLM and the plugin resolve SEPARATELY and install separately later. The
# plugin pins shared packages more tightly than vLLM does and must be the side
# that wins - the order upstream's own Dockerfiles use. At some pairings the two
# are incompatible rather than merely tighter, and a single joint resolve then
# fails outright instead of picking a side.
echo
echo "[wheels] pass 1/3: vLLM runtime closure"
pipdl "$VLLM_WHL"

echo
echo "[wheels] pass 2/3: torch stack and plugin closure"
# Mirror-only and never-published entries are stripped here and retried alone in
# pass 3, so one mirror outage costs one wheel rather than the whole pass.
STRIP='^[[:space:]]*(triton[-_]ascend|memfabric[-_]hybrid|memcache[-_]hybrid|arctic-inference)([[:space:]]|=|<|>|$)'
grep -vEi "$STRIP" "$PLUGIN_REQ" > /tmp/plugin-req.txt
grep -vEi "$STRIP" "$OWN_REQ"    > /tmp/own-req.txt
pipdl -r /tmp/own-req.txt -r /tmp/plugin-req.txt

echo
echo "[wheels] pass 3/3: mirror-only wheels (a miss is reported, not fatal)"
# Whatever pass 2 stripped out of OWN_REQ, plus any file the target declares.
# Deriving the first half from OWN_REQ keeps a single pin per package.
: > /tmp/mirror-req.txt
grep -Ei "$STRIP" "$OWN_REQ" >> /tmp/mirror-req.txt || true
for f in $MIRROR_ONLY; do [ -f "$f" ] && cat "$f" >> /tmp/mirror-req.txt; done
: > "$WHEELS/.optional-missing"
while read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    if pipdl "$line" >/tmp/opt.log 2>&1; then
        echo "  ok      $line"
    else
        echo "  MISSING $line"
        echo "$line" >> "$WHEELS/.optional-missing"
        tail -3 /tmp/opt.log | sed 's/^/          /'
    fi
done < /tmp/mirror-req.txt

# CUDA gate. The constraint file prevents these; this proves it.
#
# Plain `triton` is NOT rejected: it is a hard dependency of the vLLM wheel and
# must exist here for the offline install to resolve at all. It is uninstalled
# inside the image after the last pip transaction, because triton-ascend ships
# its own top-level `triton` package that NVIDIA's shadows. The image asserts
# that end state; this gate covers the CUDA runtime only.
#
# The gate matches *.whl only. Matching all files rejected a clean payload over
# thirty Helion autotuning configs named nvidia_h100.json in the vLLM tree.
echo
echo "[wheels] CUDA gate"
bad=$(find "$WHEELS" -maxdepth 1 -type f -name '*.whl' \
        \( -iname 'nvidia_*' -o -iname 'nvidia-*' \
        -o -iname '*cudnn*' -o -iname '*cublas*' \) | sort)
if [ -n "$bad" ]; then
    echo "[wheels] FAIL: CUDA/NVIDIA artefacts in the wheelhouse:" >&2
    echo "$bad" | sed 's/^/          /' >&2
    exit 1
fi
echo "  no nvidia_* / cudnn / cublas wheels present"

if [ "$ENFORCE_CPU_TORCH" = "1" ]; then
    torchwhl=$(ls "$WHEELS"/torch-*.whl 2>/dev/null | head -1 || true)
    case "$(basename "${torchwhl:-none}")" in
        torch-*+cpu-*) echo "  torch is the +cpu build: $(basename "$torchwhl")" ;;
        none)          echo "[wheels] FAIL: no torch wheel staged" >&2; exit 1 ;;
        *)             echo "[wheels] FAIL: torch is not a +cpu build: $(basename "$torchwhl")" >&2; exit 1 ;;
    esac
fi

echo
echo "[wheels] total: $(find "$WHEELS" -maxdepth 1 -name '*.whl' | wc -l) wheels, $(du -sh "$WHEELS" | cut -f1)"
notwheel=$(find "$WHEELS" -maxdepth 1 -type f ! -name '*.whl' ! -name '.optional-missing' | wc -l)
if [ "$notwheel" -ne 0 ]; then
    echo "[wheels] NOTE: $notwheel non-wheel files (sdists) present:"
    find "$WHEELS" -maxdepth 1 -type f ! -name '*.whl' ! -name '.optional-missing' -printf '          %f\n'
fi
