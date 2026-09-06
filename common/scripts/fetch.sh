#!/usr/bin/env bash
# Resumable download primitives. Source; do not execute.
#
#   . common/scripts/fetch.sh
#   fetch_resumable <url> <dest> <expected-bytes|0>
#   fetch_once      <url> <dest>
#   fetch_parallel  <url> <dest> <expected-bytes> [bearer-token]
#
# Preconditions: curl, stat and seq on PATH; the caller defines die().
# All three are idempotent: a complete file is a no-op, a partial file resumes.
#
# FAILURE MODE - `curl --retry` combined with `-C -` restarts a dropped
# transfer at byte 0 and truncates the file already on disk. Measured cost:
# 96 MB of a 1.3 GB toolkit. Each attempt below is a fresh curl resuming from
# the current file size, so progress is monotonic.
#
# CONNS is per-host policy, not a universal speedup. Measured:
#   Huawei OBS                       371 KB/s single, 4.3 MB/s over 8 chunks
#   download.pytorch.org             180 MB wheel under 20 s over 8 chunks
#   quay.io blobs                    2 MB/s single, 20 MB/s over 8 chunks
#   files.pythonhosted.org (Fastly)  2.9 MB/s single, 287 KB/s over 8 - worse
# pip against PyPI stays on a single stream.
CONNS="${CONNS:-8}"

# Single stream. For sources of unknown length: codeload tarballs are generated
# per request and support neither resume nor range.
fetch_resumable() {   # <url> <dest> <expected-bytes|0>
    local url="$1" out="$2" want="${3:-0}" cur att=0
    while :; do
        cur=$(stat -c%s "$out" 2>/dev/null || echo 0)
        [ "$want" != "0" ] && [ "$cur" -ge "$want" ] && return 0
        att=$((att + 1))
        [ "$att" -gt 300 ] && die "gave up on $(basename "$out") at $cur/$want bytes"
        if [ "$want" != "0" ]; then
            echo "  $(basename "$out"): attempt $att from $cur/$want ($((cur * 100 / want))%)"
        else
            echo "  $(basename "$out"): attempt $att from $cur"
        fi
        if curl -fL --no-progress-meter -C - -o "$out" \
                --connect-timeout 30 --speed-limit 4096 --speed-time 120 "$url"; then
            [ "$want" = "0" ] && return 0
        fi
        sleep 3
    done
}

# Immutable release artefact of undeclared length: a non-empty file is complete.
# Without this test the caller cannot distinguish "done" from "stalled" and
# loops until the CDN answers 416 Range Not Satisfiable.
fetch_once() {   # <url> <dest>
    if [ -s "$2" ]; then
        echo "  $(basename "$2"): already staged ($(stat -c%s "$2") bytes)"
        return 0
    fi
    fetch_resumable "$1" "$2" 0
}

# Chunked ranges, for sized artefacts on range-capable hosts. Each chunk appends
# to its own .part file and resumes independently; a dropped connection costs
# one chunk's tail. Parts concatenate in order onto any prefix already present,
# so switching from fetch_resumable mid-download keeps the bytes already fetched.
#
# A bearer token, when given, is sent on every chunk (registry blob endpoints).
fetch_parallel() {   # <url> <dest> <expected-bytes> [bearer-token]
    local url="$1" out="$2" want="$3" token="${4:-}"
    touch "$out"
    local head rem csz i start end
    head=$(stat -c%s "$out")
    if [ "$head" -ge "$want" ]; then
        echo "  $(basename "$out"): already complete ($want bytes)"
        return 0
    fi
    rem=$((want - head))
    csz=$(( (rem + CONNS - 1) / CONNS ))
    echo "  $(basename "$out"): have $head, fetching $rem more over $CONNS connections"

    for i in $(seq 0 $((CONNS - 1))); do
        start=$((head + i * csz))
        end=$((start + csz - 1))
        [ "$end" -ge "$want" ] && end=$((want - 1))
        [ "$start" -gt "$end" ] && continue
        (
            local part="$out.part.$i" have need att=0 auth=()
            [ -n "$token" ] && auth=(-H "Authorization: Bearer $token")
            need=$((end - start + 1))
            while :; do
                have=$(stat -c%s "$part" 2>/dev/null || echo 0)
                [ "$have" -ge "$need" ] && break
                att=$((att + 1)); [ "$att" -gt 200 ] && exit 1
                # --max-time as well as --speed-limit: a chunk was observed
                # holding at 4 KB for minutes without the speed guard firing.
                curl -fLsS "${auth[@]}" -r $((start + have))-$end \
                     --connect-timeout 30 --speed-limit 2048 --speed-time 60 \
                     --max-time 1800 "$url" >> "$part" 2>/dev/null || true
                sleep 2
            done
        ) &
    done
    wait

    for i in $(seq 0 $((CONNS - 1))); do
        [ -f "$out.part.$i" ] || continue
        cat "$out.part.$i" >> "$out"
        rm -f "$out.part.$i"
    done
    local got; got=$(stat -c%s "$out")
    [ "$got" -eq "$want" ] || die "$(basename "$out") is $got bytes, expected $want"
    echo "  $(basename "$out"): $got bytes, complete"
}
