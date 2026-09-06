#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Stage deps/950pr-x86_64/ - the complete offline payload for the native
# x86_64 Ascend 950PR image.
#
#   ./provision_deps_950pr_x86_64.sh              stage everything that is missing
#   ./provision_deps_950pr_x86_64.sh cann         only the CANN .run files
#   ./provision_deps_950pr_x86_64.sh debs wheels  a subset, in this order:
#       cann | cann_extra | src | thirdparty | debs | vllm | wheels | verify
#
# THIS IS THE ONLY STEP THAT USES THE NETWORK. Once it completes,
# build_950pr_x86_64.sh runs with --network=none, and a successful build is
# itself the proof that the payload is complete.
#
# Unlike provision_deps_aarch64.sh there is NO QEMU here: host and target are
# both x86_64, so every container below runs natively and resolves wheels and
# .debs against the real target environment rather than an emulated one.
#
# What lands where:
#   Ascend-cann-toolkit_9.1.0_linux-x86_64.run   Huawei OBS bucket
#   Ascend-cann-nnal_9.1.0_linux-x86_64.run      same bucket (ATB lives here)
#   apt_debs/                                    ubuntu:22.04 container
#   python_wheels/                               ubuntu:22.04 container, cp310
#   src/vllm-ascend/                             codeload tarball (+ catlass)
#   src/vllm/                                    PyPI sdist, then built to a wheel
#   cann_extra/lib64/                            26 libraries the toolkit omits,
#                                                lifted from the vendor image
#   third_party/                                 abseil / protobuf / json for the
#                                                ascend950 ACLNN op build
# ---------------------------------------------------------------------------
set -euo pipefail

CONTEXT="${CONTEXT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DEPS_DIR="${DEPS_DIR:-$CONTEXT/deps/950pr-x86_64}"
TARGET_DIR="${TARGET_DIR:-$CONTEXT/docker/target-950pr}"
CANN_VERSION="${CANN_VERSION:-9.1.0}"
VLLM_REF="${VLLM_REF:-v0.27.1}"
VLLM_ASCEND_REF="${VLLM_ASCEND_REF:-main}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:22.04}"

OBS="https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/CANN/CANN%20${CANN_VERSION}"
TOOLKIT="Ascend-cann-toolkit_${CANN_VERSION}_linux-x86_64.run"
NNAL="Ascend-cann-nnal_${CANN_VERSION}_linux-x86_64.run"
TOOLKIT_BYTES=1298337341
NNAL_BYTES=572750476

# ---------------------------------------------------------------------------
# Which PyPI index to resolve against.
# ---------------------------------------------------------------------------
# Defaults to PyPI and only falls back when PyPI is genuinely unreachable, which
# is not hypothetical here: pypi.org/simple timed out for ~20 s at a point when
# files.pythonhosted.org, download.pytorch.org and the Tsinghua mirror were all
# answering in under two seconds. The index and the file CDN fail independently.
#
# The fallback is the mirror upstream's own Dockerfile.a5 defaults to
# (PIP_INDEX_URL="https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple"), so
# this is upstream practice rather than an invention. Set PIP_INDEX_URL
# explicitly to pin either way and skip the probe.
PIP_INDEX_FALLBACK="${PIP_INDEX_FALLBACK:-https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple}"
resolve_index() {
    if [ -n "${PIP_INDEX_URL:-}" ]; then
        echo "  index    : $PIP_INDEX_URL (pinned by PIP_INDEX_URL)"
        return 0
    fi
    if curl -sSf -o /dev/null --max-time 20 https://pypi.org/simple/pip/ 2>/dev/null; then
        PIP_INDEX_URL="https://pypi.org/simple"
        echo "  index    : $PIP_INDEX_URL"
    else
        PIP_INDEX_URL="$PIP_INDEX_FALLBACK"
        echo "  index    : pypi.org/simple unreachable; falling back to $PIP_INDEX_URL" >&2
    fi
    export PIP_INDEX_URL
}

step() { echo; echo "##### $* #####"; }
warn() { echo "  WARN: $*" >&2; }
die()  { echo "  ERROR: $*" >&2; exit 1; }
drun() { docker run --rm --platform linux/amd64 "$@"; }

mkdir -p "$DEPS_DIR/apt_debs" "$DEPS_DIR/python_wheels" "$DEPS_DIR/src"

# ---------------------------------------------------------------------------
# Resumable fetch, single stream.
# ---------------------------------------------------------------------------
# NOT "curl --retry" together with "-C -": that pairing restarted the 1.3 GB
# toolkit from byte 0 on the first dropped connection and truncated what was
# already on disk. Each attempt here is a fresh curl resuming from the current
# file size, so progress is monotonic and a stall costs one attempt, not the
# file. --speed-limit/--speed-time drop a connection that has gone quiet
# instead of hanging on it indefinitely.
#
# Used for sources of unknown length (codeload tarballs, which are generated on
# the fly and cannot be resumed or range-requested at all). Sized artefacts go
# through fetch_parallel below instead.
fetch_resumable() {   # <url> <dest> <expected-bytes|0>
    local url="$1" out="$2" want="${3:-0}" cur att=0
    while :; do
        cur=$(stat -c%s "$out" 2>/dev/null || echo 0)
        if [ "$want" != "0" ] && [ "$cur" -ge "$want" ]; then return 0; fi
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

# ---------------------------------------------------------------------------
# Resumable fetch, parallel chunks. THIS IS THE ONE THAT MATTERS FOR CANN.
# ---------------------------------------------------------------------------
# The OBS bucket throttles per connection, and hard: measured back-to-back on
# the same file, one stream sustained 371 KB/s while four parallel ranges
# totalled 978 KB/s, and eight chunks reached 4.3 MB/s. That is the difference
# between a ninety-minute toolkit download and a five-minute one, so the
# parallelism is not premature optimisation - it is what makes staging
# practical on this link.
#
# Each chunk appends to its own .part file, so every chunk resumes
# independently and a dropped connection costs only that chunk's tail. Chunks
# are concatenated in order onto whatever prefix is already on disk, which also
# means switching to this function mid-download preserves the bytes a previous
# single-stream run had fetched.
CONNS="${CONNS:-8}"
fetch_parallel() {   # <url> <dest> <expected-bytes>
    local url="$1" out="$2" want="$3"
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
            local part="$out.part.$i" have need att=0
            need=$((end - start + 1))
            while :; do
                have=$(stat -c%s "$part" 2>/dev/null || echo 0)
                [ "$have" -ge "$need" ] && break
                att=$((att + 1)); [ "$att" -gt 200 ] && exit 1
                # --max-time as well as --speed-limit: a chunk was observed
                # sitting at 4 KB for minutes without the speed guard firing,
                # so a hard ceiling per attempt is what actually breaks a
                # wedged connection. The retry resumes from what landed.
                curl -fL --no-progress-meter -r $((start + have))-$end \
                     --connect-timeout 30 --speed-limit 2048 --speed-time 60 \
                     --max-time 900 \
                     "$url" >> "$part" 2>/dev/null || true
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

# ---------------------------------------------------------------------------
do_cann() {
    step "CANN ${CANN_VERSION} x86_64 (toolkit + NNAL/ATB)"
    fetch_parallel "$OBS/$TOOLKIT" "$DEPS_DIR/$TOOLKIT" "$TOOLKIT_BYTES"
    fetch_parallel "$OBS/$NNAL"    "$DEPS_DIR/$NNAL"    "$NNAL_BYTES"
    echo "  sha256 (pin these into $TARGET_DIR/deps.manifest):"
    ( cd "$DEPS_DIR" && sha256sum "$TOOLKIT" "$NNAL" | sed 's/^/    /' )
}

do_src() {
    step "vllm-ascend source (@${VLLM_ASCEND_REF})"
    # Tarball, not git clone: the Dockerfile deletes .git anyway (setuptools-scm
    # is handed VLLM_ASCEND_VERSION), and a depth-1 clone cannot resume a
    # dropped connection - it died with "early EOF" and git removed the
    # partial checkout, losing everything already transferred.
    local tb="$DEPS_DIR/src/vllm-ascend-${VLLM_ASCEND_REF}.tar.gz"
    if [ ! -f "$DEPS_DIR/src/vllm-ascend/setup.py" ]; then
        fetch_resumable \
            "https://codeload.github.com/vllm-project/vllm-ascend/tar.gz/refs/heads/${VLLM_ASCEND_REF}" \
            "$tb" 0
        tar -tzf "$tb" >/dev/null || die "vllm-ascend tarball is truncated"
        rm -rf "$DEPS_DIR/src/vllm-ascend"
        mkdir -p "$DEPS_DIR/src/vllm-ascend"
        tar -xzf "$tb" -C "$DEPS_DIR/src/vllm-ascend" --strip-components=1
    fi
    echo "  vllm-ascend: $(find "$DEPS_DIR/src/vllm-ascend" -type f | wc -l) files"

    # catlass, the one git submodule the build actually needs.
    #
    # csrc/build_aclnn.sh takes the ascend950 branch and calls
    # setup_catlass_dependency(), which checks for
    # csrc/third_party/catlass/include and, if it is missing, runs
    # `git submodule update --init --recursive`. Under --network=none (and with
    # .git deleted) that fails and takes the whole wheel build down with
    # "[build_aclnn] fetch failed". A codeload tarball carries the empty
    # submodule directory but none of its contents, so it has to be staged
    # separately - and staging it is enough, because the script skips the fetch
    # entirely when include/ already exists.
    #
    # The commit is the one .gitmodules pins, read from the checkout rather than
    # hardcoded here, so a vllm-ascend bump moves it automatically.
    local cat_dir="$DEPS_DIR/src/vllm-ascend/csrc/third_party/catlass"
    if [ -d "$cat_dir/include" ]; then
        echo "  catlass: already staged ($(find "$cat_dir" -type f | wc -l) files)"
    else
        local cat_url cat_commit
        cat_url=$(git config -f "$DEPS_DIR/src/vllm-ascend/.gitmodules" \
                  --get submodule.csrc/third_party/catlass.url 2>/dev/null)
        cat_commit=$(git config -f "$DEPS_DIR/src/vllm-ascend/.gitmodules" \
                     --get submodule.csrc/third_party/catlass.commit 2>/dev/null)
        [ -n "$cat_url" ] && [ -n "$cat_commit" ] || die "cannot read the catlass submodule pin from .gitmodules"
        echo "  catlass: fetching ${cat_commit:0:12} from $cat_url"
        rm -rf /tmp/catlass-stage
        mkdir -p /tmp/catlass-stage
        ( cd /tmp/catlass-stage \
          && git init -q . \
          && git remote add origin "$cat_url" \
          && if git fetch -q --depth 1 origin "$cat_commit" 2>/dev/null; then
                 git checkout -q FETCH_HEAD
             else
                 # Not every host allows fetching a bare commit; fall back.
                 cd /tmp && rm -rf catlass-stage \
                 && git clone -q "$cat_url" catlass-stage \
                 && cd catlass-stage && git checkout -q "$cat_commit"
             fi ) || die "failed to fetch catlass at $cat_commit"
        mkdir -p "$cat_dir"
        cp -a /tmp/catlass-stage/. "$cat_dir"/
        rm -rf "$cat_dir/.git" /tmp/catlass-stage
        echo "  catlass: staged $(find "$cat_dir" -type f | wc -l) files"
    fi
    [ -d "$cat_dir/include" ] || die "catlass/include is missing; the ascend950 ACLNN build needs it"

    step "vLLM source (${VLLM_REF})"
    # The PyPI sdist, not a git clone. It is a proper source distribution with
    # PKG-INFO, so the version is baked in and setuptools-scm never has to shell
    # out to git - which matters because the wheel is built in a container where
    # the checkout would be flagged as dubious ownership anyway. It is also a
    # single resumable HTTP object on a link where cloning has failed outright.
    local vs="$DEPS_DIR/src/vllm-${VLLM_REF#v}.tar.gz"
    if [ ! -f "$DEPS_DIR/src/vllm/setup.py" ]; then
        local url bytes
        read -r url bytes < <(python3 - "$VLLM_REF" <<'PY'
import json, sys, urllib.request
ver = sys.argv[1].lstrip("v")
d = json.load(urllib.request.urlopen(
    "https://pypi.org/pypi/vllm/%s/json" % ver, timeout=60))
for f in d["urls"]:
    if f["packagetype"] == "sdist":
        print(f["url"], f["size"])
        break
PY
)
        [ -n "${url:-}" ] || die "no sdist published for vllm ${VLLM_REF}"
        fetch_parallel "$url" "$vs" "$bytes"
        tar -tzf "$vs" >/dev/null || die "vllm sdist is truncated"
        rm -rf "$DEPS_DIR/src/vllm"
        mkdir -p "$DEPS_DIR/src/vllm"
        tar -xzf "$vs" -C "$DEPS_DIR/src/vllm" --strip-components=1
    fi
    echo "  vllm: $(find "$DEPS_DIR/src/vllm" -maxdepth 1 -type f | wc -l) top-level files"
}

# ---------------------------------------------------------------------------
# cann_extra: the runtime libraries the standalone toolkit omits.
# ---------------------------------------------------------------------------
# The public CANN 9.1.0 toolkit ships 150 shared objects in lib64; Huawei's own
# image for this SoC ships 176. Three of the twenty-six missing ones are
# load-bearing - libopapi.so (vllm-ascend links -lopapi for every SoC),
# libopapi_math.so (the custom-op package will not install without it) and
# libhccl.so (torch_npu's DT_NEEDED) - and none are separately downloadable:
# kernels-{950,a5,910b} and nnrt all return 403 from the OBS bucket.
#
# They are taken from the vendor image WITHOUT a docker pull: the amd64
# manifest is resolved through the registry API and the single 4.4 GB CANN
# layer is fetched with the same parallel range-request downloader used for the
# .run files (~70 s at ~20 MB/s against ~2 MB/s for a single stream), then only
# the missing .so files are extracted. Same manoeuvre the 310P used for
# libhccl.so on CANN 8.5.0.
VENDOR_IMAGE="${VENDOR_IMAGE:-ascend/cann}"
VENDOR_TAG="${VENDOR_TAG:-9.1.0-950-ubuntu22.04-py3.10}"

do_cann_extra() {
    step "cann_extra (libraries absent from the standalone toolkit)"
    local dest="$DEPS_DIR/cann_extra/lib64"
    if [ -e "$dest/libopapi.so" ] && [ -e "$dest/libhccl.so" ]; then
        echo "  already staged: $(ls "$dest" | wc -l) libraries, $(du -sh "$DEPS_DIR/cann_extra" | cut -f1)"
        return 0
    fi
    mkdir -p "$dest"
    local tok acc blob size scratch=/var/tmp/cann-extra-stage
    tok=$(curl -sS --max-time 60 \
          "https://quay.io/v2/auth?service=quay.io&scope=repository:${VENDOR_IMAGE}:pull" \
          | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))')
    [ -n "$tok" ] || die "could not obtain a quay.io pull token"
    acc='application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json'

    # The tag is a multi-arch index; resolve the amd64 manifest, then its
    # largest layer, which is the CANN installation.
    read -r blob size < <(
        curl -sS --max-time 90 -H "Authorization: Bearer $tok" -H "Accept: $acc" \
             "https://quay.io/v2/${VENDOR_IMAGE}/manifests/${VENDOR_TAG}" -o /tmp/_idx.json
        python3 - "$tok" "$VENDOR_IMAGE" "$acc" <<'PY'
import json, subprocess, sys
tok, image, acc = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open('/tmp/_idx.json'))
if 'manifests' in d:
    amd = [m for m in d['manifests']
           if m.get('platform', {}).get('architecture') == 'amd64']
    dig = amd[0]['digest']
    out = subprocess.run(
        ['curl', '-sS', '--max-time', '90', '-H', 'Authorization: Bearer ' + tok,
         '-H', 'Accept: ' + acc,
         'https://quay.io/v2/%s/manifests/%s' % (image, dig)],
        capture_output=True, text=True).stdout
    d = json.loads(out)
big = max(d['layers'], key=lambda l: l['size'])
print(big['digest'], big['size'])
PY
    )
    [ -n "${blob:-}" ] || die "could not resolve the vendor image's CANN layer"
    echo "  layer $blob ($(( size / 1024 / 1024 )) MB)"

    mkdir -p "$scratch"
    QUAY_TOKEN="$tok" fetch_parallel_auth \
        "https://quay.io/v2/${VENDOR_IMAGE}/blobs/${blob}" "$scratch/layer.tar.gz" "$size"

    echo "  extracting the libraries missing from the toolkit"
    rm -rf "$scratch/x" && mkdir -p "$scratch/x"
    tar -xzf "$scratch/layer.tar.gz" -C "$scratch/x" \
        --wildcards '*x86_64-linux/lib64/libopapi*' \
                    '*x86_64-linux/lib64/libhccl*' \
                    '*x86_64-linux/lib64/libes_*' \
                    '*x86_64-linux/lib64/libdvpp_*' \
                    '*x86_64-linux/lib64/libacl_dvpp*' \
                    '*x86_64-linux/lib64/libops_host_cpu.so' \
                    '*x86_64-linux/lib64/libop_common.so' \
                    '*x86_64-linux/lib64/libconstant_folding_ops.so' \
                    '*x86_64-linux/lib64/libllm_datadist.so' \
                    '*x86_64-linux/lib64/libcann_hixl.so' 2>/dev/null || true
    find "$scratch/x" -path '*x86_64-linux/lib64/*.so' -exec cp -a {} "$dest"/ \;
    rm -rf "$scratch"
    [ -e "$dest/libopapi.so" ] || die "libopapi.so not found in the vendor layer"
    [ -e "$dest/libhccl.so" ] || die "libhccl.so not found in the vendor layer"
    echo "  staged $(ls "$dest" | wc -l) libraries, $(du -sh "$DEPS_DIR/cann_extra" | cut -f1)"
}

# fetch_parallel, but sending the registry bearer token on every chunk.
fetch_parallel_auth() {   # <url> <dest> <expected-bytes>
    local url="$1" out="$2" want="$3"
    touch "$out"
    local head rem csz i start end
    head=$(stat -c%s "$out")
    [ "$head" -ge "$want" ] && return 0
    rem=$((want - head)); csz=$(( (rem + CONNS - 1) / CONNS ))
    echo "  fetching $rem bytes over $CONNS connections"
    for i in $(seq 0 $((CONNS - 1))); do
        start=$((head + i * csz)); end=$((start + csz - 1))
        [ "$end" -ge "$want" ] && end=$((want - 1))
        [ "$start" -gt "$end" ] && continue
        (
            local part="$out.part.$i" have need att=0
            need=$((end - start + 1))
            while :; do
                have=$(stat -c%s "$part" 2>/dev/null || echo 0)
                [ "$have" -ge "$need" ] && break
                att=$((att + 1)); [ "$att" -gt 60 ] && exit 1
                curl -sSL -H "Authorization: Bearer $QUAY_TOKEN" \
                     -r $((start + have))-$end --connect-timeout 30 \
                     --speed-limit 2048 --speed-time 60 --max-time 1800 \
                     "$url" >> "$part" 2>/dev/null || true
                sleep 2
            done
        ) &
    done
    wait
    for i in $(seq 0 $((CONNS - 1))); do
        [ -f "$out.part.$i" ] && { cat "$out.part.$i" >> "$out"; rm -f "$out.part.$i"; }
    done
    [ "$(stat -c%s "$out")" -eq "$want" ] || die "vendor layer download is short"
}

do_thirdparty() {
    step "vllm-ascend ACLNN third-party archives"
    local tp="$DEPS_DIR/third_party"
    mkdir -p "$tp/pkg" "$tp/json"
    # Each of these is checked under ${CANN_3RD_LIB_PATH} by the corresponding
    # cmake/third_party/*.cmake before it reaches for gitcode.com. makeself is
    # absent on purpose: CANN ships one and the Dockerfile copies it in.
    local base=https://gitcode.com/cann-src-third-party
    # These are immutable release artefacts of unknown declared length, so an
    # existing non-empty file is taken as complete. Without this check
    # fetch_resumable cannot tell "done" from "stalled" (it has no expected size
    # to compare against) and loops until the CDN starts answering 416 Range Not
    # Satisfiable, which is the server saying the file was already whole.
    get_once() {   # <url> <dest>
        if [ -s "$2" ]; then
            echo "  $(basename "$2"): already staged ($(stat -c%s "$2") bytes)"
        else
            fetch_resumable "$1" "$2" 0
        fi
    }
    get_once "$base/abseil-cpp/releases/download/20230802.1/abseil-cpp-20230802.1.tar.gz" \
             "$tp/pkg/abseil-cpp-20230802.1.tar.gz"
    get_once "$base/protobuf/releases/download/v25.1/protobuf-25.1.tar.gz" \
             "$tp/pkg/protobuf-25.1.tar.gz"
    get_once "$base/json/releases/download/v3.11.3/include.zip" \
             "$tp/pkg/include.zip"
    if [ ! -f "$tp/json/include/nlohmann/json.hpp" ]; then
        python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
                "$tp/pkg/include.zip" "$tp/json"
    fi
    [ -f "$tp/json/include/nlohmann/json.hpp" ] || die "nlohmann/json.hpp was not extracted"
    echo "  third_party: $(du -sh "$tp" | cut -f1)"
}

do_debs() {
    step "apt archive (amd64, jammy)"
    drun -v "$TARGET_DIR/scripts:/prov-scripts:ro" \
         -v "$TARGET_DIR/packages/sys_packages.txt:/prov/packages.txt:ro" \
         -v "$DEPS_DIR/apt_debs:/out" \
         "$BASE_IMAGE" bash /prov-scripts/fetch_debs.sh
    [ -f "$DEPS_DIR/apt_debs/Packages.gz" ] || die "apt archive has no Packages.gz"
}

do_vllm() {
    step "vLLM wheel (VLLM_TARGET_DEVICE=empty)"
    [ -d "$DEPS_DIR/src/vllm" ] || die "run the 'src' stage first"
    if ls "$DEPS_DIR"/python_wheels/vllm-*.whl >/dev/null 2>&1; then
        echo "  already built: $(basename "$(ls "$DEPS_DIR"/python_wheels/vllm-*.whl | head -1)")"
        return 0
    fi
    # Seed the torch wheels first: setup.py imports torch to stamp the wheel, and
    # pulling it inside the container over one connection is the slowest step in
    # provisioning. /out is the wheelhouse, so build_vllm_wheel.sh finds it there.
    do_torch
    resolve_index
    drun -e PIP_INDEX_URL="$PIP_INDEX_URL" \
         -v "$TARGET_DIR/scripts:/prov-scripts:ro" \
         -v "$TARGET_DIR/constraints.x86_64.txt:/prov/constraints.x86_64.txt:ro" \
         -v "$DEPS_DIR/src/vllm:/src/vllm" \
         -v "$DEPS_DIR/apt_debs:/debs:ro" \
         -v "$DEPS_DIR/python_wheels:/out" \
         "$BASE_IMAGE" bash /prov-scripts/build_vllm_wheel.sh
}

# The torch stack is ~250 MB of the wheelhouse and pip fetches it over a single
# connection, which on this link crawled at ~65 KB/s and dominated provisioning.
# download.pytorch.org advertises accept-ranges: bytes, so the same
# parallel-chunk fetch used for CANN applies, and these three wheels have to end
# up in python_wheels/ regardless. Seeding them first means pip finds them via
# --find-links and never downloads them at all.
TORCH_WHEELS=(
    "torch-2.10.0%2Bcpu-cp310-cp310-manylinux_2_28_x86_64.whl|188832554"
    "torchvision-0.25.0%2Bcpu-cp310-cp310-manylinux_2_28_x86_64.whl|0"
    "torchaudio-2.10.0%2Bcpu-cp310-cp310-manylinux_2_28_x86_64.whl|0"
)

do_torch() {
    step "torch stack (parallel seed into the wheelhouse)"
    local entry enc bytes name url
    for entry in "${TORCH_WHEELS[@]}"; do
        enc="${entry%%|*}"; bytes="${entry##*|}"
        name="${enc//%2B/+}"
        url="https://download.pytorch.org/whl/cpu/$enc"
        if [ -f "$DEPS_DIR/python_wheels/$name" ]; then
            echo "  $name already staged"
            continue
        fi
        if [ "$bytes" = "0" ]; then
            bytes=$(curl -sSI --max-time 60 "$url" \
                    | awk 'tolower($1) ~ /^content-length:/ {gsub(/\r/,"",$2); print $2}' | tail -1)
            [ -n "$bytes" ] || die "could not determine the size of $name"
        fi
        fetch_parallel "$url" "$DEPS_DIR/python_wheels/$name" "$bytes"
    done
}

do_wheels() {
    do_torch
    step "cp310 wheelhouse"
    resolve_index
    drun -e PIP_INDEX_URL="$PIP_INDEX_URL" \
         -v "$TARGET_DIR/scripts:/prov-scripts:ro" \
         -v "$TARGET_DIR/constraints.x86_64.txt:/prov/constraints.x86_64.txt:ro" \
         -v "$TARGET_DIR/requirements/python_wheels.txt:/prov/python_wheels.txt:ro" \
         -v "$DEPS_DIR/src/vllm-ascend:/src/vllm-ascend:ro" \
         -v "$DEPS_DIR/apt_debs:/debs:ro" \
         -v "$DEPS_DIR/python_wheels:/wheels" \
         "$BASE_IMAGE" bash /prov-scripts/fetch_wheels.sh
}

# ---------------------------------------------------------------------------
# The CUDA gate, applied to the payload as a whole.
# ---------------------------------------------------------------------------
# fetch_wheels.sh already refuses to finish a resolve that produced NVIDIA
# wheels; this re-checks the directory that the build actually mounts, so a
# wheel dropped in by hand is caught too. An Ascend image has no use for any
# of it, and a CUDA torch would shadow the CPU build torch_npu links against.
do_verify() {
    step "payload check"
    local bad
    # -name '*.whl' MATTERS: without it this matched thirty JSON files in the
    # vLLM source tree - vllm/kernels/helion/configs/*/nvidia_h100.json and
    # friends, Helion autotuning configs named after the GPU they were tuned on.
    # They are neither wheels nor CUDA binaries, and src/vllm is excluded from
    # the build context entirely, so matching them was a pure false positive
    # that failed a clean payload. What matters is that no CUDA *wheel* is
    # installable, so only wheels are inspected.
    bad=$(find "$DEPS_DIR" -type f -name '*.whl' \( -iname 'nvidia_*' -o -iname 'nvidia-*' \
            -o -iname '*cudnn*' -o -iname '*cublas*' \) | sort)
    if [ -n "$bad" ]; then
        echo "  CUDA artefacts found under $DEPS_DIR:" >&2
        echo "$bad" | sed 's/^/    /' >&2
        die "an Ascend payload must contain no NVIDIA wheels - see $TARGET_DIR/constraints.x86_64.txt"
    fi
    echo "  no nvidia_* / cudnn / cublas artefacts anywhere under deps/"

    if ls "$DEPS_DIR"/python_wheels/torch-*+cpu-*.whl >/dev/null 2>&1; then
        echo "  torch: $(basename "$(ls "$DEPS_DIR"/python_wheels/torch-*+cpu-*.whl | head -1)")"
    else
        warn "no torch-*+cpu-*.whl staged yet"
    fi
    echo "  total: $(du -sh "$DEPS_DIR" | cut -f1)"
    echo
    echo "  Now run:  ./build_950pr_x86_64.sh"
}

STAGES=("$@")
if [ "${#STAGES[@]}" -eq 0 ]; then
    STAGES=(cann cann_extra src thirdparty debs vllm wheels verify)
fi
for s in "${STAGES[@]}"; do
    case "$s" in
        cann)       do_cann ;;
        cann_extra) do_cann_extra ;;
        src)        do_src ;;
        thirdparty) do_thirdparty ;;
        debs)   do_debs ;;
        vllm)   do_vllm ;;
        wheels) do_wheels ;;
        verify) do_verify ;;
        *)      die "unknown stage '$s' (cann cann_extra src thirdparty debs vllm wheels verify)" ;;
    esac
done
