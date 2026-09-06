# `target-950pr` — Ascend 950 (A5) x86_64 Deployment Guide

Operator guide for the **`linux/amd64` offline inference image** for Huawei
Ascend 950-class parts. Provision it on a connected machine, build it
air-gapped, carry it to the target server, serve models with `vllm serve`.

For *why* the image is built the way it is — the CANN 9.1.0 pin, the
`SOC_VERSION` casing, the operator-coverage finding — read
[docs/target-950pr-x86_64.md](../../docs/target-950pr-x86_64.md). This document
is the *how*.

| | |
|---|---|
| Image tag | `vllm-ascend-950pr:x86_64-offline` |
| Platform | `linux/amd64` — **native, no emulation** |
| Target SoC | Ascend 950 (A5 / DaVinci v3), AI Core `dav-v300` |
| `SOC_VERSION` | `ascend950dt_9582` (**lowercase**) |
| Device family | `A5` |
| Base | Ubuntu 22.04, Python 3.10 |
| Stack | CANN 9.1.0 + NNAL/ATB · torch 2.10.0+cpu · torch_npu 2.10.0.post4 · vLLM v0.27.1 · vllm-ascend `main` |
| Payload | `deps/950pr-x86_64/` (override with `DEPS_DIR`) |
| Build strategy | **native x86_64 compilation** — 27 ACLNN custom ops, 493 kernel binaries |
| Cold build | **95 m 20 s** — 88 m 30 s of it is the kernel compile |
| Artefact | 3,224,204,628 B (3.1 GB) from a 20-layer, 12.8 GB image |
| Verify | **10/10** on a build host, 11/11 with an NPU |

---

## The four entry points

```bash
./targets/target-950pr/provision.sh
```

```bash
./targets/target-950pr/build.sh
```

```bash
./targets/target-950pr/run_dev.sh
```

```bash
./targets/target-950pr/run_dev.sh verify
```

1. `provision.sh` stages `deps/950pr-x86_64/` — **the only networked step**.
2. `build.sh` builds with `--network=none`.
3. `run_dev.sh` opens an interactive shell in the built image.
4. `run_dev.sh verify` runs the in-image check suite (`verify_runtime.sh`).

All four are run **from the repository root** — the build context is the root,
never this directory.

---

## Prerequisites

* Docker 20.10+ with BuildKit and `docker buildx`.
* **No QEMU, no `binfmt` registration.** Host and target are both x86_64; that
  is the one prerequisite this target does not share with the 310P.
* `pigz`, for `--save *.gz`.
* ~60 GB free disk (12.8 GB image + 3.8 GB payload + BuildKit cache) and
  8–16 GB RAM. The kernel compile runs `nproc` `bisheng` processes at once, so
  core count is what the build time actually tracks.
* Work inside the WSL 2 native filesystem, not `/mnt/c` or `/mnt/d`.

---

## Phase 1 — provision (online)

```bash
./targets/target-950pr/provision.sh
```

Stages everything that is missing. It is resumable and accepts named stages, in
this order:

```bash
./targets/target-950pr/provision.sh cann cann_extra src thirdparty debs vllm wheels verify
```

### What it stages

| Path | Contents |
|---|---|
| `Ascend-cann-toolkit_9.1.0_linux-x86_64.run` | CANN toolkit, 1,298,337,341 B, SHA-256 pinned in `deps.manifest` |
| `Ascend-cann-nnal_9.1.0_linux-x86_64.run` | NNAL — ATB lives here, 572,750,476 B, pinned |
| `cann_extra/lib64/` | the **26 libraries the public toolkit omits**, lifted from the vendor image layer |
| `apt_debs/` | amd64 `.deb` closure of `packages/sys_packages.txt` + `Packages.gz` |
| `python_wheels/` | cp310 manylinux x86_64 wheelhouse, including the built vLLM wheel |
| `src/vllm-ascend/` | plugin checkout **with the `catlass` submodule headers** |
| `third_party/` | abseil, protobuf and nlohmann/json for the ACLNN op build |

Every row is declared in [`deps.manifest`](deps.manifest), and `build.sh`
refuses to start until each one is satisfied — the payload is *checked*, not
assumed.

### The public CANN 9.1.0 toolkit is incomplete

Its `lib64` holds 150 shared objects against the 176 in Huawei's own image for
this SoC. Three of the missing 26 are load-bearing:

* `libopapi.so` — `vllm-ascend` links `-lopapi` for every SoC;
* `libopapi_math.so` — the compiled custom-op package will not install without it;
* `libhccl.so` — recorded in every `torch_npu` build's `DT_NEEDED`.

No published `.run` carries them (`kernels-{950,a5,910b}` and `nnrt` all answer
403), so `provision.sh` extracts them from the
`quay.io/ascend/cann:9.1.0-950-ubuntu22.04-py3.10` **layer blob**. That pull
happens once and never reaches the image build, which stays `--network=none`.

### The vLLM wheel is built, not downloaded

PyPI's x86_64 `vllm` is a **CUDA** build. The Ascend backend lives entirely in
`vllm-ascend`, so vLLM v0.27.1 is built from source with
`VLLM_TARGET_DEVICE=empty` via `common/scripts/build_vllm_wheel.sh` — natively,
which is why this step costs minutes here and not hours.

### The `catlass` submodule is not optional

`csrc/build_aclnn.sh` takes the `ascend950` branch, calls
`setup_catlass_dependency()`, and runs `git submodule update` when
`csrc/third_party/catlass/include` is absent. Under `--network=none` that fails
and takes the whole `vllm-ascend` wheel build with it. The codeload tarball
ships the directory empty, so `provision.sh` stages the headers explicitly.

### Provisioning knobs

| Variable | Default | Purpose |
|---|---|---|
| `CANN_VERSION` | `9.1.0` | toolkit and NNAL version |
| `VLLM_ASCEND_REF` | `main` | plugin ref |
| `PIP_INDEX_URL` | PyPI, falling back to the Tsinghua mirror | pin the index and skip the reachability probe |

---

## Phase 2 — build (air-gapped)

```bash
./targets/target-950pr/build.sh
```

which wraps:

```bash
docker buildx build --platform linux/amd64 --network=none --progress=plain --build-arg BASE_IMAGE=ubuntu:22.04 --build-arg CANN_VERSION=9.1.0 --build-arg SOC_VERSION=ascend950dt_9582 -f targets/target-950pr/Dockerfile.x86_64 -t vllm-ascend-950pr:x86_64-offline --load .
```

`--network=none` applies to every `RUN`, so a successful build **is** the proof
that `deps/950pr-x86_64/` is complete. Only the `$BASE_IMAGE` and the BuildKit
dockerfile frontend may be fetched, and only when not already cached.

### What the build does

| Stage | Step |
|---|---|
| 1 | apt from `deps/950pr-x86_64/apt_debs`, exposed as a `deb [trusted=yes] file:/debs ./` repository; `clang-15` aliased to `clang`/`clang++` |
| 2 | pip bootstrap from the wheelhouse |
| 3 | **CANN 9.1.0 toolkit + NNAL installed natively** — no unpacker stage, no emulation |
| — | `cann_extra` copied into the toolkit's `lib64`; `libhccl.so` fallback wired via `common/patches/hccl_devlib_fallback.sh` |
| 4 | environment (`ASCEND_TOOLKIT_HOME`, `ATB_HOME_PATH`, `LD_LIBRARY_PATH`, `SOC_VERSION`, `ASCEND_AICORE_ARCH=dav-v300`, …) |
| 5 | torch stack, vLLM and the `vllm-ascend` dependency set in separate pip transactions, then a no-CUDA assertion |
| 6 | `vllm-ascend` built for `ascend950dt_9582` and installed — **this is the 88 minutes** |
| 7 | driver plumbing (`HwHiAiUser`, `/var/driver`, `/usr/slog`) |
| 8 | entrypoint + verify suite, then a build-time import assertion |

**No patches are applied for this target.** Unlike the 310P, upstream
`vllm-ascend` builds for a 950 unmodified.

The image **cannot be produced** unless `import torch, torch_npu, vllm,
vllm_ascend` all succeed inside it.

### Stage 6 is the whole build, and it looks hung

`csrc/build_aclnn.sh` compiles **27 ACLNN custom ops into 493 kernel binaries**
with `ccec`/`bisheng`, driven by ninja. BuildKit buffers the stage log, so
`--progress=plain` can sit silent for half an hour while the machine is fully
loaded. Check the process table, not the log:

```bash
pgrep -c bisheng
```

The tail is badly skewed: kernels 1–480 finish in ~47 min, and the final 13 —
dominated by `MlaPrologV3_*` — take ~44 min on their own, with single compiler
processes alive for 14+ minutes.

### Caching: how not to lose 88 minutes

BuildKit keys a layer on the literal command string **plus its mounts**. Editing
anything the stage-6 `RUN` references — including adding a `--mount` for a
helper script — invalidates it and restarts the compile from kernel 1/493. That
is why `common/patches/cmake_fetchcontent_local.sh` is *inlined* in the
Dockerfile rather than mounted there.

The entrypoint and verify suite are `COPY`ed at stage 8, so editing them
rebuilds in seconds.

For a deliberately cold measurement:

```bash
docker builder prune -a -f && docker system prune -f
```

### Export

```bash
./targets/target-950pr/build.sh --save artifacts/vllm-ascend-950pr-x86_64-offline.tar.gz
```

or by hand, streaming straight into `pigz` so the uncompressed 12.8 GB tar never
touches disk:

```bash
docker save vllm-ascend-950pr:x86_64-offline | pigz -p "$(nproc)" > artifacts/vllm-ascend-950pr-x86_64-offline.tar.gz
```

```bash
sha256sum artifacts/vllm-ascend-950pr-x86_64-offline.tar.gz
```

---

## Phase 3 — deploy on an Ascend 950 host

### 3.1 Transfer and load

Verify the archive **on the destination** before loading it — a copy from WSL's
ext4 across a 9p/drvfs boundary is exactly where truncation hides:

```bash
sha256sum vllm-ascend-950pr-x86_64-offline.tar.gz
```

```bash
docker load < vllm-ascend-950pr-x86_64-offline.tar.gz
```

```bash
docker image ls vllm-ascend-950pr
```

`docker load` reads gzip natively — no separate decompression step, and no need
for 12 GB of scratch space.

The target host needs a Docker daemon and the Ascend **driver** (a host package,
never shipped in an image). Nothing else.

### 3.2 Device nodes and mounts

| Node | Role |
|---|---|
| `/dev/davinci0` … `N` | compute devices — one `--device` per NPU exposed |
| `/dev/davinci_manager` | device management |
| `/dev/devmm_svm` | shared virtual memory |
| `/dev/hisi_hdc` | host-device communication |

The three control nodes are **as mandatory as the compute device**. Without
them the runtime cannot open a context and the failure surfaces much later as an
opaque ACL error. Each `--device` also adds the corresponding device-cgroup
allow rule; under a restricted runtime, all four node classes must be permitted.

Four host paths are bind-mounted read-only alongside them:
`/usr/local/Ascend/driver`, `/usr/local/dcmi`, `/usr/local/bin/npu-smi` and
`/etc/ascend_install.info`. `LD_LIBRARY_PATH` puts the driver's `lib64` first,
so a real host driver always wins over anything staged in the image.

### 3.3 Production inference container

```bash
docker run -d --restart unless-stopped --name vllm-ascend-950pr --device /dev/davinci0 --device /dev/davinci_manager --device /dev/devmm_svm --device /dev/hisi_hdc -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro -v /usr/local/dcmi:/usr/local/dcmi:ro -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi:ro -v /etc/ascend_install.info:/etc/ascend_install.info:ro -v /models:/models:ro -e MODEL=/models/Qwen2.5-7B-Instruct -p 8000:8000 --shm-size=1g vllm-ascend-950pr:x86_64-offline
```

For several NPUs, repeat `--device /dev/davinciN`; the entrypoint derives
`ASCEND_RT_VISIBLE_DEVICES` and `--tensor-parallel-size` from what it finds.
`--shm-size=1g` matters once tensor parallelism is in play — vLLM's workers
communicate through shared memory and Docker's 64 MB default is not enough.

```bash
curl http://localhost:8000/v1/models
```

### 3.4 Entrypoint reference

| Command | Effect |
|---|---|
| *(none)* | `serve` |
| `serve [model] [vllm flags…]` | `vllm serve` with the defaults below |
| `verify` | the runtime verification suite |
| anything else | `exec`'d unchanged (`bash`, `python3 …`, `npu-smi info`) |

| Variable | Default |
|---|---|
| `MODEL` | *(required to serve)* — model id or path |
| `PORT` / `HOST` | `8000` / `0.0.0.0` |
| `TENSOR_PARALLEL_SIZE` | number of `/dev/davinci*` found (floored at 1) |
| `VLLM_DTYPE` | **unset** — passed through only if you set it |
| `ASCEND_RT_VISIBLE_DEVICES` | every NPU found |
| `ALLOW_NO_NPU` | `0`; set to `1` to start without an NPU |

Each default applies only when you have not passed the corresponding flag, so
`serve my-model --port 9000` overrides cleanly.

> **`VLLM_DTYPE` is unset here, unlike the 310P.** The 310P has no hardware
> bfloat16 and forces `float16`; a 950 does not need that override, so the
> checkpoint's own dtype is honoured.

### 3.5 Development container

```bash
./targets/target-950pr/run_dev.sh
```

Starts a shell with `--network=none`, passes through every `/dev/davinci*` it
finds (setting `ALLOW_NO_NPU=1` when there are none), bind-mounts the host
driver if present, and mounts the repo, the plugin source, `third_party` and the
payload read-only plus a writable `/work` volume. Every command runs natively —
there is no `qemu-user` in this shell.

Inside, the Ascend C build environment for dev shells:

```bash
. /usr/local/lib/ascend/compiler_env.sh
```

### 3.6 Smoke test

```bash
./targets/target-950pr/run_dev.sh verify
```

or without a checkout on the target host:

```bash
docker run --rm --device /dev/davinci0 --device /dev/davinci_manager --device /dev/devmm_svm --device /dev/hisi_hdc -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro vllm-ascend-950pr:x86_64-offline verify
```

Ten checks: architecture is `x86_64`; Python 3.10; `libascendcl.so` (x86-64 ELF)
and `libhccl.so` both present; `torch`/`torch_npu`/`vllm`/`vllm_ascend` all
import offline; `_build_info.__device_type__` is `A5`; `vllm_ascend_C` was built
into the wheel; `ldd -r` finds no unresolved symbols beyond the Python C API; no
310P stub symbols leaked in; the **ACLNN custom-op package is installed** with
`libcust_opapi.so` alongside it; the `vllm` CLI is on PATH.

The core acceptance check on its own:

```bash
docker run --rm --network=none vllm-ascend-950pr:x86_64-offline python3 -c "import torch, torch_npu, vllm, vllm_ascend; print('ALL RUNTIME IMPORTS SUCCEEDED')"
```

**Hardware-dependent checks report `[INFO]`, never `FAIL`.** Two of them need
silicon, so a build host sees 10/10 with two `[INFO]` markers and a 950 sees
11/11:

* **`import vllm_ascend.vllm_ascend_C`** — with no NPU, CANN's
  `aclrtGetSocName()` returns `NULL`, the runtime builds a `std::string` from it
  and aborts the process before Python sees anything catchable.
* **`vllm serve --help`** — it loads the platform plugin, which imports
  triton-ascend, whose driver queries the NPU architecture at import:
  `SystemError: <built-in function get_arch> returned NULL`.

Neither is a defect in this image; both are properties of the Ascend stack with
no device attached.

---

## Target-specific gotchas

* **`SOC_VERSION` must be lowercase `ascend950dt_9582`.** Every upstream gate is
  the case-sensitive CMake regex `SOC_VERSION MATCHES "ascend950"`, and
  `setup.py` demands a value starting with `ascend950`. `Ascend950PR` is not a
  spelling CANN or `vllm-ascend` recognises anywhere.
* **The kernels library is skipped; the ACLNN ops are not.** Two different
  mechanisms, and conflating them is the mistake this target's docs were
  corrected for. `ascendc_library(vllm_ascend_kernels)` is genuinely gated off
  for `ascend950`, so there is no `libvllm_ascend_kernels.so`; `build_aclnn.sh`
  builds 27 ops anyway — `MlaPrologV3` and `ChunkKdaFwd` among them — and that
  package is the largest single product of the image. See
  [docs/target-950pr-x86_64.md §5](../../docs/target-950pr-x86_64.md).
* **`vllm_ascend/utils.py` still says "in ASCEND950 chip, we temporarily disable
  all custom ops".** That comment describes the `vllm_ascend_C` op list only,
  not the ACLNN package the same tree builds.
* **The public toolkit is an incomplete slice** — 26 missing `lib64` libraries,
  three of them load-bearing. See Phase 1.
* **`setuptools-scm` shells out to `git` during `bdist_wheel`.** Stage 6 deletes
  `.git` from its *copy* of the tree; the version comes from
  `SETUPTOOLS_SCM_PRETEND_VERSION`.
* **NVIDIA `triton` shadows `triton-ascend`.** Both install a module named
  `triton`. Stage 5 uninstalls NVIDIA's, installs `triton-ascend` with
  `--no-deps`, and asserts which one won before the build may continue.
* **A wheel-only wheelhouse.** Everything is downloaded with
  `--only-binary=:all:`, so the offline install never compiles an sdist.

---

## See also

* [docs/target-950pr-x86_64.md](../../docs/target-950pr-x86_64.md) — release matrix, build flags, operator coverage, measured results
* [docs/DEV_HANDOFF_ASCEND_OPS.md](../../docs/DEV_HANDOFF_ASCEND_OPS.md) — the ACLNN op build in detail
* [../../README.md](../../README.md) — repository overview and target comparison
* [../target-310p/README.md](../target-310p/README.md) — the emulated AArch64 sibling
* [docs/repository-layout.md](../../docs/repository-layout.md) — what belongs where
