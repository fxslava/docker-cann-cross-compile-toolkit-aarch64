#!/bin/bash
# ---------------------------------------------------------------------------
# Entrypoint for the x86_64 Ascend 950PR offline inference image.
#
# Detects the NPUs handed to the container, wires up the CANN + ATB + driver
# environment, then launches `vllm serve`.
#
#   docker run ... <image>                      # serve $MODEL
#   docker run ... <image> serve --port 8080    # serve with extra vllm flags
#   docker run ... <image> verify               # offline self-check, no NPU needed
#   docker run ... <image> bash                 # anything else is exec'd as-is
#
# Environment:
#   MODEL                   model id or local path to serve (required to serve)
#   PORT                    listen port                        (default 8000)
#   HOST                    bind address                       (default 0.0.0.0)
#   TENSOR_PARALLEL_SIZE    defaults to the number of NPUs found
#   VLLM_DTYPE              passed through only if set (see the note below)
#   ASCEND_RT_VISIBLE_DEVICES   defaults to every NPU found
#   ALLOW_NO_NPU=1          start even when no /dev/davinci* is present
#   NO_JEMALLOC=1           skip the jemalloc LD_PRELOAD
# ---------------------------------------------------------------------------
set -uo pipefail

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint] WARNING: $*" >&2; }
die()  { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# --- CANN + ATB environment ------------------------------------------------
# The image already carries these as ENV so a plain `docker run <img> python3`
# works; sourcing the vendor scripts on top picks up anything version-specific.
# nnal/atb is what upstream's Dockerfile.a5 sources before touching
# vllm-ascend, so it is not optional on this target.
#
# The sourcing goes through the shared shim because ATB's set_env.sh is not
# nounset-clean - see common/patches/ascend_setenv_nounset.sh.
. /usr/local/lib/ascend/setenv.sh
ascend_source_setenv

# Upstream's A5 image preloads jemalloc; it measurably reduces fragmentation in
# long-running serving processes. Skipped silently if the library is absent.
if [ "${NO_JEMALLOC:-0}" != "1" ]; then
    jem=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
    [ -e "$jem" ] && export LD_PRELOAD="$jem${LD_PRELOAD:+:$LD_PRELOAD}"
fi

# --- NPU discovery ---------------------------------------------------------
# /dev/davinci<N> are the compute devices. The three control nodes below are
# just as mandatory: without them the runtime cannot open a context, and the
# failure surfaces much later as an opaque ACL error.
devices=()
for dev in /dev/davinci[0-9]*; do
    [ -c "$dev" ] && devices+=("${dev#/dev/}")
done

missing_ctl=()
for ctl in /dev/davinci_manager /dev/devmm_svm /dev/hisi_hdc; do
    [ -e "$ctl" ] || missing_ctl+=("$ctl")
done

log "NPU devices : ${#devices[@]} found${devices[*]:+ (${devices[*]})}"
if [ "${#missing_ctl[@]}" -gt 0 ]; then
    warn "missing control nodes: ${missing_ctl[*]}"
    warn "pass them through with --device, e.g. --device /dev/davinci_manager"
fi

# The host driver is bind-mounted over this path; nothing ships it in the image.
if [ -e /usr/local/Ascend/driver/lib64/libascend_hal.so ]; then
    log "host driver : /usr/local/Ascend/driver present"
elif [ "${#devices[@]}" -gt 0 ]; then
    warn "/usr/local/Ascend/driver is empty - mount the host driver:"
    warn "  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro"
fi

if [ -z "${ASCEND_RT_VISIBLE_DEVICES:-}" ] && [ "${#devices[@]}" -gt 0 ]; then
    ids=$(printf '%s\n' "${devices[@]}" | sed 's/^davinci//' | sort -n | paste -sd,)
    export ASCEND_RT_VISIBLE_DEVICES="$ids"
fi
log "ASCEND_RT_VISIBLE_DEVICES=${ASCEND_RT_VISIBLE_DEVICES:-<unset>}"
log "SOC_VERSION=${SOC_VERSION:-<unset>}"

command -v npu-smi >/dev/null 2>&1 && npu-smi info 2>/dev/null | head -12

# --- dispatch --------------------------------------------------------------
[ "$#" -eq 0 ] && set -- serve

case "$1" in
    verify)
        exec /usr/local/bin/verify-runtime.sh
        ;;
    serve)
        shift
        ;;
    *)
        exec "$@"
        ;;
esac

if [ "${#devices[@]}" -eq 0 ] && [ "${ALLOW_NO_NPU:-0}" != "1" ]; then
    die "no /dev/davinci* device visible. Run with --device /dev/davinci0 \
--device /dev/davinci_manager --device /dev/devmm_svm --device /dev/hisi_hdc, \
or set ALLOW_NO_NPU=1 to start anyway."
fi

has_flag() {  # <flag> <args...>
    local want="$1"; shift
    for a in "$@"; do
        case "$a" in "$want"|"$want"=*) return 0 ;; esac
    done
    return 1
}

args=()
has_flag --host "$@" || args+=(--host "${HOST:-0.0.0.0}")
has_flag --port "$@" || args+=(--port "${PORT:-8000}")

# NO DTYPE IS FORCED HERE. DaVinci v3 has a bfloat16 path, so the checkpoint's
# own dtype is correct and overriding it degrades quality silently. The 310P
# entrypoint pins --dtype float16 because dav-m200 has no bf16 path at all and
# an unqualified serve of a bf16 checkpoint fails there. Set VLLM_DTYPE to
# override.
if [ -n "${VLLM_DTYPE:-}" ] && ! has_flag --dtype "$@"; then
    args+=(--dtype "$VLLM_DTYPE")
fi

if ! has_flag --tensor-parallel-size "$@" && ! has_flag -tp "$@"; then
    # Floor at 1: with ALLOW_NO_NPU=1 the device count is 0, and vllm rejects
    # --tensor-parallel-size 0.
    tp="${TENSOR_PARALLEL_SIZE:-${#devices[@]}}"
    [ "$tp" -ge 1 ] 2>/dev/null || tp=1
    args+=(--tensor-parallel-size "$tp")
fi

# The model may come from $MODEL or be given positionally as `serve <model>`.
model="${MODEL:-}"
if [ "$#" -gt 0 ]; then
    case "$1" in
        -*) ;;
        *) model="$1"; shift ;;
    esac
fi
[ -n "$model" ] || die "no model given. Set MODEL=<id-or-path> or run: serve <model> [vllm flags]"

log "launching: vllm serve $model ${args[*]} $*"
exec vllm serve "$model" "${args[@]}" "$@"
