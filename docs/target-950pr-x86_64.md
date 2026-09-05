# Ascend 950PR on x86_64: build flags, staging plan and runtime

A `linux/amd64` offline inference image for Ascend 950-class silicon (Atlas
350, DaVinci v3, device family **A5**), built natively on an x86_64 host.

**Status: scaffolded, not yet built.** Every file is in place and every path is
wired, but `deps/950pr-x86_64/` has not been staged — that is a multi-gigabyte
networked step, and §4 below is the plan for it. `build_950pr_x86_64.sh`
refuses to start until the manifest is satisfied, so nothing here can be
mistaken for a working image.

This is the sibling of the 310P image in [README.aarch64.md](../README.aarch64.md).
The two differ in more than the SoC:

| | 310P3 (`docker/target-310p`) | 950PR (`docker/target-950pr`) |
|---|---|---|
| Image architecture | `linux/arm64`, QEMU-emulated at build time | `linux/amd64`, **native** |
| Base OS / Python | Ubuntu 22.04 / 3.10 | Ubuntu 24.04 / 3.12 |
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
| Python | 3.12 | noble system interpreter |
| vLLM | v0.27.1 | **built from source**, `VLLM_TARGET_DEVICE=empty` |
| vllm-ascend | `main` | no tagged release carries the A5 gates yet |
| torch | 2.10.0 | download.pytorch.org/whl/cpu |
| torch_npu | 2.10.0.post4 | **Ascend mirror only** |
| torchvision / torchaudio | 0.25.0 / 2.10.0 | download.pytorch.org |
| triton-ascend | 3.2.2 | Ascend mirror; needs clang-15 |

Two traps worth stating plainly:

* **PyPI's x86_64 `vllm` wheel is a CUDA build.** On aarch64 this was already
  true; on x86_64 pip will resolve it happily and produce an image that imports
  cleanly and dispatches to nothing. The wheel must be built from the v0.27.1
  source with `VLLM_TARGET_DEVICE=empty`.
* **torch_npu 2.10.0.post4 is not on PyPI.** PyPI's newest `torch-npu` is
  2.9.1. 2.10.0.post4 lives on `mirrors.huaweicloud.com/ascend/repos/pypi`. If
  that mirror is unreachable, the fallback is the 2.9.1 + matching
  vllm-ascend/vLLM set — a *different* matrix, not a substitution into this one.

---

## 3. Build flags and environment

```bash
./build_950pr_x86_64.sh
./build_950pr_x86_64.sh --save artifacts/vllm-ascend-950pr-x86_64-offline.tar.gz
```

which wraps:

```bash
docker buildx build \
    --platform linux/amd64 \
    --network=none \
    --build-arg SOC_VERSION=ascend950dt_9582 \
    -f docker/target-950pr/Dockerfile.x86_64 \
    -t vllm-ascend-950pr:x86_64-offline \
    --load \
    .
```

### Build ARGs

| ARG | Default | Notes |
|---|---|---|
| `BASE_IMAGE` | `ubuntu:24.04` | see §6 on the noble deviation |
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
§"Why `SOC_VERSION` is lowercase `ascend310p3`"). `build_950pr_x86_64.sh`
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

`docker/target-950pr/deps.manifest` is the machine-readable version of this
section; the build script parses it and refuses to start until every row is
satisfied. Sizes there were measured with HTTP range requests; SHA-256 values
are deliberately unpinned (`-`) because they cannot be known without
downloading, and should be pinned from the first verified fetch.

```
deps/950pr-x86_64/
  Ascend-cann-toolkit_9.1.0_linux-x86_64.run     1,298,337,341 bytes
  Ascend-cann-nnal_9.1.0_linux-x86_64.run          572,750,476 bytes
  apt_debs/                 .deb closure of packages/sys_packages.txt + Packages.gz
  python_wheels/            cp312 manylinux x86_64 wheelhouse
  src/vllm-ascend/          upstream checkout, no patches applied
```

**1. CANN installers**

```bash
BASE='https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/CANN/CANN%209.1.0'
wget -c "$BASE/Ascend-cann-toolkit_9.1.0_linux-x86_64.run"
wget -c "$BASE/Ascend-cann-nnal_9.1.0_linux-x86_64.run"
sha256sum Ascend-cann-*_9.1.0_linux-x86_64.run   # pin these into deps.manifest
```

**2. apt archive.** Native this time — no QEMU container needed, just a noble
one so the `.deb`s match the base image:

```bash
docker run --rm -v "$PWD/deps/950pr-x86_64/apt_debs:/out" \
  -v "$PWD/docker/target-950pr/packages/sys_packages.txt:/pkgs.txt:ro" \
  ubuntu:24.04 bash -c '
    apt-get update -qq &&
    apt-get install -y --no-install-recommends --download-only \
      $(grep -vE "^[[:space:]]*(#|$)" /pkgs.txt | tr "\n" " ") &&
    cp /var/cache/apt/archives/*.deb /out/ &&
    cd /out && apt-get install -y dpkg-dev >/dev/null &&
    dpkg-scanpackages . > Packages && gzip -kf Packages'
```

**3. wheelhouse.** Resolve as cp312/x86_64, with the Ascend mirror as an extra
index for `torch-npu` and `triton-ascend`:

```bash
pip download --only-binary=:all: -d deps/950pr-x86_64/python_wheels \
  -r docker/target-950pr/requirements/python_wheels.txt \
  --extra-index-url https://download.pytorch.org/whl/cpu \
  --extra-index-url https://mirrors.huaweicloud.com/ascend/repos/pypi
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

## 5. Operator coverage — read before believing a PASS

The 950 operator set produced by this image is **a subset of DaVinci v3's
capability, not the full set**, because that is what upstream currently builds.
`vllm-ascend@main` puts `ascend950` on the *same* CMake branch as `ascend310p`
in three places:

```cmake
if(SOC_VERSION MATCHES "ascend310p.*|ascend950")   # skip the whole kernels lib
    message(STATUS "Hardware ${SOC_VERSION} detected: skip vllm_ascend_kernels compile")

set(VLLM_ASCEND_CUSTOM_OP_EXCLUDE_ASCEND950        # drop MLAPO + batch_matmul_transpose
    .../mla_preprocess/op_kernel/mla_preprocess_kernel.cpp
    .../batch_matmul_transpose/op_kernel/batch_matmul_transpose_kernel.cpp)

if(NOT (SOC_VERSION MATCHES "ascend310p.*|ascend950"))
    target_compile_definitions(vllm_ascend_C PRIVATE -DVLLM_ENABLE_ATB_AND_DIRECT_KERNELS)
```

and `vllm_ascend/utils.py` says it outright: *"in ASCEND950 chip, we temporarily
disable all custom ops"*. Only `vllm_ascend_C` is installed; there is no
`libvllm_ascend_kernels.so`.

So a request for "the full operator set — FlashAttention, MLA, FP8, MXFP4/FP4"
cannot be satisfied by building upstream today, and an image claiming it would
be claiming something untrue. `verify_runtime.sh` therefore asserts the shape
upstream actually produces and prints the exclusions as `[INFO]`. When upstream
enables those kernels, step 6 of the suite and the stage 6 note in the
Dockerfile have to move together — deliberately, not silently.

What *is* asserted: no 310P stub symbols leaked in, `vllm_ascend_C` links with
no unresolved non-Python symbols, and the device family is `A5`.

---

## 6. What is deviated from, and what is unverified

Three places where this scaffold does not match the brief it was built from,
each for a reason that would otherwise cause a silent failure:

1. **`SOC_VERSION=Ascend950PR` → `ascend950dt_9582`.** Case-sensitive CMake
   gates; §3 above.
2. **"Full operator set" → upstream's subset.** §5 above.
3. **Ubuntu 24.04 / Python 3.12 is unreferenced upstream.** Huawei publishes
   950 images only on `ubuntu22.04` and `openeuler24.03`, and upstream's
   `Dockerfile.a5` builds on the 22.04 one. Noble was requested and is
   implemented, but nothing upstream exercises this combination: expect the
   `.run` installer's distro checks and the glibc 2.39 jump to be where trouble
   appears first. Fallback is one flag —
   `BASE_IMAGE=ubuntu:22.04 ./build_950pr_x86_64.sh` — with `python3.10` in
   `packages/sys_packages.txt` and a cp310 wheelhouse.

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

  `build_950pr_x86_64.sh` runs that check automatically when it finds an
  extracted toolkit under the payload directory, and says so when it cannot.
* **PEP 668 handling.** Noble marks its interpreter externally managed; the
  Dockerfile removes `/usr/lib/python3.12/EXTERNALLY-MANAGED` because the CANN
  installer shells out to the system `pip3` for its `--pylocal` components. A
  venv would be tidier but does not survive that.
* **Whether `9.1.0`'s toolkit really carries the x86_64 `--pylocal` payload the
  installer expects on noble.** The 310P path proved this only for aarch64
  payloads on a 22.04 base.
