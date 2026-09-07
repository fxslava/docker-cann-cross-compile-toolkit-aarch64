# Ascend 950PR on x86_64: build flags, staging plan and runtime

A `linux/amd64` offline inference image for Ascend 950-class silicon (Atlas
350, DaVinci v3, device family **A5**), built natively on an x86_64 host.

**Status: the CANN 9.1.0 image is built and verified; the CANN 9.2.0 default is
staged for but not yet built.**

* **9.1.0** — `deps/950pr-x86_64/` was staged in full (3.8 GB) and the image was
  built natively on x86_64 with `--network=none`, then verified inside the
  container: **10/10 checks pass on a build host** (13/13 under the extended
  suite described in §8), with the hardware-only checks reported as `[INFO]`
  rather than counted. See §7 for the measured numbers and §5 for the operator
  set. Reproduce it with `CANN_VERSION=9.1.0 ./targets/target-950pr/build.sh`.
* **9.2.0** — now the default, because that is what the 950PR host runs. The
  pipeline is fully wired for it, but **no CANN 9.2.0 has been published**
  anywhere reachable (§1), so the toolkit and NNAL installers have to come from
  a vendor drop before the build can run. Everything downstream of that is in
  place and tested; §8.7 has the exact remaining steps.

Building it exposed six things that the scaffold had assumed away, all of them
now fixed in this repo rather than worked around locally — the most consequential
being that **the publicly downloadable CANN 9.1.0 toolkit is not a complete CANN
install** (§6).

This is the sibling of the 310P image in [README.aarch64.md](../README.aarch64.md).
The two differ in more than the SoC:

| | 310P3 (`targets/target-310p`) | 950PR (`targets/target-950pr`) |
|---|---|---|
| Image architecture | `linux/arm64`, QEMU-emulated at build time | `linux/amd64`, **native** |
| Base OS / Python | Ubuntu 22.04 / 3.10 | Ubuntu 22.04 / 3.10 |
| CANN | 8.5.0 | `$CANN_VERSION`, default 9.2.0 (+ NNAL/ATB) |
| Unpacker stage | needed, to dodge the emulation tax | **none** — installer runs natively |
| `ldconfig` stub | needed, `qemu-user` segfaults | **none** |
| Local patches | 1, for bf16/`PIPE_FIX` kernel gating | **none**, by design |
| Serving dtype | forced `float16` | checkpoint's own (bf16 capable) |

---

## 1. Which CANN release, and how that is established

[docs/soc-build-matrix.md §2](soc-build-matrix.md) already showed that CANN
8.5.0 cannot build for this SoC at all: zero files in the toolkit mention
`ascend950`, and `platform_ascendc.h`'s `SocVersion` enum stops short of it. A
newer toolkit was therefore a precondition, not a preference.

Probing the Huawei OBS bucket with the range-request method documented in
`download_deps.sh` (206 = the key exists, 403 = the version string does not),
on 2026-09-05:

| CANN version | x86_64 | aarch64 |
|---|---|---|
| 8.5.0 | 206 | 206 |
| 8.5.1 | 206 | 206 |
| 8.6.0 / 8.6.RC1 | 403 | 403 |
| 9.0.0 | 206 | 206 |
| 9.0.RC1 | 403 | 403 |
| **9.1.0** | **206** | **206** |
| 9.1.RC1 / 9.2.0 / 9.5.0 | 403 | 403 |

Corroborated from two other directions:

* `quay.io/ascend/cann` publishes `9.1.0-950-ubuntu22.04-py3.{10,11,12}` and
  `9.0.1-950-*` tags — Huawei ships 950 images for this line.
* `vllm-project/vllm-ascend@main` carries **`Dockerfile.a5`**, whose base image
  is `quay.io/ascend/cann:9.1.0-950-ubuntu22.04-py3.12`.

`Ascend-cann-nnal_9.1.0_linux-x86_64.run` also exists (572,750,476 bytes) and is
required: upstream sources `nnal/atb/set_env.sh` before building vllm-ascend.
`Ascend-cann-kernels-950_9.1.0_*` and `-nnrt_` return 403 — those keys do not
exist under those names, so do not plan around them.

### 1a. CANN 9.2.0 **is** published — on the DevCloud apt repository

**This section previously concluded the opposite, and it was looking in the
wrong place.** The earlier probes were of the OBS bucket and the container
registries, and those findings still hold: re-probed 2026-09-07, the OBS bucket
answers 403 for every 9.2.0 spelling tried (`9.2`, `9.2.0`, `9.2.RC1`,
`9.2.0.RC1`, `9.2.0.alpha001`, `9.2.0.alpha002`, `9.2.T1`) while 9.0.0 and 9.1.0
answer 206; `quay.io/ascend/cann` tops out at the 9.1.0 line across all 517
tags, Docker Hub `ascendai/cann` agrees, and `vllm-ascend` still pins
`CANN_VERSION="9.1.0"` in `Dockerfile.a5` on both `main` and
`releases/v0.27.1rc`.

What none of those probes covered is Huawei's **Debian package repository**,
which is a separate distribution channel and does carry the 9.2.0 line:

```
https://ascend.devcloud.huaweicloud.com/cann/debian
```

Probed 2026-09-07:

| Property | Value |
|---|---|
| Suites | `cann`, `hdk` — both component `main` |
| Architectures | `all`, `amd64`, `arm64` |
| Signing | GPG. `cann-keyring_1.0.0_all.deb` installs the key at `/usr/share/keyrings/cann-archive-keyring.gpg` and writes `/etc/apt/sources.list.d/ascend-cann.list` |
| Releases carried | 8.5.0, 9.0.0, 9.0.0-beta.2, 9.0.1, 9.1.0, 9.1.0-beta.1, 9.1.0-beta.3, 9.1.1, 9.2.0-beta.1, **9.2.0-beta.2** |
| Packages | `ascend-cann-{toolkit,nnal,950-ops,910-ops,910b-ops,310p-ops,310b-ops,A3-ops}` |

Two details matter and neither is obvious:

* **`main` indexes every release.** The per-version components (`9.2.0-beta.2/`
  and friends) exist, but the keyring enables only `cann main`, and that one
  component's `Packages` lists all ten releases. So `apt-cache policy
  ascend-cann-toolkit` shows ten candidate versions and the `=<version>` pin is
  what selects one. An unpinned install silently follows the newest beta.
* **`ascend-cann-950-ops` exists here and existed nowhere else.** This is the
  Ascend950 operator payload — 2.8 GB — whose absence from the OBS bucket
  (`Ascend-cann-kernels-950` → 403) is the entire reason this repo used to lift
  26 libraries out of a vendor container's layer blob. See §1b.

So `provision.sh cann` now installs the keyring into a staging container and
downloads with apt itself, which means the repository's **signature** is what
authenticates the payload rather than the fact that it arrived over TLS. The
`vendor/cann-<version>/cann_debs/` drop survives for a site that cannot reach
the repository at all from its staging host.

### 1b. The packages are `.run` wrappers, and `dpkg -i` does not work

Each `.deb` is thin: its `data.tar` holds exactly **one** file, the vendor's own
`Ascend-cann-*_<version>_linux-x86_64.run`, and its `postinst` runs

```
${RUN} --install --install-path="/usr/local/Ascend" --force --nox11 --install-for-all
```

then deletes it. That cannot be used in a container build, for two independent
reasons — both measured, not inferred:

1. **No `--quiet`, so it stops on the EULA.** The installer prints the licence
   and waits for input. In `docker build` there is none, so it exits 1 and dpkg
   reports `post-installation script subprocess returned error exit status 1`
   with `/usr/local/Ascend` left **empty**. The vendor's own documented flag for
   scripted installs is `--quiet`, whose help text says using it constitutes
   acceptance of the EULA.
2. **`--install` is *run* mode.** From the installer's `--help`:
   `--install | --devel | --full   Install run | devel | full mode`. Only
   `--full` installs `pyACL_<version>_linux-x86_64.run` and the development
   payload. An image built from run mode fails at `import acl` on the inference
   path (`vllm_ascend/device_allocator/camem.py:27` imports it at module scope),
   which is a runtime failure, not a build failure.

Dockerfile stage 3 therefore takes the `.run` back out of the `.deb` with
`dpkg-deb --fsys-tarfile` and drives it directly. The scene differs per package
and the three installers do **not** share an option grammar:

| Package | Scene | Notes |
|---|---|---|
| `ascend-cann-toolkit` | `--full` | `--install \| --devel \| --full` |
| `ascend-cann-950-ops` | `--install` | `--install \| --devel` only. **There is no `--full`** — passing one makes the installer print its usage and exit **0**, which is success-shaped and installs nothing |
| `ascend-cann-nnal` | `--install` | scenes are install/upgrade/uninstall; no scene at all is rejected outright |

The payload is unchanged by this: the bytes are the vendor's, GPG-verified by
apt at staging time and SHA-256 pinned in `deps.manifest` against the hashes the
repository's own signed `Packages` index publishes. Only the *scene* is chosen
by the Dockerfile rather than by a `postinst` that cannot run unattended.
`/usr/local/Ascend/.cann-provenance` records the repository, the exact apt
version and each package's hash, since `dpkg -l` knows nothing about them.

### 1c. The 9.2.0 install produces the **vendor** layout

Measured on 9.2.0-beta.2, the toolkit installer lays down:

```
/usr/local/Ascend/cann-9.2.0-beta.2            the real tree
/usr/local/Ascend/cann                      -> cann-9.2.0-beta.2
/usr/local/Ascend/ascend-toolkit/latest     -> /usr/local/Ascend/cann
/usr/local/Ascend/ascend-toolkit/set_env.sh -> …/latest/set_env.sh
```

Three consequences:

* The real directory is named with the **package** version, betas included —
  `cann-9.2.0-beta.2`, not `cann-9.2.0`. Nothing should hardcode either.
* The old stage-3c loop, which did `ln -sfn ascend-toolkit/latest` at `cann`,
  would have produced `cann -> ascend-toolkit/latest -> cann`: an **ELOOP** that
  every path through the image then fails on. It now resolves the target with
  `readlink -f` first and links every name to the real directory.
* A plain `find` over `ascend-toolkit/` no longer finds
  `ascend_toolkit_install.info`, because that directory holds only symlinks — so
  the version assertion uses `find -L`. Without it the assertion silently
  degrades to a warning.

**Before assuming 9.2.0 is what you need**, read the host rather than the
deployment note — the driver (Ascend HDK, e.g. `25.0.rc1`) and the CANN toolkit
are separately versioned, and "the host runs 9.2.0" is often a report of one
when the other is meant:

```bash
cat /usr/local/Ascend/ascend-toolkit/latest/x86_64-linux/ascend_toolkit_install.info
cat /usr/local/Ascend/driver/version.info
npu-smi info -t board -i 0
```

---

### 1d. catlass does not compile on 9.2.0, and the pin cannot just be moved

The ascend950 ACLNN op build pulls in `catlass`, vllm-ascend's third-party
submodule. CANN 9.2.0's Bisheng requires `__attribute__((cce_simd_vf))`
functions to be free or **static**; catlass at the pinned commit declares
fourteen as non-static members, so `ChunkFwdO`, `ChunkGatedDeltaRuleFwdH` and
`ChunkKdaFwd` fail to build:

```
block_epilogue_fa_softmax_ascend950.hpp:329:5: error: simd_vf function
    'ComputeExpSubSum' must be a free function or static member function
ld.lld: error: cannot open .../kernel_meta/ChunkFwdO_..._mix_aic_0.o
```

The second line is the one that shows up first in a scan of the log, and it is a
red herring: the object is missing because the compile failed, not because of
anything about linking.

Upstream fixed it in `c89fe73d`, but deleted `include/catlass/debug.hpp` before
that commit — and vllm-ascend at this ref includes that header. Measured on all
three candidates:

| catlass commit | `simd_vf` static | `debug.hpp` | builds on 9.2.0? |
|---|---|---|---|
| `41bf90da` (`.gitmodules`) | ✗ | ✓ | no — `simd_vf` errors |
| `c89fe73d` (the fix) | ✓ | ✗ | no — `debug.hpp` not found |
| `337cc892` (master) | ✓ | ✗ | no — `debug.hpp` not found |

`41bf90da` is an ancestor of master, so the history is linear and the deletion
genuinely precedes the fix. A cherry-pick of `c89fe73d` onto the pin conflicts in
every file it touches — an intervening `pre-commit` reformat, plus a dozen files
absent at the pin.

So the change is backported:
`targets/target-950pr/patches/0001-catlass-simd-vf-static.patch`, 11 lines over 4
headers, applied by `provision.sh` at staging time. In-class declarations only —
C++ forbids `static` on the three out-of-class definitions in
`block_epilogue_per_group_per_block.hpp`, and upstream's post-fix file agrees.

`provision.sh` dry-runs the patch and refuses to stage a payload it cannot apply
to; both it and `build.sh` then assert that **no** non-static `__simd_vf__`
members remain, because the alternative is discovering it forty minutes into a
kernel compile.

---

## 2. The release matrix

Read out of `vllm-ascend @ releases/v0.27.1rc` (`requirements.txt`,
`pyproject.toml`) and its `Dockerfile.a5`. It moves as a set:

| Component | Pin | Source |
|---|---|---|
| CANN | `$CANN_VERSION` 9.2.0 / `$CANN_APT_VERSION` 9.2.0-beta.2 | DevCloud apt repository, or `vendor/cann-<v>/cann_debs/` (§1a) |
| CANN Ascend950 ops | same release | same source — `ascend-cann-950-ops` (§1a) |
| CANN NNAL (ATB) | same release | same source |
| Python | 3.10 | jammy system interpreter |
| vLLM | v0.27.1 | **built from source**, `VLLM_TARGET_DEVICE=empty` |
| vllm-ascend | `releases/v0.27.1rc` @ `e61a5d7` | the branch upstream cuts against vLLM v0.27.1; pinned by commit, not by branch head (§8.5) |
| torch | 2.10.0**+cpu** | download.pytorch.org/whl/cpu |
| torch_npu | 2.10.0.post4 | PyPI |
| torchvision / torchaudio | 0.25.0+cpu / 2.10.0+cpu | download.pytorch.org/whl/cpu |
| triton-ascend | 3.2.2 | **Ascend mirror only**; needs clang-15 |

Three traps:

* **PyPI's x86_64 `vllm` wheel is a CUDA build.** As on aarch64: pip resolves it
  cleanly and produces an image that imports and dispatches to nothing. The
  wheel must be built from the v0.27.1 source with `VLLM_TARGET_DEVICE=empty`.

  Building it that way does more than skip the CUDA kernels. `setup.py`'s
  `get_requirements()` reads `requirements/common.txt` for the empty target
  (`_no_device()`), and `common.txt` names **no** `torch`, `nvidia` or `cuda`
  requirement at all — whereas the published sdist's `PKG-INFO`, generated for
  the CUDA target, declares `torch==2.13.0`, `torchvision==0.28.0` and
  `torchaudio==2.11.0`. Installing the PyPI artefact would therefore not merely
  add CUDA: it would drag the torch stack **three minor versions past** the
  2.10.0 that `torch_npu` 2.10.0.post4 is compiled against. The empty-target
  wheel stays silent about torch and lets vllm-ascend's pins govern, which is
  what makes the three-transaction install order work. The wheel it produces is
  versioned `0.27.1+empty` — `setup.py` appends that local segment itself.
* **PyPI's x86_64 `torch` 2.10.0 is a CUDA build too**, and this one bites
  harder because nothing about it looks wrong. Its metadata carries **fifteen**
  `nvidia-*-cu12` requirements gated on
  `platform_system == "Linux" and platform_machine == "x86_64"` — exactly this
  target — so an unconstrained resolve stages several GB of CUDA runtime that
  an Ascend NPU cannot use, and whose `torch` shadows the CPU build `torch_npu`
  is compiled against. `targets/target-950pr/constraints.x86_64.txt` pins
  `torch==2.10.0+cpu` (plus `torchvision`/`torchaudio` `+cpu`), which declare no
  `nvidia` requirements at all. This is the same mechanism, against the
  opposite architecture, as `targets/target-310p/constraints.aarch64.txt`.
  Three places enforce it, so a slip cannot reach the image quietly:
  `fetch_wheels.sh` fails the resolve, `targets/target-950pr/build.sh` fails preflight,
  and the Dockerfile asserts no `nvidia-*` distribution is installed and that
  `torch.__version__` ends in `+cpu`.
* **triton-ascend 3.2.2 is Ascend-mirror only.** PyPI stops at 3.2.0. 3.2.2
  lives on `mirrors.huaweicloud.com/ascend/repos/pypi`, whose PEP 503 index is
  served at the **root** of that path — appending `/simple/` returns 404. If the
  mirror is unreachable, `fetch_wheels.sh` records the miss in
  `python_wheels/.optional-missing` rather than failing the whole resolve.

An earlier revision of this document claimed `torch_npu` 2.10.0.post4 was
Ascend-mirror-only because PyPI stopped at 2.9.1. That is no longer true and the
table above is corrected: PyPI now carries 2.10.0, `.post2`, `.post4` and
`.post6` as cp310–cp313 `manylinux_2_28` wheels for x86_64 and aarch64.

---

## 3. Build flags and environment

```bash
./targets/target-950pr/build.sh
./targets/target-950pr/build.sh --save artifacts/vllm-ascend-950pr-x86_64-offline.tar.gz
```

which wraps:

```bash
docker buildx build \
    --platform linux/amd64 \
    --network=none \
    --build-arg SOC_VERSION=ascend950dt_9582 \
    -f targets/target-950pr/Dockerfile.x86_64 \
    -t vllm-ascend-950pr:x86_64-offline \
    --load \
    .
```

### Build ARGs

| ARG | Default | Notes |
|---|---|---|
| `BASE_IMAGE` | `ubuntu:22.04` | jammy, the base upstream builds on — see §6 |
| `CANN_VERSION` | `9.2.0` | selects both `.run` filenames, the `cann_extra` vendor tag, the `cann-<v>` symlink and the in-image `ENV`; asserted against the installed toolkit (§8.1) |
| `SOC_VERSION` | `ascend950dt_9582` | **lowercase, see below** |
| `ASCEND_AICORE_ARCH` | `dav-c310` | **corrected — was `dav-v300`, which exists in no CANN file; see §8.8** |
| `COMPILE_CUSTOM_KERNELS` | `1` | |
| `VLLM_ASCEND_VERSION` | `0.27.1` | `setuptools-scm` pretend-version; must match the provisioned ref (§8.5) |

### `SOC_VERSION` is lowercase, and it is not `Ascend950PR`

vllm-ascend gates every 950 code path on `if(SOC_VERSION MATCHES "ascend950")`
— a **case-sensitive** CMake regex — and `setup.py`'s own error text asks for
`a value starting with ascend950`. The vendor-facing spelling `Ascend950PR`
matches none of those gates: the build would succeed while silently taking the
generic branch, which is a worse outcome than failing.

This is the same trap the 310P hit from the other side (see README.aarch64.md
§"Why `SOC_VERSION` is lowercase `ascend310p3`"). `targets/target-950pr/build.sh`
rejects anything not starting with `ascend950` during preflight.

`ascend950dt_9582` is the value upstream's `Dockerfile.a5` ships. On real
hardware derive yours instead — `setup.py` builds it as
`(Chip Name + "_" + NPU Name).lower()` from:

```bash
npu-smi info -t board -i 0
```

### Runtime environment

| Variable | Default | Purpose |
|---|---|---|
| `MODEL` | — | model id or path (required to serve) |
| `PORT` / `HOST` | 8000 / 0.0.0.0 | listen address |
| `TENSOR_PARALLEL_SIZE` | number of NPUs found | |
| `VLLM_DTYPE` | *unset* | passed through only if set — **no dtype is forced**, unlike the 310P, because DaVinci v3 has bf16 |
| `ASCEND_RT_VISIBLE_DEVICES` | every NPU found | |
| `ALLOW_NO_NPU` | `0` | start without `/dev/davinci*` |
| `NO_JEMALLOC` | `0` | skip the jemalloc `LD_PRELOAD` upstream sets |

Running on a 950 host needs the compute device plus the three control nodes,
same as the 310P:

```bash
docker run -d --name vllm-950pr \
  --device /dev/davinci0 --device /dev/davinci_manager \
  --device /dev/devmm_svm --device /dev/hisi_hdc \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
  -e MODEL=/models/your-model -p 8000:8000 \
  vllm-ascend-950pr:x86_64-offline
```

---

## 4. Dependency staging plan — `deps/950pr-x86_64/`

`targets/target-950pr/deps.manifest` is the machine-readable version of this
section; the build script parses it and refuses to start until every row is
satisfied. Sizes there were measured with HTTP range requests; SHA-256 values
are deliberately unpinned (`-`) because they cannot be known without
downloading, and should be pinned from the first verified fetch.

```
deps/950pr-x86_64/
  Ascend-cann-toolkit_9.1.0_linux-x86_64.run     1,298,337,341 bytes
  Ascend-cann-nnal_9.1.0_linux-x86_64.run          572,750,476 bytes
  apt_debs/                 .deb closure of packages/sys_packages.txt + Packages.gz
  python_wheels/            cp310 manylinux x86_64 wheelhouse (no CUDA, see §2)
  src/vllm-ascend/          upstream checkout, no patches applied
  src/vllm/                 v0.27.1, built to a wheel and left in python_wheels/
```

### The scripted route

`targets/target-950pr/provision.sh` does all of it, and is the sibling of
`targets/target-310p/provision.sh` — minus the QEMU, because host and target are the
same architecture here, so every container runs natively and resolves against
the real target environment instead of an emulated one:

```bash
./targets/target-950pr/provision.sh                 # everything that is missing
./targets/target-950pr/provision.sh cann            # or one stage at a time:
./targets/target-950pr/provision.sh src debs vllm wheels verify
```

Stages are idempotent and resumable — re-running skips what is already
complete, and the CANN fetch picks up mid-file. That last part is deliberate:
`curl --retry` combined with `-C -` restarted the 1.3 GB toolkit from byte 0 on
the first dropped connection *and truncated what was already on disk*, so each
attempt is instead a fresh `curl` resuming from the current file size, with
`--speed-limit`/`--speed-time` to drop a connection that has gone quiet.

The manual equivalent of each stage follows, for when something needs doing by
hand.

**1. CANN installers**

```bash
BASE='https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/CANN/CANN%209.1.0'
wget -c "$BASE/Ascend-cann-toolkit_9.1.0_linux-x86_64.run"
wget -c "$BASE/Ascend-cann-nnal_9.1.0_linux-x86_64.run"
sha256sum Ascend-cann-*_9.1.0_linux-x86_64.run   # pin these into deps.manifest
```

**2. apt archive.** Native this time — no QEMU container needed, just a jammy
one so the `.deb`s match the base image. `clang-15` resolves out of
`jammy-updates` (1:15.0.7-0ubuntu0.22.04.3), which stock `ubuntu:22.04` has
enabled; it is not in the release pocket:

```bash
docker run --rm -v "$PWD/deps/950pr-x86_64/apt_debs:/out" \
  -v "$PWD/targets/target-950pr/packages/sys_packages.txt:/pkgs.txt:ro" \
  ubuntu:22.04 bash -c '
    apt-get update -qq &&
    apt-get install -y --no-install-recommends --download-only \
      $(grep -vE "^[[:space:]]*(#|$)" /pkgs.txt | tr "\n" " ") &&
    cp /var/cache/apt/archives/*.deb /out/ &&
    cd /out && apt-get install -y dpkg-dev >/dev/null &&
    dpkg-scanpackages . > Packages && gzip -kf Packages'
```

**3. wheelhouse.** Resolve as cp310/x86_64 — inside an `ubuntu:22.04`
container, so environment markers (`python_version`, `platform_machine`, glibc)
are evaluated against the real target rather than the host. `--constraint` is
the load-bearing flag, not an optional tidy-up: without it this exact command
stages several GB of `nvidia-*-cu12` wheels (see §2).

```bash
pip download --only-binary=:all: -d deps/950pr-x86_64/python_wheels \
  -r targets/target-950pr/requirements/python_wheels.txt \
  --constraint targets/target-950pr/constraints.x86_64.txt \
  --extra-index-url https://download.pytorch.org/whl/cpu \
  --extra-index-url https://mirrors.huaweicloud.com/ascend/repos/pypi
```

Then confirm the payload is CUDA-free before building — `targets/target-950pr/build.sh`
checks this in preflight and refuses to start otherwise:

```bash
find deps/950pr-x86_64 -type f \( -iname 'nvidia_*' -o -iname '*cudnn*' \) | sort
ls deps/950pr-x86_64/python_wheels/torch-*.whl     # must be torch-2.10.0+cpu-*
```

**4. the vLLM wheel** — built, never downloaded:

```bash
git clone --depth 1 -b v0.27.1 https://github.com/vllm-project/vllm.git
cd vllm && VLLM_TARGET_DEVICE=empty python3 -m pip wheel --no-deps \
  -w ../deps/950pr-x86_64/python_wheels .
```

**5. vllm-ascend source**

```bash
git clone --depth 1 https://github.com/vllm-project/vllm-ascend.git \
  deps/950pr-x86_64/src/vllm-ascend
```

`deps/` is git-ignored in this repository; nothing above is committed.

---

## 5. Operator coverage — corrected by the build

**An earlier revision of this section was wrong, and the build disproved it.**
It claimed the 950 gets no custom kernels at all. That conflated two separate
mechanisms:

| Mechanism | ascend950 | Evidence |
|---|---|---|
| `ascendc_library(vllm_ascend_kernels)` | **skipped** | no `libvllm_ascend_kernels.so` in the image |
| `csrc/build_aclnn.sh` ACLNN ops | **27 ops built** | 493 kernel binaries, 793 files installed |

So the CMake gate quoted below is real, but it only governs the *kernels
library*. The ACLNN custom-op package is built by a different path and is by
far the largest product of this image — roughly **88 m 30 s** of the build,
installed at `vllm_ascend/_cann_ops_custom/vendors/custom_transformer` with
`libcust_opapi.so` alongside it. `verify_runtime.sh` now asserts its presence.

### The 27 ops, exactly as the build asks for them

These are not inferred from reading `build_aclnn.sh`; they are the literal
`--ops=` argument the `ascend950` branch passes to its inner `build.sh`, read
off the process table of a running cold build:

```
build.sh --pkg --soc=ascend950 --ops=moe_gating_top_k_hash;inplace_partial_rotary_mul;
kv_compress_epilog;compressor;compressor_metadata;vllm_quant_lightning_indexer;
vllm_quant_lightning_indexer_metadata;kv_quant_sparse_attn_sharedkv;
kv_quant_sparse_attn_sharedkv_metadata;hc_post;hc_pre;swiglu_group_quant;
situ_mx_quant;indexer_compress_epilog_v2;causal_conv1d;recurrent_gated_delta_rule;
recurrent_kda;chunk_fwd_o;chunk_gated_delta_rule_fwd_h;chunk_kda_fwd;
kda_gate_cumsum;kda_layout_swap12;store_kv_block;store_kv_block_metadata;
k2q_csr;sparse_attention_score;mla_prolog_v3
```

Twenty-seven names, and every one of them is compiled for this target. Two are
worth calling out by their kernel spelling, because both were claimed to be
absent at one point or another:

* **`mla_prolog_v3` → `MlaPrologV3_*`.** MLAPO is **not** excluded on this SoC.
  The `VLLM_ASCEND_CUSTOM_OP_EXCLUDE_ASCEND950` list drops
  `mla_preprocess`/`batch_matmul_transpose` from the *`vllm_ascend_C` extension*
  — a different operator on a different build path. The ACLNN `MlaPrologV3_*`
  kernels are the slowest in the whole run; the last handful of them account for
  roughly half of stage 6's wall time on their own.
* **`chunk_kda_fwd` → `ChunkKdaFwd_*`.** The KDA (Kimi Delta Attention) family
  — `chunk_kda_fwd`, `recurrent_kda`, `kda_gate_cumsum`, `kda_layout_swap12` —
  is compiled here in full, alongside the gated-delta-rule and causal-conv1d
  ops that share its code paths.

Note the `*_metadata` entries (`compressor_metadata`,
`vllm_quant_lightning_indexer_metadata`, `kv_quant_sparse_attn_sharedkv_metadata`,
`store_kv_block_metadata`): they are counted among the 27 and produce their own
kernel binaries, which is part of why 27 ops yield 493 of them.

What remains true is that the **`vllm_ascend_C` extension** takes the same
branch as the 310P, and that is what the gates below describe:

```cmake
if(SOC_VERSION MATCHES "ascend310p.*|ascend950")   # skip the whole kernels lib
    message(STATUS "Hardware ${SOC_VERSION} detected: skip vllm_ascend_kernels compile")

set(VLLM_ASCEND_CUSTOM_OP_EXCLUDE_ASCEND950        # drop MLAPO + batch_matmul_transpose
    .../mla_preprocess/op_kernel/mla_preprocess_kernel.cpp
    .../batch_matmul_transpose/op_kernel/batch_matmul_transpose_kernel.cpp)

if(NOT (SOC_VERSION MATCHES "ascend310p.*|ascend950"))
    target_compile_definitions(vllm_ascend_C PRIVATE -DVLLM_ENABLE_ATB_AND_DIRECT_KERNELS)
```

and `vllm_ascend/utils.py` still says *"in ASCEND950 chip, we temporarily
disable all custom ops"* — a comment that now describes only the
`vllm_ascend_C` op list, not the ACLNN package the same tree builds.

`verify_runtime.sh` asserts the shape upstream actually produces: no 310P stub
symbols leaked in, `vllm_ascend_C` links with no unresolved non-Python symbols,
the device family is `A5`, and the ACLNN custom-op package is installed. It does
**not** claim those operators execute correctly — only a 950 can show that.

---

## 6. What is deviated from, and what is unverified

Three places where this scaffold does not match the brief it was built from,
each for a reason that would otherwise cause a silent failure:

1. **`SOC_VERSION=Ascend950PR` → `ascend950dt_9582`.** Case-sensitive CMake
   gates; §3 above.
2. **"Full operator set" → upstream's subset.** §5 above.
3. ~~**Ubuntu 24.04 / Python 3.12 is unreferenced upstream.**~~ **Resolved:
   this target is now Ubuntu 22.04 / Python 3.10.** The earlier revision built
   on noble and recorded the risk that nothing upstream exercised that
   combination, with the fallback spelled out as "one flag —
   `BASE_IMAGE=ubuntu:22.04`, with `python3.10` in `packages/sys_packages.txt`
   and a cp310 wheelhouse". That fallback is now the default, so the deviation
   is gone rather than merely documented:

   * Huawei publishes 950 CANN images for `ubuntu22.04` only (plus
     `openeuler24.03`), including `9.1.0-950-ubuntu22.04-py3.{10,11,12}`, and
     upstream's `Dockerfile.a5` builds on the 22.04 one.
   * Jammy's glibc is 2.35, comfortably above the `manylinux_2_28` floor every
     wheel in this stack targets. Noble's 2.39 was the untested jump.
   * The cp310 matrix is complete, not a compromise: `torch` 2.10.0+cpu,
     `torch_npu` 2.10.0.post4, `torchvision` 0.25.0+cpu, `torchaudio`
     2.10.0+cpu and `triton-ascend` 3.2.2 all publish cp310 `manylinux_2_28`
     x86_64 wheels, and vLLM 0.27.1 declares `requires-python >=3.10,<3.15`.
   * `BASE_IMAGE` remains an ARG, so noble is still reachable with one flag —
     the direction of the fallback has simply reversed.

   Verified in an `ubuntu:22.04` container rather than assumed: Python 3.10.12,
   glibc 2.35, `clang-15` at 1:15.0.7-0ubuntu0.22.04.3 from `jammy-updates`,
   and `python3-distutils` available (Python 3.10 still needs it; 3.12 does
   not, which is why it was absent from the noble-era package list).

4. **The public CANN 9.1.0 toolkit is not a complete CANN install**, and this
   was the hardest thing the build surfaced. Its `lib64` holds **150** shared
   objects; the `lib64` in Huawei's own image for this SoC
   (`quay.io/ascend/cann:9.1.0-950-ubuntu22.04-py3.10`) holds **176**. Three of
   the twenty-six missing ones stop the build dead:

   | Library | Needed by | Symptom if absent |
   |---|---|---|
   | `libopapi.so` | `vllm_ascend_C` links `-lopapi` for **every** SoC | `ld: cannot find -lopapi` |
   | `libopapi_math.so` | `libcust_opapi.so` in the custom-op package | installer: *"Shared library validation failed"* |
   | `libhccl.so` | `torch_npu`'s `DT_NEEDED` | `ImportError: libhccl.so` |

   None are separately downloadable: `Ascend-cann-kernels-{950,a5,910b}_9.1.0_*`
   and `-nnrt_9.1.0_*` all return **403** while the toolkit and NNAL return
   **206**. They are therefore lifted out of the vendor image's layer blob into
   `deps/950pr-x86_64/cann_extra/` (183 MB, 26 libraries) — the same route the
   310P used to obtain `libhccl.so` on CANN 8.5.0.

   `targets/target-950pr/provision.sh cann_extra` does this without a `docker
   pull`: it resolves the amd64 manifest, fetches the 4.41 GB layer with the
   same parallel range-request downloader used for the CANN `.run` files
   (~70 s at ~20 MB/s), and extracts only the missing `.so` files.

   The toolkit's own manifest confirms the omission is deliberate rather than a
   broken install: `share/info/hcomm/script/filelist.csv` lists
   `libhccl_{alg,legacy,plf,v2}.so` and `libhcomm.so` and no aggregate.

Unverified, and honestly so:

* ~~**`ASCEND_AICORE_ARCH=dav-v300`.**~~ **Resolved — it was wrong. See §8.8.**
  Checked against a real CANN 9.1.0 toolkit: `dav-v300` appears in no file at
  all, and every Ascend950 platform config says `CCEC_AIC_version=dav-c310-cube`.
  The value is now `dav-c310`. `targets/target-950pr/build.sh` still runs its
  `ascend950_list` probe automatically when it finds an extracted toolkit under
  the payload directory, and says so when it cannot.
* ~~**PEP 668 handling.**~~ **No longer a concern on this base.** Jammy ships
  no `/usr/lib/python3.10/EXTERNALLY-MANAGED` marker (checked in the
  container), so pip installs into the system interpreter unmodified — which is
  what the CANN installer needs, since it shells out to the system `pip3` for
  its `--pylocal` components and would not see a venv. The Dockerfile keeps a
  no-op `rm -f /usr/lib/python3.*/EXTERNALLY-MANAGED` purely so that overriding
  `BASE_IMAGE` with a marker-carrying release does not silently break.
* **Whether `9.1.0`'s toolkit really carries the x86_64 `--pylocal` payload the
  installer expects.** The 310P path proved this only for aarch64 payloads,
  though both land on a 22.04 base now, which narrows the gap to architecture
  alone.

---

## 7. Measured results

Built natively on x86_64 (12 cores, WSL2) with `--no-cache --network=none`, from
a payload staged by `targets/target-950pr/provision.sh`. The figures below are
from the reproduction at commit `5449353` — a second, independent cold build
that also served as the regression check on the `targets/` + `common/` refactor.

| | |
|---|---|
| Base image | `ubuntu:22.04` (jammy), Python 3.10.12, glibc 2.35 |
| Build time | **95m 20s** cold, wall clock (10:35:47Z → 12:11:07Z), including image export and the `pigz` save |
| — of which stage 6 | **5,310 s = 88m 30s** — the `vllm-ascend` wheel and its 493 ACLNN kernels, **93% of the build** |
| — next three stages | CANN toolkit install 90 s · pip transactions 60 s · offline apt 28 s |
| Image | `sha256:35510eb1…`, **20 layers**, 3,249,613,925 B content / 12.8 GB disk usage |
| Artefact | `<project_root>/artifacts/vllm-ascend-950pr-x86_64-offline.tar.gz` on the **Windows** drive — see [repository-layout.md](repository-layout.md) |
| Artefact size | **3,224,204,628 bytes** (3.1 GB), `docker save \| pigz` |
| Artefact SHA-256 | `f6e14dd12e62a6915502dab8b1f6b520b672e3080d39f68bae5931d8e6ba4c70` |
| Payload | 3.8 GB in `deps/950pr-x86_64/` |
| Verification | **10/10 passed, 0 failed** on a build host, from a green-field `docker load` |

### Reproduced, and diffed against the previous build

The image was deleted from the daemon and reconstructed **only** from the
exported archive before being verified, so the 10/10 above is a property of the
artefact, not of the build tree that produced it. `docker load` returned the
same image id the build had written.

Against the `e22b741` build of the same target:

| | e22b741 | 5449353 | |
|---|---|---|---|
| Filesystem layers | 18 | **20** | expected: the refactor added `COPY common/patches/ascend_setenv_nounset.sh` and `COPY common/docker/compiler_env.sh` |
| Image content size | 3,249,610,679 B | 3,249,613,925 B | +3,246 B — those two scripts |
| Installed distributions | 233 | 233 | identical |
| Distinct distribution names | 207 | 207 | **zero differences in either direction** |
| `vllm_ascend_C` symbols | 118 | 118 | identical |
| ACLNN package | 27 ops / 493 kernels / 793 files | same | identical |

The layer count is the only structural change, and it is accounted for
instruction by instruction: the pre-refactor Dockerfile had 17
layer-producing instructions, this one has 19, and both add one base-image
layer.

Stack as built, confirmed from inside the image:

```
torch 2.10.0+cpu   torch_npu 2.10.0.post4   vllm 0.27.1   vllm_ascend A5
triton-ascend 3.2.2 (provides the `triton` module; NVIDIA triton uninstalled)
CANN 9.1.0 toolkit + NNAL/ATB + 26 cann_extra libraries
ACLNN custom ops: 27 ops, 493 kernel binaries, 793 files installed
vllm_ascend_C: 118 exported symbols, no unresolved non-Python symbols
```

**Zero NVIDIA artefacts**, enforced at four independent points: the constraint
file, the wheelhouse resolve, `targets/target-950pr/build.sh` preflight, and an
in-image assertion that no `nvidia-*` distribution is installed and that
`torch.__version__` ends in `+cpu`.

### What 10/10 does and does not mean

**These numbers are the suite as it stood when the 9.1.0 image was measured.**
§8.4 added three assertions since — the CANN release match, the toolkit-path
sweep and pyACL — so the same image re-verified today reads 13/13 on a build
host and 14/14 on a 950. The reasoning below is unchanged; only the totals moved.

Two checks are reported as `[INFO]` because they need silicon, exactly as the
suite's contract requires — they are not silently passed:

* **`vllm_ascend_C` cannot be imported here.** With no NPU, CANN's
  `aclrtGetSocName()` returns NULL and the runtime aborts the process before
  Python can catch it.
* **`vllm serve --help` cannot run here.** It loads the platform plugin, which
  imports triton-ascend, whose driver queries the NPU architecture at import:
  `SystemError: <built-in function get_arch> returned NULL`.

So this image is proven *complete and self-consistent offline*. Proving the
operators **execute** requires a 950; re-run `verify` there and both checks are
exercised for real, taking the suite to **11/11**. Only one of the two adds a
new assertion — the `vllm_ascend_C` import — because the `vllm` CLI check
already counts on a build host, as "CLI on PATH", and merely gets stricter where
a device exists.

---

## 8. Migrating the CANN line — what changed, and what is left

The 950PR deployment failed because the image carried CANN 9.1.0 while the host
runs 9.2.0. That is a real class of failure, not a version-string cosmetic:
`torch_npu`, pyACL's C extension and the compiled ACLNN ops all bind to the
toolkit's own `lib64`, so a minor skew surfaces as `undefined symbol` several
imports deep, or as a NULL return from the first `aclnn*` call.

The fix is not "edit `9.1.0` to `9.2.0` in four files". It is to make the CANN
release a **parameter with no literal left behind**, and to assert the things
that were previously assumed. That is what this section records.

### 8.1 The release is now one variable

`CANN_VERSION` (default `9.2.0`) drives every path that mentions it:

| Where | Before | Now |
|---|---|---|
| `provision.sh` | `CANN_VERSION=9.1.0`, plus hardcoded `TOOLKIT_BYTES` / `NNAL_BYTES` | version-derived URLs; sizes from a per-release table, or a `HEAD` for a release with no entry |
| `provision.sh` `VENDOR_TAG` | literal `9.1.0-950-ubuntu22.04-py3.10` | `${CANN_VERSION}-950-ubuntu22.04-py3.10` |
| `deps.manifest` | `9.1.0` in four rows | `@CANN_VERSION@`, expanded by `build.sh` |
| `build.sh` | `CANN_VERSION=9.1.0` | `9.2.0`, and the manifest is expanded before parsing |
| `Dockerfile.x86_64` | `ARG CANN_VERSION=9.1.0` | `9.2.0`, and it is also an `ENV` so a running container can be asked |

Building the previous line therefore needs no edits at all:

```bash
CANN_VERSION=9.1.0 ./targets/target-950pr/provision.sh
CANN_VERSION=9.1.0 ./targets/target-950pr/build.sh
```

Three guards were added so a half-migrated payload cannot get through quietly,
because that produces an image that looks healthy and fails on hardware:

1. **`provision.sh verify` and `build.sh`** both refuse a payload containing
   `Ascend-cann-*.run` from a release other than `$CANN_VERSION`.
2. **`provision.sh cann`** checks the first bytes of each `.run` are `#!` — a
   403 XML body saved under the artefact's name has the right name and passes a
   naive existence check.
3. **The Dockerfile** reads `version=` out of `ascend_toolkit_install.info`
   after installing, and fails the build if it disagrees with `CANN_VERSION`.

`deps.manifest` also gained `pin|<version>|<file>|<bytes>|<sha256>` rows, which
`build.sh` now actually verifies — the `sha256` column was documentation before,
checked by nothing. A release with no pin row is size-checked with a warning
naming the row to add; `provision.sh cann` prints the hashes to paste in.

### 8.2 Where a pre-release CANN comes from

Since 9.2.0 is not downloadable (§1a), the payload accepts a vendor drop:

```bash
mkdir -p vendor/cann-9.2.0
cp Ascend-cann-toolkit_9.2.0_linux-x86_64.run vendor/cann-9.2.0/
cp Ascend-cann-nnal_9.2.0_linux-x86_64.run    vendor/cann-9.2.0/
./targets/target-950pr/provision.sh cann
```

`cann_extra` — the twenty-six runtime libraries the standalone toolkit omits,
`libopapi.so` / `libopapi_math.so` / `libhccl.so` among them — has the same
problem one level down: it is lifted from Huawei's vendor container, and there
is no 9.2.0 container either. Two offline routes:

```bash
cp libopapi_math.so libhccl.so vendor/cann-9.2.0/cann_extra/lib64/

docker save VENDOR_IMAGE -o cann-9.2.0-vendor.tar
CANN_VENDOR_TAR=$PWD/cann-9.2.0-vendor.tar ./targets/target-950pr/provision.sh cann_extra
```

**`VENDOR_TAG` is deliberately not allowed to silently fall back to 9.1.0.**
These libraries are copied into the toolkit's own `lib64` and resolved by the
same loader, so mixing releases *is* the undefined-symbol failure this migration
exists to remove. `provision.sh` stops with the commands above instead.

### 8.3 The hardcoded-path audit

Run against `vllm-ascend @ releases/v0.27.1rc` (`e61a5d7`), the ref this target
now pins. **Nothing requires `/usr/local/Ascend/cann-9.2.0`.** The complete set
of version-stamped CANN paths in that tree is one line, and it is a glob:

```
tests/e2e/nightly/multi_node/scripts/run.sh:44
    CANN_DIR=$(ls -d /usr/local/Ascend/cann-* 2>/dev/null | head -1 || true)
```

with its own comment saying the directory "varies between release (cann-9.1.0)
and daily (e.g. cann-2026.08.03) images, so discover it dynamically instead of
hardcoding a version-specific path". It is nightly multi-node test tooling, it
only sources the *optional* `ascendnpu-ir/bin/set_env.sh`, and it degrades to a
warning when absent.

Everything else resolves the toolkit through one of:

| Path | Consumers |
|---|---|
| `$ASCEND_HOME_PATH` / `$ASCEND_TOOLKIT_HOME` | `csrc/build.sh:1338`, `csrc/cmake/config.cmake:26`, `csrc/cmake/dependencies.cmake:13`, `setup.py:263` |
| `/usr/local/Ascend/ascend-toolkit/latest` | `collect_env.py:300`, upstream's own Dockerfiles, `csrc/build.sh:73` |
| `/usr/local/Ascend/latest` (no `ascend-toolkit` segment) | `csrc/cmake/config.cmake:30`, `csrc/cmake/dependencies.cmake:19`, `csrc/build.sh:74` — **fallbacks only**, each guarded by an `$ASCEND_HOME_PATH` test that this image satisfies |

The Dockerfile creates both `cann-${CANN_VERSION}` and `latest` as symlinks to
`ascend-toolkit/latest` anyway (stage 3c). Not because anything demands them —
the audit says otherwise — but because they cost one inode each, they satisfy
that glob so the optional `set_env.sh` is found rather than skipped, they make
the tree match the vendor images operators have runbooks for, and they close the
`/usr/local/Ascend/latest` fallback in case a future refactor upstream reaches
it. `verify_runtime.sh` step 3 asserts all of them land on the same tree.

### 8.4 pyACL

`import acl` is CANN's own Python binding, shipped with the toolkit and built
against that release's `libascendcl.so`. **It must never become a pip install** —
anything on PyPI by that name is an unrelated project, and installing one
shadows the real module with something that cannot talk to an NPU.

It is on the inference path, not optional:

```
vllm_ascend/device_allocator/camem.py:27
    from acl.rt import memcpy
```

at module scope, for the CANN-mem sleep-mode allocator. The wiring is three
layers, each covering a gap the previous one leaves:

1. **`PYTHONPATH`** carries `${ASCEND_TOOLKIT_HOME}/python/site-packages` and
   the arch-qualified `x86_64-linux/…` spelling. Which one physically holds the
   module depends on the release's symlink layout, so both are listed.
2. **A `.pth` file** in the interpreter's own `purelib`, written at build time by
   `common/docker/pyacl_wire.py --install` after *discovering* the directory.
   This is what makes `import acl` resolve **natively, with no pip install and
   no environment cooperation**: `PYTHONPATH` is a single string that
   `docker run -e PYTHONPATH=...` replaces outright, and any wrapper that scrubs
   the environment (`env -i`, a supervisor, a spawn worker from a sanitised
   parent) loses it. `site` reads the `.pth` at every interpreter start.
3. **Assertions**, at build time and again at run time, that distinguish three
   outcomes which look alike in a traceback:

   | Outcome | Meaning | Build | `verify` on a build host | `verify` on a 950PR |
   |---|---|---|---|---|
   | module not found | toolkit installed without `--full` | **fail** | fail | fail |
   | `undefined symbol` | pyACL and the CANN libraries beside it are different releases | **fail** | fail | fail |
   | missing `libascend_hal.so` etc. | host driver not mounted — `/usr/local/Ascend/driver/lib64` is empty in the image by design | pass, noted | pass, noted | **fail** |

`LD_LIBRARY_PATH` was audited rather than reordered. "Put the toolkit first" is
the wrong instinct here: the three `/usr/local/Ascend/driver/lib64*` entries
ahead of it are **empty in the image** and are where the host's driver is
bind-mounted, and the driver half of the stack must come from the host kernel
module's own userspace. Promoting the toolkit above them would shadow the real
driver with the toolkit's stubs — healthy on a build host, broken on silicon.
Since this image contains exactly one CANN tree (`cann-${CANN_VERSION}` and
`latest` are symlinks *into* it, not copies), the toolkit's `lib64` sitting
immediately after those three already has the highest priority any CANN library
can have. What was added is upstream's `<arch>-linux/devlib` spelling alongside
this repo's `devlib`, since which one exists varies by release.

### 8.5 The vllm-ascend ref is pinned

`provision.sh` staged `main` while the Dockerfile stamped
`SETUPTOOLS_SCM_PRETEND_VERSION=0.26.0` on whatever arrived — so the wheel
claimed a version it was not built from, and two provisioning runs a day apart
produced different images from an unchanged repository. Both now point at
`releases/v0.27.1rc`, fetched **by commit** (`VLLM_ASCEND_COMMIT`,
`e61a5d7204fe4a0fc329471df8e4c3c90e9bb2f1`), with the stamp moved to `0.27.1`.
That branch is the one upstream cuts against vLLM v0.27.1 — already this
target's `VLLM_REF` — and its `Dockerfile.a5` pins the same torch / torch_npu /
triton-ascend set the wheelhouse stages. `src/vllm-ascend/.provenance` records
repo, ref, commit and timestamp, so an image traces back to an exact tree with
`.git` deleted.

### 8.6 torch_npu is the pin the repo cannot derive

Everything else in the wheelhouse is independent of the CANN release. `torch_npu`
is not: it links the toolkit's `lib64` directly, so it is paired with a CANN
version the way pyACL is, and getting it wrong produces `undefined symbol` at
`import torch_npu`.

There is no table to look it up in. torch_npu's own published compatibility
matrix is on the **8.x** CANN numbering and stops at

| CANN | PyTorch | torch_npu |
|---|---|---|
| 8.5.0 | 2.12.0 | 2.12.0rc1 |

with **no CANN 9.x row at all** — the 950/A5 line is newer than that table. The
only authority for a 9.x pairing is vllm-ascend's own pins, and at the ref this
target follows those are `torch==2.10.0` / `torch-npu==2.10.0.post4`
(`requirements.txt:16-17`, `pyproject.toml:21-22`), paired with CANN 9.1.0 by
`Dockerfile.a5`.

So for a 9.2.0 build the pairing is **unattested, not wrong**. PyPI also carries
`2.10.0.post6`, `2.11.0` and `2.12.0`, and choosing one of those because it is
newer is exactly the guess that breaks the import. `provision.sh verify`
therefore *warns* rather than failing — the payload is usable, the pairing is
not confirmed — and names `TORCH_NPU_CANN` (default `9.1.0`) as the variable to
move once it is. Take the real answer from the vendor drop's release notes, or
from a vllm-ascend ref whose `Dockerfile.a5` names 9.2.0; upstream's daily stage
carries `ARG TORCH_NPU_VERSION` / `TORCH_NPU_DATE` precisely because a
pre-release CANN needs a torch_npu built against it. Move torch, torchvision,
torchaudio and triton-ascend with it — upstream treats the five as one set.

### 8.7 What remains, and what blocks it

Everything above is in the repository and the logic is exercised: the manifest
templating and `pin` verification were replayed against fabricated payloads
(correct / corrupted / truncated / mixed-release), the vendor-drop adoption and
the `#!` shape check were run end to end, the unobtainable-release and
unpublished-vendor-image error paths were triggered against the live bucket and
registry, and the `.pth` mechanism was proven in a venv — `import acl` resolving
in a fresh interpreter with `PYTHONPATH` unset.

**The 9.2.0 build itself has not been run**, and one thing blocks it: there is
no CANN 9.2.0 to build against (§1a). It needs a vendor drop into
`vendor/cann-9.2.0/`. `deps/950pr-x86_64/` is also empty in this checkout, so
provisioning is a further ~10 GB, but that is time rather than a blocker.

What *was* run without it:

* `docker buildx build --check` over the whole Dockerfile — **no warnings**.
* `common/docker/pyacl_wire.py` against a real CANN 9.1.0 install, out of
  `quay.io/ascend/cann:9.1.0-950-ubuntu22.04-py3.10`, to confirm the discovery
  and classification logic against a genuine toolkit layout rather than an
  assumed one.

With the drop in place:

```bash
./targets/target-950pr/provision.sh
./targets/target-950pr/build.sh --no-cache --save artifacts/vllm-ascend-950pr-x86_64-offline.tar.gz
./targets/target-950pr/run_dev.sh verify
```

Expect roughly 95 minutes cold (§7), dominated by the 493 ACLNN kernel binaries
that 9.2.0's `bisheng` will rebuild from scratch. The acceptance criteria —
`import acl`, `import torch_npu` and `vllm_ascend_C` with no `undefined symbol`
or path errors — are assertions 6, 7 and 10 of the suite, and on the 950PR
itself the pyACL check tightens from "resolves" to "imports" (14/14).

### 8.8 Two build flags corrected against a real CANN 9.1.0 toolkit

The pyACL work needed a genuine CANN tree to test against, and Huawei's own
`quay.io/ascend/cann:9.1.0-950-ubuntu22.04-py3.10` provided one. Having it on
disk settled three things this repo had been carrying as assumptions — two of
which were wrong.

**1. `ASCEND_AICORE_ARCH` was `dav-v300`. That string does not exist.**

`grep -rl dav-v300` over the entire toolkit returns nothing. Every Ascend950
platform config — PR and DT alike — says:

```ini
# x86_64-linux/data/platform_config/Ascend950PR_957d.ini  (and 950DT_9582.ini)
Short_SoC_version=Ascend950
CCEC_AIC_version=dav-c310-cube
CCEC_AIV_version=dav-c310-vec
```

The repo's convention is the base arch without the `-cube` / `-vec` suffix, and
the other two targets confirm it: 310P3's ini says `CCEC_AIC_version=dav-m200`
and this repo uses `dav-m200`; 910B's says `dav-c220-cube` and the docs say
`dav-c220`. By the same rule Ascend950 is **`dav-c310`**, and that is now the
value.

The blast radius is small but real. `ASCEND_AICORE_ARCH` is **not read by
vllm-ascend at all** — its tree contains no reference to the name — so the wheel
build was never affected. It is this repo's own variable, consumed by
`builders/builder-x86_64` and `build_vllm_ascend_wheel.sh` for direct
`ccec`/`bisheng` invocations, and exported into the image so a dev shell has it.
So the correction changes nothing about the image that ships and everything
about whether a hand-run kernel compile targets the actual core.

**2. `SOC_VERSION=ascend950dt_9582` is valid, but it is a 950-DT part.**

It is genuinely buildable — `host_config.cmake`'s `ascend950_list` contains it
and `platform_config/Ascend950DT_9582.ini` exists — and it is what upstream's
`Dockerfile.a5` ships. But CANN treats 950PR and 950DT as **distinct SoC
families** with separate name spaces, and `ascend950_list` carries both:

| Family | Values in CANN 9.1.0 |
|---|---|
| **950PR** | `ascend950pr_`{`9579`, `957b`, `957c`, `957d`, `9589`, `958a`, `958b`, `9599`, `950z`} |
| 950DT | `ascend950dt_`{`9571`–`9578`, `9581`–`9588`, `9591`, `9592`, `9595`, `9596`, `95a1`, `95a2`, `950x`, `950y`} |

They share `Short_SoC_version=Ascend950` and the `dav-c310` core, so a DT build
is not obviously wrong on PR silicon — but the 493 ACLNN kernel binaries this
image compiles are keyed on the exact `SOC_VERSION`, and nothing checks at load
time that it matches the part underneath. **This target is named 950PR and
defaults to a DT value**, so `build.sh` now warns when `SOC_VERSION` is a
`ascend950dt_*` one and points at the derivation:

```bash
npu-smi info -t board -i 0     # then (Chip Name + "_" + NPU Name), lowercased
```

That is not changed to a PR default here, because guessing *which* of the nine
PR parts is as wrong as guessing DT. Derive it from the board.

**3. `cann-<version>` is the canonical layout, not an alias.** Confirmed on both
the 950 image and a 310P one:

```
/usr/local/Ascend/cann-9.1.0                    the actual tree
/usr/local/Ascend/cann                       -> cann-9.1.0
/usr/local/Ascend/ascend-toolkit/latest      -> /usr/local/Ascend/cann
ASCEND_TOOLKIT_HOME=/usr/local/Ascend/cann-9.1.0     <- the vendor's own value
ASCEND_HOME_PATH=/usr/local/Ascend/cann-9.1.0
```

This image installs from the `.run`, which lays down `ascend-toolkit/<ver>` plus
`latest` and none of the `cann` names — so stage 3c adds them, linking in the
opposite direction to the same effect. §8.3's audit said nothing *requires*
them; this says the vendor images *have* them, which is the better reason.

**And one assumption that held.** pyACL is at
`<root>/python/site-packages/acl.so` (with an `acl/` package beside it), and
`import acl; from acl.rt import memcpy` **succeeds with no NPU and no driver
mounted** — `libascendcl.so` resolves its driver-side dependencies lazily. So
the acceptance criterion is enforceable at build time, not only on the target.
The build-time check still classifies a driver-shaped failure as non-fatal,
since that is the one failure a build host cannot judge and a future release
could start binding eagerly; `undefined symbol` is fatal everywhere.
