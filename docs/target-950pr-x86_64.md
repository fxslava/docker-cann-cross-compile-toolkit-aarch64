# Ascend 950PR on x86_64: build flags, staging plan and runtime

A `linux/amd64` offline inference image for Ascend 950-class silicon (Atlas
350, DaVinci v3, device family **A5**), built natively on an x86_64 host.

**Status: built and verified.** `deps/950pr-x86_64/` was staged in full (3.8 GB)
and the image was built natively on x86_64 with `--network=none`, then verified
inside the container: **10/10 checks pass on a build host**, with the
hardware-only checks reported as `[INFO]` rather than counted. See §7 for the
measured numbers and §5 for what the operator set actually turned out to be.

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
| CANN | 8.5.0 | 9.1.0 (+ NNAL/ATB) |
| Unpacker stage | needed, to dodge the emulation tax | **none** — installer runs natively |
| `ldconfig` stub | needed, `qemu-user` segfaults | **none** |
| Local patches | 1, for bf16/`PIPE_FIX` kernel gating | **none**, by design |
| Serving dtype | forced `float16` | checkpoint's own (bf16 capable) |

---

## 1. Why CANN 9.1.0, and how that was established

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

---

## 2. The release matrix

Read out of `vllm-ascend@main` (`requirements.txt`, `pyproject.toml`) and its
`Dockerfile.a5`. It moves as a set:

| Component | Pin | Source |
|---|---|---|
| CANN | 9.1.0 | Huawei OBS bucket |
| CANN NNAL (ATB) | 9.1.0 | same bucket |
| Python | 3.10 | jammy system interpreter |
| vLLM | v0.27.1 | **built from source**, `VLLM_TARGET_DEVICE=empty` |
| vllm-ascend | `main` | no tagged release carries the A5 gates yet |
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
| `CANN_VERSION` | `9.1.0` | selects both `.run` filenames |
| `SOC_VERSION` | `ascend950dt_9582` | **lowercase, see below** |
| `ASCEND_AICORE_ARCH` | `dav-v300` | **unverified, see §6** |
| `COMPILE_CUSTOM_KERNELS` | `1` | |
| `VLLM_ASCEND_VERSION` | `0.26.0` | `setuptools-scm` pretend-version |

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
far the largest product of this image — roughly **87 minutes** of the build,
installed at `vllm_ascend/_cann_ops_custom/vendors/custom_transformer` with
`libcust_opapi.so` alongside it. `verify_runtime.sh` now asserts its presence.

`mla_prolog_v3` is among the 27, so **MLAPO is not excluded on this SoC** — the
`MlaPrologV3_*` kernels are among the slowest to compile in the whole run. The
ops actually built are listed in `build_aclnn.sh`'s `ascend950` branch:
`moe_gating_top_k_hash`, `inplace_partial_rotary_mul`, `kv_compress_epilog`,
`compressor`, `vllm_quant_lightning_indexer`, `kv_quant_sparse_attn_sharedkv`,
`swiglu_group_quant`, `situ_mx_quant`, `causal_conv1d`,
`recurrent_gated_delta_rule`, `recurrent_kda`, `chunk_fwd_o`,
`chunk_gated_delta_rule_fwd_h`, `chunk_kda_fwd`, `kda_gate_cumsum`,
`store_kv_block`, `k2q_csr`, `sparse_attention_score`, `mla_prolog_v3` and
others.

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

* **`ASCEND_AICORE_ARCH=dav-v300`.** This repo has never had a CANN 9.x payload
  on disk. What *is* known is that vllm-ascend maps `ascend950` to kernel
  directory `arch35` (`csrc/CMakeLists.txt`, `ARCH_DIRECTORY_LIST`), which is
  not the same statement. Confirm against the toolkit before trusting a kernel
  build:

  ```bash
  grep -nE '^set\((ascend|kirin)[a-z0-9_]*_list' \
    <toolkit>/ascendc_kernel_cmake/legacy_modules/host_config.cmake
  ```

  `targets/target-950pr/build.sh` runs that check automatically when it finds an
  extracted toolkit under the payload directory, and says so when it cannot.
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

Built natively on x86_64 (12 cores, WSL2) with `--network=none`, from a payload
staged by `targets/target-950pr/provision.sh`.

| | |
|---|---|
| Base image | `ubuntu:22.04` (jammy), Python 3.10.12, glibc 2.35 |
| Build time | **86m 58s** cold (kernel compilation is ~87m of it) |
| Image | 3.25 GB content / 12.8 GB disk usage |
| Artefact | `<project_root>/artifacts/vllm-ascend-950pr-x86_64-offline.tar.gz` on the **Windows** drive — see [repository-layout.md](repository-layout.md) |
| Artefact size | **3,224,198,617 bytes** (3.1 GB), `docker save \| pigz` |
| Artefact SHA-256 | `1d4435a4170c488883ff2b64313df2f16ca9f85a604a026b7488d76b80e13546` |
| Payload | 3.8 GB in `deps/950pr-x86_64/` |
| Verification | **10/10 passed, 0 failed** on a build host |

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

Two checks are reported as `[INFO]` because they need silicon, exactly as the
suite's contract requires — they are not silently passed:

* **`vllm_ascend_C` cannot be imported here.** With no NPU, CANN's
  `aclrtGetSocName()` returns NULL and the runtime aborts the process before
  Python can catch it.
* **`vllm serve --help` cannot run here.** It loads the platform plugin, which
  imports triton-ascend, whose driver queries the NPU architecture at import:
  `SystemError: <built-in function get_arch> returned NULL`.

So this image is proven *complete and self-consistent offline*. Proving the
operators **execute** requires a 950; re-run `verify` there and the suite
exercises both checks and reports 12/12.
