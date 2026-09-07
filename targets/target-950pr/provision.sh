#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Stage deps/950pr-x86_64/ - the complete offline payload for the native
# x86_64 Ascend 950PR image.
#
#   ./targets/target-950pr/provision.sh              stage everything that is missing
#   ./targets/target-950pr/provision.sh cann         only the CANN .run files
#   ./targets/target-950pr/provision.sh debs wheels  a subset, in this order:
#       cann | cann_extra | src | thirdparty | debs | vllm | wheels | verify
#
# THIS IS THE ONLY STEP THAT USES THE NETWORK. Once it completes,
# targets/target-950pr/build.sh runs with --network=none, and a successful build is
# itself the proof that the payload is complete.
#
# Unlike targets/target-310p/provision.sh there is NO QEMU here: host and target are
# both x86_64, so every container below runs natively and resolves wheels and
# .debs against the real target environment rather than an emulated one.
#
# CANN NOW COMES FROM HUAWEI'S OFFICIAL DevCloud APT REPOSITORY - NOT FROM THE
# OBS BUCKET, AND NOT FROM A .run INSTALLER.
#
# That repository publishes the 9.2.0 beta line, which the OBS bucket does not:
# probed 2026-09-07, every 9.2.0 spelling answered 403 there while 9.0.0 and
# 9.1.0 answered 206. It is also GPG-signed, which the bucket fetch never was -
# the download below is authenticated by apt against Huawei's own key rather
# than trusted because it arrived over TLS.
#
# TWO VERSION VARIABLES, AND THEY ARE NOT THE SAME THING:
#
#   CANN_VERSION      the release LINE - 9.2.0. Drives the on-disk layout the
#                     image builds (cann-9.2.0, ascend-toolkit/9.2.0) and every
#                     assertion that the installed tree is the release that was
#                     asked for. This is what a CANN install calls itself
#                     internally, in ascend_toolkit_install.info.
#   CANN_APT_VERSION  the exact Debian version pinned in apt - 9.2.0-beta.2.
#
# A beta is a separate package version of the same line, so the two spellings
# genuinely differ, and collapsing them would either break the apt pin or push
# "-beta.2" into filesystem paths that no CANN consumer ever looks for.
#
# `CANN_VERSION=9.1.0 CANN_APT_VERSION=9.1.0 ./provision.sh` still stages the
# previous line unchanged - the repository carries 8.5.0 through 9.2.0-beta.2.
# A site with no route to the repository at all takes the .debs from
# $CANN_LOCAL_DIR instead; see the note on CANN_LOCAL_DIR below.
#
# What lands where ($V = $CANN_VERSION):
#   cann_debs/*.deb                              Huawei's official DevCloud
#                                                apt repository, or
#                                                vendor/cann-${V}/cann_debs/
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

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT="${CONTEXT:-$(cd "$SELF_DIR/../.." && pwd)}"
COMMON_DIR="${COMMON_DIR:-$CONTEXT/common}"
DEPS_DIR="${DEPS_DIR:-$CONTEXT/deps/950pr-x86_64}"
TARGET_DIR="${TARGET_DIR:-$CONTEXT/targets/target-950pr}"
CANN_VERSION="${CANN_VERSION:-9.2.0}"
VLLM_REF="${VLLM_REF:-v0.27.1}"

# ---------------------------------------------------------------------------
# vllm-ascend is PINNED TO A RELEASE BRANCH HEAD, not to `main`.
# ---------------------------------------------------------------------------
# `main` was the previous default and it is the wrong thing to build an
# air-gapped image from: it moves under you, so two provisioning runs a day
# apart produce different images from the same repository state, and the
# Dockerfile stamps SETUPTOOLS_SCM_PRETEND_VERSION=0.26.0 onto whatever it
# happened to fetch.
#
# releases/v0.27.1rc is the branch upstream cuts against vLLM v0.27.1, which is
# already this target's VLLM_REF, and its Dockerfile.a5 - upstream's own
# 950/A5 reference image - pins the same CANN/torch/triton set this target
# stages. VLLM_ASCEND_COMMIT is that branch's head at the time of writing;
# codeload serves a tarball for a bare SHA, so the fetch is reproducible
# rather than "whatever the branch points at today".
#
# To move the pin: set both variables together, and re-read Dockerfile.a5 on
# the new ref before assuming the wheelhouse still matches.
VLLM_ASCEND_REF="${VLLM_ASCEND_REF:-releases/v0.27.1rc}"
VLLM_ASCEND_COMMIT="${VLLM_ASCEND_COMMIT:-e61a5d7204fe4a0fc329471df8e4c3c90e9bb2f1}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:22.04}"

# ---------------------------------------------------------------------------
# catlass, AND WHY ITS PIN HAD TO MOVE WITH CANN.
# ---------------------------------------------------------------------------
# catlass is a git submodule of vllm-ascend, pinned in its .gitmodules - and
# that pin is normally what this script honours, because a vllm-ascend bump
# should carry its own submodule with it.
#
# It cannot be honoured on CANN 9.2.0. The pinned commit
# (41bf90da655bba3c66d0acd7e00abe33960ecfd6, the one vllm-ascend
# releases/v0.27.1rc carries) DOES NOT COMPILE against 9.2.0-beta.2's Bisheng
# compiler. Measured, in a real build:
#
#   block_epilogue_fa_softmax_ascend950.hpp:329:5: error: simd_vf function
#       'ComputeExpSubSum' must be a free function or static member function
#       __simd_vf__ inline void ComputeExpSubSum(...)
#
# CANN 9.2.0 tightened the rule on __attribute__((cce_simd_vf)): such a function
# must now be free or STATIC, and catlass at that commit declares nine of them
# as ordinary non-static members - ComputeMaskandScale, UpdateMax,
# ComputeExpSubSum, UpdateExpSumAndExpMax (fa_softmax), FlashUpdateNew,
# FlashUpdateLastNew, LastDivNew (fa_rescale_o), AivPerTensor and AddBias
# (per_group_per_block). Three ops fail to build as a result - ChunkFwdO,
# ChunkGatedDeltaRuleFwdH and ChunkKdaFwd, the gated-delta-rule / KDA linear
# attention kernels - and the failure surfaces as a confusing linker error,
#   ld.lld: error: cannot open ..._mix_aic_0.o: No such file or directory,
# because the object was never produced.
#
# UPSTREAM CATLASS HAS ALREADY FIXED THIS - commit c89fe73dbb68 ("针对VF函数补充
# `static`修饰"), 2026-07-28, marks all of them static.
#
# MOVING THE PIN FORWARD TO PICK THAT UP DOES NOT WORK, AND THIS WAS TRIED.
# Upstream deleted include/catlass/debug.hpp BEFORE the static fix landed
# (commit 94c354c3), and vllm-ascend at this ref still includes it:
#
#   csrc/.../chunk_gated_delta_rule_fwd_h/op_kernel/arch35/gemm/kernel/
#       gdn_fwd_h_kernel.hpp:16:10:
#       fatal error: 'catlass/debug.hpp' file not found
#
# So NO single catlass commit satisfies both this vllm-ascend ref and CANN
# 9.2.0's compiler. The fix is backported instead - see
# targets/target-950pr/patches/0001-catlass-simd-vf-static.patch, which is
# c89fe73d's semantic change applied to the pinned tree and nothing else.
#
# CATLASS_COMMIT therefore defaults to EMPTY: honour .gitmodules, then patch.
# Set it to an explicit sha only to test a different catlass, in which case the
# patch will very likely no longer apply and CATLASS_PATCH should be set empty
# too.
CATLASS_COMMIT="${CATLASS_COMMIT-}"

# The backport, applied to the staged catlass. Set empty to skip it - correct
# on a CANN line whose Bisheng still accepts non-static simd_vf members.
CATLASS_PATCH="${CATLASS_PATCH-$TARGET_DIR/patches/0001-catlass-simd-vf-static.patch}"

# The exact Debian version. See the two-variable note in the header.
CANN_APT_VERSION="${CANN_APT_VERSION:-9.2.0-beta.2}"

# Huawei's official CANN apt repository, and the keyring package that both
# trusts its signing key and writes the sources.list entry. Installing the
# keyring is what makes this an authenticated fetch rather than a bare
# download; it drops /etc/apt/sources.list.d/ascend-cann.list pointing at
# the `cann` and `hdk` suites, whose `main` component indexes EVERY release
# the repository carries - so pinning an exact version is what selects one,
# and 9.2.0-beta.2 is simply the highest ascend-cann-toolkit there today.
CANN_DEB_REPO="${CANN_DEB_REPO:-https://ascend.devcloud.huaweicloud.com/cann/debian}"
CANN_KEYRING_DEB="${CANN_KEYRING_DEB:-cann-keyring_1.0.0_all.deb}"

# THE PACKAGE SET, AND WHY THE OPS PACKAGE IS IN IT.
#   ascend-cann-toolkit   compiler, ACLNN headers, pyACL, development tree.
#   ascend-cann-950-ops   the Ascend950 operator payload. This is the piece
#                         that had NO published .run at all - probing the OBS
#                         bucket for Ascend-cann-kernels-950 returned 403 -
#                         and whose absence is why this repo used to lift 26
#                         libraries out of a vendor image's layer blob. It is
#                         SoC-specific: 310p/310b/910/910b/A3 have their own,
#                         and installing the wrong one yields an image with no
#                         kernels for its own silicon.
#   ascend-cann-nnal      ATB (Ascend Transformer Boost). Not optional: the
#                         attention paths link against it.
CANN_DEB_PKGS=("ascend-cann-toolkit" "ascend-cann-950-ops" "ascend-cann-nnal")
CANN_DEBS_DIR="$DEPS_DIR/cann_debs"

# apt names a downloaded archive <pkg>_<version>_<arch>.deb, which is NOT the
# filename it has on the repository (Ascend-cann-toolkit_9.2.0-beta.2_linux-
# x86_64.deb). The build mounts what apt produced, so the apt spelling is the
# one deps.manifest and the Dockerfile use.
cann_deb_file() {   # <package>
    echo "$1_${CANN_APT_VERSION}_amd64.deb"
}

# ---------------------------------------------------------------------------
# The strictly air-gapped route: a local drop.
# ---------------------------------------------------------------------------
# Fetching from the DevCloud repository still uses the network ONCE, during
# provisioning - which is the bargain this pipeline is built on, since build.sh
# then runs with --network=none and a successful build is itself the proof that
# the payload is complete. A site that cannot reach the repository from the
# staging host at all copies the .deb files across by hand instead:
#
#     mkdir -p vendor/cann-9.2.0/cann_debs
#     cp ascend-cann-toolkit_9.2.0-beta.2_amd64.deb  vendor/cann-9.2.0/cann_debs/
#     cp ascend-cann-950-ops_9.2.0-beta.2_amd64.deb  vendor/cann-9.2.0/cann_debs/
#     cp ascend-cann-nnal_9.2.0-beta.2_amd64.deb     vendor/cann-9.2.0/cann_debs/
#
# and `provision.sh cann` adopts them with no network at all. To produce those
# files on a connected machine, run this same stage there and copy
# deps/950pr-x86_64/cann_debs/ over: the names apt gives them are exactly the
# names deps.manifest and the Dockerfile expect.
CANN_LOCAL_DIR="${CANN_LOCAL_DIR:-$CONTEXT/vendor/cann-${CANN_VERSION}}"

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

mkdir -p "$DEPS_DIR/apt_debs" "$DEPS_DIR/python_wheels" "$DEPS_DIR/src" "$CANN_DEBS_DIR"

# Download primitives are shared with the 310P target. fetch.sh requires die()
# and is sourced after it is defined.
#   fetch_resumable  single stream, sources of undeclared length
#   fetch_once       immutable release artefact, non-empty means complete
#   fetch_parallel   chunked ranges, sized artefacts on range-capable hosts
[ -f "$COMMON_DIR/scripts/fetch.sh" ] \
    || die "missing $COMMON_DIR/scripts/fetch.sh - run from a complete checkout"
. "$COMMON_DIR/scripts/fetch.sh"
# ---------------------------------------------------------------------------
# Staging CANN from the DevCloud apt repository.
# ---------------------------------------------------------------------------
# The fetch runs INSIDE a container, not on the staging host, and that is
# deliberate rather than incidental:
#
#   * the host may be anything (this was developed on a Windows workstation
#     driving Docker through WSL) and `apt` is not portable to it;
#   * apt is what verifies the repository's GPG signature. Doing the download
#     with curl would fetch exactly the same bytes and authenticate none of
#     them. The keyring package is installed first precisely so that
#     `apt-get update` fails on a bad signature instead of proceeding;
#   * pinning `=${CANN_APT_VERSION}` makes the resolve reproducible. The
#     repository's `main` component indexes every release it has ever carried,
#     so an unpinned install would silently follow the newest beta.
#
# --download-only, not install: nothing is unpacked here. The .debs land in
# deps/950pr-x86_64/cann_debs/ and the image installs them offline, so the
# payload is sealed at the end of provisioning exactly as before.
fetch_cann_debs() {
    local pkgspec=() pkg
    for pkg in "${CANN_DEB_PKGS[@]}"; do pkgspec+=("${pkg}=${CANN_APT_VERSION}"); done
    echo "  fetching: ${pkgspec[*]}"
    echo "  from    : $CANN_DEB_REPO (suite 'cann', component 'main', GPG-verified)"
    drun -e DEBIAN_FRONTEND=noninteractive \
         -e CANN_DEB_REPO="$CANN_DEB_REPO" \
         -e CANN_KEYRING_DEB="$CANN_KEYRING_DEB" \
         -e PKGS="${pkgspec[*]}" \
         -v "$CANN_DEBS_DIR:/out" \
         "$BASE_IMAGE" bash -eux -c '
            apt-get update -qq
            apt-get install -y -qq wget ca-certificates >/dev/null
            cd /tmp
            wget -q "${CANN_DEB_REPO}/${CANN_KEYRING_DEB}"
            # Installs the signing key AND /etc/apt/sources.list.d/ascend-cann.list.
            dpkg -i "${CANN_KEYRING_DEB}"
            # This is the step that authenticates the repository. It fails on a
            # bad or missing signature, which is the whole point of the keyring.
            apt-get update
            mkdir -p /out/partial
            apt-get install -y --download-only -o Dir::Cache::archives=/out ${PKGS}
            # apt leaves its own lock and partial/ behind; the manifest checks
            # this directory, so it must contain nothing but the archives.
            rm -rf /out/partial /out/lock
            # The container runs as root and the host user has to read these
            # back for sha256 and for the build context.
            chmod 0644 /out/*.deb
         '
}

# Take the .debs from a local drop if one is there - the strictly air-gapped
# route described at the top of this file. Copied rather than symlinked because
# DEPS_DIR is bind-mounted into the build and a dangling link inside the build
# context is a confusing failure; `cp -n` never clobbers a staged payload.
adopt_local_debs() {
    local n=0 pkg f
    ls "$CANN_LOCAL_DIR"/cann_debs/*.deb >/dev/null 2>&1 || return 1
    for pkg in "${CANN_DEB_PKGS[@]}"; do
        f=$(cann_deb_file "$pkg")
        [ -f "$CANN_LOCAL_DIR/cann_debs/$f" ] || return 1
    done
    echo "  adopting cann_debs from $CANN_LOCAL_DIR/cann_debs"
    for pkg in "${CANN_DEB_PKGS[@]}"; do
        f=$(cann_deb_file "$pkg")
        cp -n "$CANN_LOCAL_DIR/cann_debs/$f" "$CANN_DEBS_DIR/$f"
        n=$((n+1))
    done
    echo "  adopted $n packages with no network"
    return 0
}

do_cann() {
    step "CANN ${CANN_APT_VERSION} x86_64 (toolkit + 950 ops + NNAL/ATB), via apt"

    local pkg f missing=()
    for pkg in "${CANN_DEB_PKGS[@]}"; do
        f=$(cann_deb_file "$pkg")
        [ -s "$CANN_DEBS_DIR/$f" ] || missing+=("$pkg")
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        echo "  already staged: ${#CANN_DEB_PKGS[@]} packages, $(du -sh "$CANN_DEBS_DIR" | cut -f1)"
    elif adopt_local_debs; then
        :
    else
        fetch_cann_debs
    fi

    # A .deb is an ar archive whose first eight bytes are "!<arch>\n". An error
    # page or a truncated transfer saved under the artefact's name would sail
    # past a size check, so assert the shape rather than the length - the same
    # reason the .run route asserted a makeself "#!" header.
    for pkg in "${CANN_DEB_PKGS[@]}"; do
        f=$(cann_deb_file "$pkg")
        [ -f "$CANN_DEBS_DIR/$f" ] \
            || die "$f was not staged - re-run '$0 cann'"
        head -c 8 "$CANN_DEBS_DIR/$f" | grep -q '^!<arch>' \
            || die "$f is not a Debian package - re-stage it"
    done

    echo "  staged $(ls "$CANN_DEBS_DIR"/*.deb | wc -l) packages, $(du -sh "$CANN_DEBS_DIR" | cut -f1)"
    echo "  sha256 (pin these into $TARGET_DIR/deps.manifest):"
    ( cd "$CANN_DEBS_DIR" && sha256sum ./*.deb | sed 's|  \./|  |' | sed 's/^/    /' )
}

do_src() {
    step "vllm-ascend source (${VLLM_ASCEND_REF} @ ${VLLM_ASCEND_COMMIT:0:12})"
    # Tarball, not git clone: the Dockerfile deletes .git anyway (setuptools-scm
    # is handed VLLM_ASCEND_VERSION), and a depth-1 clone cannot resume a
    # dropped connection - it died with "early EOF" and git removed the
    # partial checkout, losing everything already transferred.
    #
    # BY COMMIT, NOT BY BRANCH. codeload serves /tar.gz/<sha> as well as
    # /tar.gz/refs/heads/<branch>, and the sha is what makes an air-gapped
    # image reproducible: a release branch still moves, and the Dockerfile
    # stamps a fixed SETUPTOOLS_SCM_PRETEND_VERSION onto whatever arrives.
    # Setting VLLM_ASCEND_COMMIT= (empty) falls back to the branch head, which
    # is what you want when deliberately tracking a branch.
    local tb ref
    if [ -n "${VLLM_ASCEND_COMMIT:-}" ]; then
        ref="$VLLM_ASCEND_COMMIT"
        tb="$DEPS_DIR/src/vllm-ascend-${VLLM_ASCEND_COMMIT:0:12}.tar.gz"
    else
        ref="refs/heads/${VLLM_ASCEND_REF}"
        tb="$DEPS_DIR/src/vllm-ascend-${VLLM_ASCEND_REF//\//-}.tar.gz"
    fi
    if [ ! -f "$DEPS_DIR/src/vllm-ascend/setup.py" ]; then
        fetch_resumable \
            "https://codeload.github.com/vllm-project/vllm-ascend/tar.gz/${ref}" \
            "$tb" 0
        tar -tzf "$tb" >/dev/null || die "vllm-ascend tarball is truncated"
        rm -rf "$DEPS_DIR/src/vllm-ascend"
        mkdir -p "$DEPS_DIR/src/vllm-ascend"
        tar -xzf "$tb" -C "$DEPS_DIR/src/vllm-ascend" --strip-components=1
        # Record what was staged so the image and the docs can be traced back
        # to an exact upstream tree without keeping .git around.
        printf 'repo=https://github.com/vllm-project/vllm-ascend\nref=%s\ncommit=%s\nstaged=%s\n' \
            "$VLLM_ASCEND_REF" "${VLLM_ASCEND_COMMIT:-<branch head>}" "$(date -u +%FT%TZ)" \
            > "$DEPS_DIR/src/vllm-ascend/.provenance"
    fi
    echo "  vllm-ascend: $(find "$DEPS_DIR/src/vllm-ascend" -type f | wc -l) files"
    [ -f "$DEPS_DIR/src/vllm-ascend/.provenance" ] \
        && sed 's/^/    /' "$DEPS_DIR/src/vllm-ascend/.provenance"

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
    # The commit is normally the one .gitmodules pins, read from the checkout
    # rather than hardcoded here, so a vllm-ascend bump moves it automatically -
    # but $CATLASS_COMMIT overrides it when set, because the pinned commit does
    # not compile under CANN 9.2.0's Bisheng. See the note on CATLASS_COMMIT at
    # the top of this file for exactly what fails and why.
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
        if [ -n "$CATLASS_COMMIT" ] && [ "$CATLASS_COMMIT" != "$cat_commit" ]; then
            echo "  catlass: OVERRIDING the .gitmodules pin ${cat_commit:0:12}"
            echo "           with ${CATLASS_COMMIT:0:12} - the .gitmodules commit does not"
            echo "           compile under CANN ${CANN_APT_VERSION}'s Bisheng (simd_vf must be"
            echo "           static). See the CATLASS_COMMIT note in this script."
            cat_commit="$CATLASS_COMMIT"
        fi
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

        # THE BACKPORT. See the CATLASS_PATCH note at the top of this file for
        # what fails without it and why the pin is not simply moved instead.
        local patched=none
        if [ -n "$CATLASS_PATCH" ]; then
            [ -f "$CATLASS_PATCH" ] \
                || die "CATLASS_PATCH=$CATLASS_PATCH does not exist"
            # -p1 because the patch was generated inside a catlass checkout, so
            # its paths start at include/. --dry-run first: a patch that does
            # not apply means the catlass commit moved under it, and silently
            # building unpatched sources is exactly the failure this is here to
            # prevent.
            if ! patch -p1 --dry-run -d "$cat_dir" -i "$CATLASS_PATCH" >/dev/null 2>&1; then
                die "$(basename "$CATLASS_PATCH") does not apply to catlass ${cat_commit:0:12}.
       That patch is a backport of upstream c89fe73d onto the commit
       vllm-ascend pins. If the pin moved, re-cut it against the new tree
       (or set CATLASS_PATCH= if the new tree already has the fix)."
            fi
            patch -p1 -d "$cat_dir" -i "$CATLASS_PATCH" >/dev/null
            patched=$(basename "$CATLASS_PATCH")
            echo "  catlass: applied $patched"
        fi

        # Provenance, for the same reason vllm-ascend has one: a moved submodule
        # pin - or a patch applied on top of it - is invisible in the tree it
        # lands in.
        printf 'url=%s\ncommit=%s\ngitmodules_commit=%s\npatch=%s\nstaged=%s\n' \
            "$cat_url" "$cat_commit" \
            "$(git config -f "$DEPS_DIR/src/vllm-ascend/.gitmodules" \
               --get submodule.csrc/third_party/catlass.commit 2>/dev/null)" \
            "$patched" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$cat_dir/.provenance"
        echo "  catlass: staged $(find "$cat_dir" -type f | wc -l) files"
        sed 's/^/    /' "$cat_dir/.provenance"

        # The assertion that the backport actually took. `patch` is happy to
        # report success on a reversed or fuzzy application, and the symptom of
        # a miss is a twenty-minute build that dies in the kernel compile.
        if [ -n "$CATLASS_PATCH" ]; then
            local nonstatic
            nonstatic=$(grep -rlE '^[[:space:]]+__simd_vf__ (inline|void)' \
                        "$cat_dir/include" 2>/dev/null | wc -l)
            [ "$nonstatic" -eq 0 ] \
                || die "catlass still has non-static __simd_vf__ members in $nonstatic file(s);
       the backport did not take. CANN 9.2.0's Bisheng rejects those."
            echo "  catlass: no non-static __simd_vf__ members remain"
        fi
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
# layer is fetched with common/scripts/fetch.sh's parallel range request
# (~70 s at ~20 MB/s against ~2 MB/s single-stream), then only the missing .so
# files are extracted. The 310P target obtains libhccl.so the same way on
# CANN 8.5.0.
VENDOR_IMAGE="${VENDOR_IMAGE:-ascend/cann}"
# Derived from CANN_VERSION rather than hardcoded, so `CANN_VERSION=9.1.0` and
# `CANN_VERSION=9.2.0` each reach for their own vendor image instead of
# silently lifting 9.1.0 libraries into a 9.2.0 toolkit. THAT MIX IS THE BUG
# THIS TARGET IS BEING MIGRATED AWAY FROM: cann_extra libraries land in the
# same lib64 as the toolkit's own and are resolved by the same loader, so a
# version skew between them is exactly the "undefined symbol" class of failure
# the acceptance criteria call out.
VENDOR_TAG="${VENDOR_TAG:-${CANN_VERSION}-950-ubuntu22.04-py3.10}"

# The .so set lifted from the vendor image. Kept in one place because both the
# registry path and the local-tarball path extract the same list.
CANN_EXTRA_GLOBS=(
    '*x86_64-linux/lib64/libopapi*'
    '*x86_64-linux/lib64/libhccl*'
    '*x86_64-linux/lib64/libes_*'
    '*x86_64-linux/lib64/libdvpp_*'
    '*x86_64-linux/lib64/libacl_dvpp*'
    '*x86_64-linux/lib64/libops_host_cpu.so'
    '*x86_64-linux/lib64/libop_common.so'
    '*x86_64-linux/lib64/libconstant_folding_ops.so'
    '*x86_64-linux/lib64/libllm_datadist.so'
    '*x86_64-linux/lib64/libcann_hixl.so'
)

# Air-gapped / pre-release route. A site that has a vendor CANN image but no
# registry reachable from the provisioning host can hand over either:
#
#   vendor/cann-<ver>/cann_extra/lib64/*.so   the libraries themselves, or
#   CANN_VENDOR_TAR=<path>                    `docker save`d image, or a raw
#                                             layer tar/tar.gz
#
# and this stage uses them instead of talking to quay.io.
CANN_VENDOR_TAR="${CANN_VENDOR_TAR:-}"

extract_cann_extra() {   # <tar-or-tar.gz> <dest-lib64>
    local src="$1" dest="$2" x
    x="$(dirname "$src")/_x"
    rm -rf "$x" && mkdir -p "$x"
    # A `docker save` archive is a tar of layer tars; a blob is one layer.
    # Try the archive as a layer first, then peel it as an image if that
    # yielded nothing.
    tar -xf "$src" -C "$x" --wildcards "${CANN_EXTRA_GLOBS[@]}" 2>/dev/null || true
    if [ -z "$(find "$x" -name '*.so' -print -quit)" ]; then
        rm -rf "$x" && mkdir -p "$x/img"
        tar -xf "$src" -C "$x/img" 2>/dev/null || true
        # EVERY regular file is tried as a layer, not just *.tar. A modern
        # `docker save` writes the OCI layout, where layers are
        # blobs/sha256/<hex> with no extension at all; older ones write
        # <hash>/layer.tar. tar simply fails on the manifest and index JSON,
        # which is why the loop ignores errors instead of filtering by name.
        # Biggest first: the CANN layer is by far the largest, so the wanted
        # libraries usually appear on the first or second try.
        local layer
        while IFS= read -r layer; do
            tar -xf "$layer" -C "$x" --wildcards "${CANN_EXTRA_GLOBS[@]}" 2>/dev/null || true
        done < <(find "$x/img" -type f -size +1M -printf '%s\t%p\n' | sort -rn | cut -f2)
    fi
    find "$x" -path '*x86_64-linux/lib64/*.so' -exec cp -a {} "$dest"/ \;
    rm -rf "$x"
}

do_cann_extra() {
    step "cann_extra (optional operator-runtime override)"
    local dest="$DEPS_DIR/cann_extra/lib64"
    mkdir -p "$dest"

    # 0. Already staged by hand or by a previous run.
    if [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        echo "  staged: $(ls "$dest" | wc -l) override libraries, $(du -sh "$DEPS_DIR/cann_extra" | cut -f1)"
        return 0
    fi

    # 1. Libraries dropped in by hand.
    if ls "$CANN_LOCAL_DIR"/cann_extra/lib64/*.so >/dev/null 2>&1; then
        echo "  adopting cann_extra from $CANN_LOCAL_DIR/cann_extra/lib64"
        cp -a "$CANN_LOCAL_DIR"/cann_extra/lib64/*.so "$dest"/
        echo "  staged $(ls "$dest" | wc -l) libraries"
        return 0
    fi

    # 2. A vendor image handed over as a tarball.
    if [ -n "$CANN_VENDOR_TAR" ]; then
        [ -f "$CANN_VENDOR_TAR" ] || die "CANN_VENDOR_TAR=$CANN_VENDOR_TAR does not exist"
        echo "  extracting cann_extra from $CANN_VENDOR_TAR"
        extract_cann_extra "$CANN_VENDOR_TAR" "$dest"
        echo "  staged $(ls "$dest" | wc -l) libraries"
        return 0
    fi

    # 3. The registry route, now OPT-IN rather than the default.
    if [ "${CANN_EXTRA_FROM_REGISTRY:-0}" = "1" ]; then
        do_cann_extra_registry "$dest"
        echo "  staged $(ls "$dest" | wc -l) libraries"
        return 0
    fi

    # 4. Nothing staged, and that is now the expected outcome.
    cat <<EOF
  skipped - and an empty cann_extra/ is the NORMAL result since the move to apt.

  This directory exists because the standalone toolkit .run was an incomplete
  slice of a CANN install: no published .run carried libopapi.so,
  libopapi_math.so or libhccl.so, so they were lifted out of a vendor
  container's layer blob - a different release's container, which is precisely
  how an image acquires undefined-symbol failures at import time.

  ascend-cann-950-ops=${CANN_APT_VERSION} is the operator package whose absence
  caused all of that, and it is now staged in cann_debs/ from the same
  repository and the same release as the toolkit. The Dockerfile asserts on the
  OUTCOME - libopapi.so and libopapi_math.so present in the toolkit's lib64
  after the ops install - so if the ops package does turn out to be incomplete
  for some release, the build says so with the names of the missing libraries
  rather than silently producing an image that fails later.

  To override anyway, use any of:
    cp *.so $CANN_LOCAL_DIR/cann_extra/lib64/    then re-run this stage
    CANN_VENDOR_TAR=<docker-save.tar> $0 cann_extra
    CANN_EXTRA_FROM_REGISTRY=1 $0 cann_extra     (needs a vendor image for
                                                  ${CANN_VERSION} to exist; the
                                                  950 tags stop at 9.1.0)
EOF
}

do_cann_extra_registry() {
    local dest="$1"
    local tok acc blob size scratch=/var/tmp/cann-extra-stage
    tok=$(curl -sS --max-time 60 \
          "https://quay.io/v2/auth?service=quay.io&scope=repository:${VENDOR_IMAGE}:pull" \
          | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))')
    [ -n "$tok" ] || die "could not obtain a quay.io pull token"
    acc='application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json'

    # Does the tag exist at all? Unlike the OBS bucket, a registry answers
    # honestly: 200 for a published tag, 404 MANIFEST_UNKNOWN for one that was
    # never pushed. Check before the layer fetch so an unpublished CANN line
    # says so instead of dying in `max(d['layers'])` on an error document.
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 \
           -H "Authorization: Bearer $tok" -H "Accept: $acc" \
           "https://quay.io/v2/${VENDOR_IMAGE}/manifests/${VENDOR_TAG}")
    if [ "$code" != "200" ]; then
        cat >&2 <<EOF
  ERROR: no vendor image ${VENDOR_IMAGE}:${VENDOR_TAG} (HTTP $code).

  quay.io/ascend/cann carried 517 tags when this was written and the newest
  CANN line among them was 9.1.0; Docker Hub ascendai/cann stops there too.
  If CANN_VERSION=${CANN_VERSION} has no published image yet, the twenty-six
  libraries the standalone toolkit omits have to come from your own vendor
  drop. Either:

    # the libraries themselves
    mkdir -p $CANN_LOCAL_DIR/cann_extra/lib64
    cp libopapi*.so libhccl*.so ... $CANN_LOCAL_DIR/cann_extra/lib64/

    # or the vendor image, saved on a host that can reach it
    docker save <vendor-image> -o cann-${CANN_VERSION}-vendor.tar
    CANN_VENDOR_TAR=\$PWD/cann-${CANN_VERSION}-vendor.tar $0 cann_extra

  DO NOT fall back to the 9.1.0 image for a ${CANN_VERSION} toolkit. These
  libraries are installed into the toolkit's own lib64 and resolved by the same
  loader, so mixing releases is precisely how you get the undefined-symbol
  failures this migration exists to remove. Override VENDOR_TAG only if you
  know the two releases are ABI-identical.
EOF
        exit 1
    fi

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
    fetch_parallel "https://quay.io/v2/${VENDOR_IMAGE}/blobs/${blob}" \
        "$scratch/layer.tar.gz" "$size" "$tok"

    echo "  extracting the libraries missing from the toolkit"
    extract_cann_extra "$scratch/layer.tar.gz" "$dest"
    rm -rf "$scratch"
}


do_thirdparty() {
    step "vllm-ascend ACLNN third-party archives"
    local tp="$DEPS_DIR/third_party"
    mkdir -p "$tp/pkg" "$tp/json"
    # Each of these is checked under ${CANN_3RD_LIB_PATH} by the corresponding
    # cmake/third_party/*.cmake before it reaches for gitcode.com. makeself is
    # absent on purpose: CANN ships one and the Dockerfile copies it in.
    local base=https://gitcode.com/cann-src-third-party
    fetch_once "$base/abseil-cpp/releases/download/20230802.1/abseil-cpp-20230802.1.tar.gz" \
               "$tp/pkg/abseil-cpp-20230802.1.tar.gz"
    fetch_once "$base/protobuf/releases/download/v25.1/protobuf-25.1.tar.gz" \
               "$tp/pkg/protobuf-25.1.tar.gz"
    fetch_once "$base/json/releases/download/v3.11.3/include.zip" \
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
    drun -e EMULATED=0 \
         -v "$COMMON_DIR/scripts:/common:ro" \
         -v "$TARGET_DIR/packages/sys_packages.txt:/prov/packages.txt:ro" \
         -v "$DEPS_DIR/apt_debs:/out" \
         "$BASE_IMAGE" bash /common/fetch_debs.sh
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
    # PLAT_NAME is the wheel tag, not a cross-compile switch: the container is
    # amd64 and jammy's glibc is 2.35, which clears manylinux_2_28.
    drun -e PIP_INDEX_URL="$PIP_INDEX_URL" \
         -e EMULATED=0 \
         -e PLAT_NAME=manylinux_2_28_x86_64 \
         -e CONSTRAINTS=/prov/constraints.txt \
         -v "$COMMON_DIR/scripts:/common:ro" \
         -v "$TARGET_DIR/constraints.x86_64.txt:/prov/constraints.txt:ro" \
         -v "$DEPS_DIR/src/vllm:/src/vllm" \
         -v "$DEPS_DIR/apt_debs:/debs:ro" \
         -v "$DEPS_DIR/python_wheels:/out" \
         "$BASE_IMAGE" bash /common/build_vllm_wheel.sh
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
    # EXTRA_INDEXES is the Ascend mirror and nothing else. triton-ascend 3.2.2
    # exists only there (PyPI stops at 3.2.0) and that index is served at the
    # ROOT of the path - appending /simple/ returns 404. download.pytorch.org is
    # deliberately absent: the +cpu wheels are pre-seeded by do_torch, and its
    # per-project pages are megabytes of HTML re-fetched on every resolve.
    #
    # Pass 3 is derived from the entries pass 2 strips out of OWN_REQ, so
    # triton-ascend keeps a single pin in requirements/python_wheels.txt.
    drun -e PIP_INDEX_URL="$PIP_INDEX_URL" \
         -e EMULATED=0 \
         -e ENFORCE_CPU_TORCH=1 \
         -e CONSTRAINTS=/prov/constraints.txt \
         -e OWN_REQ=/prov/requirements.txt \
         -e PLUGIN_REQ=/src/vllm-ascend/requirements.txt \
         -e EXTRA_INDEXES=https://mirrors.huaweicloud.com/ascend/repos/pypi \
         -v "$COMMON_DIR/scripts:/common:ro" \
         -v "$TARGET_DIR/constraints.x86_64.txt:/prov/constraints.txt:ro" \
         -v "$TARGET_DIR/requirements/python_wheels.txt:/prov/requirements.txt:ro" \
         -v "$DEPS_DIR/src/vllm-ascend:/src/vllm-ascend:ro" \
         -v "$DEPS_DIR/apt_debs:/debs:ro" \
         -v "$DEPS_DIR/python_wheels:/wheels" \
         "$BASE_IMAGE" bash /common/fetch_wheels.sh
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

    # ONE CANN RELEASE IN THE PAYLOAD, NOT TWO. The toolkit, NNAL and the
    # cann_extra libraries all end up in the same lib64 and are resolved by one
    # loader; a payload carrying 9.1.0 installers next to a 9.2.0 request (or
    # the reverse) builds an image whose libraries disagree about their own
    # ABI, which surfaces as `undefined symbol` at import time rather than as
    # anything a build log would call an error.
    local stray
    stray=$(find "$CANN_DEBS_DIR" -maxdepth 1 -name '*.deb' \
            ! -name "*_${CANN_APT_VERSION}_*" -printf '%f\n' 2>/dev/null | sort)
    if [ -n "$stray" ]; then
        echo "  packages from another CANN release are staged alongside ${CANN_APT_VERSION}:" >&2
        echo "$stray" | sed 's/^/    /' >&2
        die "remove them, or re-run with CANN_APT_VERSION set to the release you mean to build"
    fi
    echo "  cann: ${CANN_APT_VERSION} only (no mixed-release packages in the payload)"

    # torch_npu is the one pin this repo cannot derive when CANN moves.
    # TORCH_NPU_CANN records which CANN release the wheelhouse's torch_npu pin
    # was read against - upstream vllm-ascend's Dockerfile.a5 pairs
    # torch-npu==2.10.0.post4 with CANN 9.1.0, and torch_npu's own published
    # compatibility matrix has no CANN 9.x row at all to appeal to instead.
    # Building a different CANN release against that pin may well be right, but
    # it is unverified, and the failure it produces is `undefined symbol` at
    # `import torch_npu` rather than anything this script can detect. So it
    # WARNS rather than failing: the payload is usable, the pairing is not
    # attested. See targets/target-950pr/requirements/python_wheels.txt.
    TORCH_NPU_CANN="${TORCH_NPU_CANN:-9.1.0}"
    if [ "$CANN_VERSION" != "$TORCH_NPU_CANN" ]; then
        warn "the staged torch_npu pin was read against CANN ${TORCH_NPU_CANN}, not ${CANN_VERSION}."
        warn "  Upstream pairs torch-npu==2.10.0.post4 with CANN ${TORCH_NPU_CANN} (Dockerfile.a5),"
        warn "  and torch_npu's own matrix has no CANN 9.x row. Confirm the pairing"
        warn "  from your ${CANN_VERSION} drop's release notes before trusting the image;"
        warn "  a mismatch surfaces as 'undefined symbol' at import torch_npu."
    else
        echo "  torch_npu: pinned against CANN ${TORCH_NPU_CANN}, which is what is being built"
    fi
    echo "  total: $(du -sh "$DEPS_DIR" | cut -f1)"
    echo
    echo "  Now run:  ./targets/target-950pr/build.sh"
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
