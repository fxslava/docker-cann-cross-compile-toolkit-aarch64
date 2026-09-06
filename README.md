# Air-Gapped `vllm-ascend` Inference Images for Huawei Ascend

Reproducible, **100% offline** Docker images that run `vllm serve` on Huawei
Ascend NPUs. Every image is assembled with `--network=none` from a payload
staged beforehand, carries a complete CANN toolkit, and contains **zero
NVIDIA/CUDA artefacts** — a property that is enforced at four independent points
rather than assumed.

Two targets are built today, and they diverge in almost every dimension that
matters:

* **`targets/target-310p/`** — Ascend 310P3, `linux/arm64`.
  Built on an x86_64 host **under QEMU emulation** (`docker buildx` + `binfmt`).
* **`targets/target-950pr/`** — Ascend 950 (A5 / DaVinci v3), `linux/amd64`.
  Built **natively** on x86_64, compiling 27 ACLNN custom ops (493 kernel
  binaries) in the process.

Both are driven through the same four commands. Nothing below is aspirational:
every number is measured, and the commands are the ones the scripts actually
run.

---

## Contents

1. [What this repository produces](#1-what-this-repository-produces)
2. [Target comparison matrix](#2-target-comparison-matrix)
3. [The unified 4-point lifecycle interface](#3-the-unified-4-point-lifecycle-interface)
4. [Host prerequisites](#4-host-prerequisites)
5. [Phase 1 — online provisioning](#phase-1--online-provisioning)
6. [Phase 2 — offline air-gapped build](#phase-2--offline-air-gapped-build)
7. [Phase 3 — deployment on the target machine](#phase-3--deployment-on-the-target-machine)
8. [Repository layout](#8-repository-layout)
9. [The zero-CUDA guarantee](#9-the-zero-cuda-guarantee)
10. [Windows / WSL 2 operator notes](#10-windows--wsl-2-operator-notes)
11. [Troubleshooting index](#11-troubleshooting-index)
12. [Document index](#12-document-index)

---

## 1. What this repository produces

Each target produces **one deployable image** containing CANN, PyTorch,
`torch_npu`, vLLM and the `vllm-ascend` plugin compiled for a specific Ascend
SoC — exported as a single `.tar.gz` that can be carried onto an air-gapped
server and `docker load`ed.

The design rests on three rules:

**1. Exactly one networked step.** `targets/<target>/provision.sh` is the only
script in this repository that touches the network. It stages `deps/<target>/`.
Everything afterwards runs offline.

**2. The build proves its own offline-ness.** `build.sh` passes
`--network=none` to `docker buildx build`, which applies to every `RUN`
instruction. A successful build is therefore *proof* that the payload is
complete — not a claim about it. (Image resolution is not a `RUN` step, so
BuildKit may still fetch the base image and its own frontend from a registry;
pre-pull them on a disconnected builder, see [Phase 2](#phase-2--offline-air-gapped-build).)

**3. No CUDA reaches an Ascend image.** PyPI's `torch` is a CUDA build on both
`x86_64` and `aarch64`. An unconstrained resolve pulls gigabytes of `nvidia-*`
wheels that an NPU cannot use and that **shadow the CPU build `torch_npu` is
compiled against**. See [§9](#9-the-zero-cuda-guarantee).

---

## 2. Target comparison matrix

| | `targets/target-310p` | `targets/target-950pr` |
|---|---|---|
| **Target SoC** | Ascend 310P3 (Atlas 300I, A1 / edge) | Ascend 950 (Atlas 350) |
| **Device family** (`_build_info.__device_type__`) | `_310P` | `A5` |
| **AI Core** | `dav-m200` | `dav-v300` — *unverified against CANN 9.1.0's own tables* |
| **`SOC_VERSION`** | `ascend310p3` | `ascend950dt_9582` |
| **Image platform** | `linux/arm64` | `linux/amd64` |
| **Host architecture** | x86_64 | x86_64 |
| **Build strategy** | **Cross / emulated** — QEMU `binfmt`, plus a host-arch CANN unpacker stage | **Native** — no QEMU, no binfmt, no emulation tax |
| **OS / interpreter** | Ubuntu 22.04 (jammy), Python 3.10 | Ubuntu 22.04 (jammy), Python 3.10 |
| **CANN** | 8.5.0 toolkit | 9.1.0 toolkit **+ NNAL/ATB** |
| **torch / torch_npu** | 2.8.0+cpu / 2.8.0.post2 | 2.10.0+cpu / 2.10.0.post4 |
| **vLLM / vllm-ascend** | v0.13.0 / v0.13.0 (**patched**) | v0.27.1 / `main` (**no patches**) |
| **Triton** | — | `triton-ascend` 3.2.2 (replaces NVIDIA triton) |
| **Kernel compilation scope** | `ascendc_library(vllm_ascend_kernels)` **is** built; bf16/`PIPE_FIX` kernels excluded by a local patch. **No ACLNN custom-op package.** | `vllm_ascend_kernels` **skipped** by upstream's `ascend950` CMake gate; instead `csrc/build_aclnn.sh` builds **27 ACLNN ops → 493 kernel binaries** via `ccec`/`bisheng` |
| **Patches applied** | 1 (`patches/0001-…-ascend310p-kernel-gates.patch`) | none, by design — `build.sh` refuses to start if any appear |
| **Cold build** | **745 s** (~12.5 min) | **95 m 20 s** (~88 min of it is the kernel compile — it *is* the build) |
| **Warm rebuild** | ~6 min (mostly the wheel) | ~7 s if the edit lands after the kernel stage |
| **Payload size** | ~2 GB in `deps/` (CANN alone is 1.1 GB) | 3.8 GB in `deps/950pr-x86_64/` |
| **Image size** | 8.03 GB (2.01 GB content) | 12.8 GB disk (3.25 GB content) |
| **Artefact** | 1,989,784,456 B (1.99 GB) | 3,224,204,628 B (3.1 GB) |
| **Verify on a build host** | **9 / 9** | **10 / 10** |
| **Host RAM** | 8–16 GB adequate | **≥ 24 GB, 32 GB recommended** |
| **Host disk** | ~40 GB | ~50 GB |
| **Runtime dtype** | `--dtype float16` **forced** (no hardware bf16) | checkpoint's own dtype (bf16 supported) |
| **Payload directory** | `deps/` | `deps/950pr-x86_64/` |
| **Deep-dive doc** | [README.aarch64.md](README.aarch64.md) | [docs/target-950pr-x86_64.md](docs/target-950pr-x86_64.md) |
| **Deployment guide** | [targets/target-310p/README.md](targets/target-310p/README.md) | [targets/target-950pr/README.md](targets/target-950pr/README.md) |

> **The payload paths are asymmetric.** The 310P target predates the per-target
> partitioning and still defaults to a bare `deps/`; the 950PR target uses
> `deps/950pr-x86_64/`. Both accept `DEPS_DIR=` to override.

### Why 310P needs emulation and 950PR does not

`vllm-ascend` **cannot be cross-built**. Its `CMakeLists.txt` runs `import
torch` for the version check, and `setup.py` shells out to `pip show torch-npu`
to locate the target headers — so the build-host interpreter and the target
interpreter must be *the same interpreter*. Building the whole image as AArch64
also removes the `op_build` `dlopen` architecture mismatch.

For the 950PR the question does not arise: host and target are both `x86_64`,
so every step runs natively at full speed. The 88 minutes it takes are *real
compute* (493 kernel binaries), not an emulation tax.

The one place the 310P build escapes emulation is the CANN installer: it is a
pure-shell installer spawning thousands of `cp`/`ln`/`chmod` processes, costing
**617 s emulated against ~74 s native**, so stage 0 runs it on the build host's
own architecture and `COPY --from`s the finished tree in. See
[docs/cann-native-unpack.md](docs/cann-native-unpack.md).

---

## 3. The unified 4-point lifecycle interface

Every target exposes the same four entry points, so a target is driven the same
way whatever its architecture:

| # | Entry point | Runs where | Network |
|---|---|---|---|
| 1 | `./targets/<target>/provision.sh` | host + throwaway containers | **yes** — the only networked step |
| 2 | `./targets/<target>/build.sh` | host (`docker buildx`) | **no** — `--network=none` |
| 3 | `./targets/<target>/run_dev.sh` | host → container | no (`DEV_NETWORK=none` by default) |
| 4 | `./targets/<target>/verify_runtime.sh` | **inside the image**, as `docker run <image> verify` | no |

```bash
./targets/target-310p/provision.sh          # or: ./targets/target-950pr/provision.sh
```

```bash
./targets/target-310p/build.sh --save artifacts/vllm-ascend-310p-aarch64-offline.tar.gz
```

```bash
./targets/target-310p/run_dev.sh            # interactive shell in the built image
```

```bash
./targets/target-310p/run_dev.sh verify     # the in-image check suite
```

**Point 4 is a source file, not a host command.** `verify_runtime.sh` is baked
into the image at `/usr/local/bin/verify-runtime.sh` and is invoked as the
`verify` subcommand — either via `run_dev.sh verify` (which handles NPU
passthrough and mounts) or directly:

```bash
docker run --rm --network=none vllm-ascend-310p:aarch64-offline verify
```

### Shared conventions

* **The build context is always the repository root**, never the target
  directory — `deps/` is the payload and must be inside the context. Every path
  inside the Dockerfiles is repo-relative. Always build with `-f`; never `cd`
  into a Dockerfile's own directory.
* **Unrecognised arguments to `build.sh` are forwarded to `buildx`**, so
  `--no-cache`, `--progress=plain`, `--build-arg …` all work.
* **`--save <path>` exports the image**; a `.gz` destination streams through
  `pigz` instead of landing the uncompressed tar on disk.

### Environment variables

Common to both `build.sh` scripts:

| Variable | Default (310P) | Default (950PR) |
|---|---|---|
| `TAG` | `vllm-ascend-310p:aarch64-offline` | `vllm-ascend-950pr:x86_64-offline` |
| `CONTEXT` | repository root | repository root |
| `DEPS_DIR` | `$CONTEXT/deps` | `$CONTEXT/deps/950pr-x86_64` |
| `TARGET_DIR` | `$CONTEXT/targets/target-310p` | `$CONTEXT/targets/target-950pr` |
| `BASE_IMAGE` | `ubuntu:22.04` | `ubuntu:22.04` |
| `UNPACKER_IMAGE` | `python:3.10-slim` | *(not used — native build)* |
| `CANN_VERSION` | `8.5.0` | `9.1.0` |
| `SOC_VERSION` | `ascend310p3` (Dockerfile `ARG`) | `ascend950dt_9582` |

Provisioning knobs are listed per target in
[Phase 1](#phase-1--online-provisioning).

---

## 4. Host prerequisites

### Operating system

* **Linux x86_64**, or **WSL 2 running Ubuntu 22.04** on Windows 10/11.
* Work inside the **WSL 2 native filesystem** (`~/…`), never on `/mnt/c` or
  `/mnt/d`. The build context is several GB and the 9P/drvfs mount makes every
  layer measurably slower. The one exception is `artifacts/`, which
  deliberately lives on the Windows drive so archives survive
  `wsl --shutdown` — see [docs/repository-layout.md](docs/repository-layout.md).

### Docker

* **Docker Engine 20.10+ with BuildKit.** `docker buildx` must be present;
  `build.sh` calls `docker buildx inspect --bootstrap` and refuses to run if the
  required platform is absent.
* Export `DOCKER_BUILDKIT=1` if you invoke `docker build` by hand (the
  `builders/` image is built that way). `build.sh` uses `docker buildx build`,
  which is BuildKit unconditionally.

```bash
export DOCKER_BUILDKIT=1
```

### `binfmt` registration — **310P only**

The 310P image is `linux/arm64`. On an x86_64 host every one of its `RUN` steps
executes under `qemu-aarch64`, which the host kernel must be told about:

```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

Verify — the `F` (fix binary) flag is the important part, because it is what
lets the handler work inside a container that does not itself ship
`qemu-aarch64-static`:

```bash
cat /proc/sys/fs/binfmt_misc/qemu-aarch64
```

```text
enabled
interpreter /usr/bin/qemu-aarch64-static
flags: F
```

Then confirm an arm64 container actually runs:

```bash
docker run --rm --platform linux/arm64 arm64v8/ubuntu:22.04 uname -m
```

This must print `aarch64`. **The registration does not survive
`wsl --shutdown`** — both `provision.sh` and `build.sh` re-register
automatically if the handler has gone, but a bare `docker run --platform
linux/arm64` will fail with `exec format error` until it is back.

The 950PR target needs none of this and never registers binfmt.

### Tooling

`bash`, `git`, `curl`, `wget`, `python3`, `sha256sum`, `stat`, `tar`, and
**`pigz`** (required by `build.sh --save *.gz`):

```bash
sudo apt-get install -y pigz
```

### Disk and memory

| | 310P | 950PR |
|---|---|---|
| `deps/` payload | ~2 GB | 3.8 GB |
| Image on disk | 8.03 GB | 12.8 GB |
| BuildKit cache | ~10–20 GB | ~15–25 GB |
| Exported artefact | 1.99 GB | 3.1 GB |
| **Practical free space** | **~40 GB** | **~50 GB** |
| **RAM** | 8–16 GB | **≥ 24 GB (32 GB recommended)** |
| Cores | any (emulation-bound) | 12+ recommended; the measured 88 min was on 12 |

The 950PR RAM figure is driven by the ACLNN kernel compile: `ninja` runs
`bisheng`/`ccec` across all cores and each kernel translation unit is
memory-hungry. Under-provisioning RAM here manifests as the OOM killer
terminating a compiler mid-stage, roughly an hour in.

---

## Phase 1 — online provisioning

**Run this on a connected machine.** It is the only step that uses the network.

```bash
./targets/target-310p/provision.sh
```

```bash
./targets/target-950pr/provision.sh
```

Both are **idempotent**: an artefact already staged and complete is skipped, a
partial download resumes. Re-running after an interruption is always safe.

### What lands where

**310P → `deps/`** (override with a positional argument or `DEPS_DIR`):

| Path | Contents |
|---|---|
| `Ascend-cann-toolkit_8.5.0_linux-aarch64.run` | CANN toolkit, ~1.1 GB, SHA-256 verified |
| `cann_extra/` | `libhccl.so` and friends, lifted from the vendor CANN image |
| `apt_debs/` | arm64 `.deb` closure of `packages.aarch64.txt` + `Packages.gz` index |
| `python_wheels/` | cp310 / manylinux-aarch64 wheelhouse, including the built vLLM wheel |
| `src/vllm-ascend/` | plugin checkout **including the `catlass` submodule** |
| `src/vllm/` | vLLM source (only when its wheel still has to be built) |
| `third_party/` | ACLNN CMake archives (`pkg/`, `json/include/`, `makeself/`) |
| `MANIFEST.txt` | inventory, printed at the end of the run |

**950PR → `deps/950pr-x86_64/`** (override with `DEPS_DIR`):

| Path | Contents |
|---|---|
| `Ascend-cann-toolkit_9.1.0_linux-x86_64.run` | 1,298,337,341 B, SHA-256 pinned in `deps.manifest` |
| `Ascend-cann-nnal_9.1.0_linux-x86_64.run` | 572,750,476 B — this is where **ATB** lives |
| `cann_extra/lib64/` | **26 libraries the standalone toolkit omits** |
| `apt_debs/` | amd64 jammy `.deb` closure + index |
| `python_wheels/` | cp310 x86_64 wheelhouse + the built vLLM wheel |
| `src/vllm-ascend/` | codeload tarball + the `catlass` submodule staged separately |
| `src/vllm/` | PyPI sdist for v0.27.1 |
| `third_party/` | abseil-cpp, protobuf, nlohmann/json for the ACLNN build |

### The 950PR provisioner runs in stages

```bash
./targets/target-950pr/provision.sh cann cann_extra src thirdparty debs vllm wheels verify
```

With no arguments it runs all eight in that order. Naming a subset re-runs only
those stages — useful when one endpoint was down:

```bash
./targets/target-950pr/provision.sh wheels verify
```

### The multi-stream range downloader

Large artefacts are fetched by `common/scripts/fetch.sh`, which exists because
of two measured failure modes:

* **`curl --retry` combined with `-C -` restarts a dropped transfer at byte 0
  and truncates the file already on disk** — measured cost, 96 MB of a 1.3 GB
  toolkit. Every attempt is therefore a *fresh* curl resuming from the current
  file size, so progress is monotonic.
* **Per-host connection policy differs wildly.** Huawei OBS serves 371 KB/s on
  one connection and 4.3 MB/s over 8; `quay.io` blobs, 2 MB/s versus 20 MB/s.
  But `files.pythonhosted.org` (Fastly) does the reverse — 2.9 MB/s single,
  287 KB/s over 8.

So there are three primitives, and each caller picks deliberately:

| Function | Used for |
|---|---|
| `fetch_parallel <url> <dest> <bytes> [token]` | sized artefacts on range-capable hosts: CANN `.run` files, torch wheels, registry blobs |
| `fetch_resumable <url> <dest> <bytes\|0>` | sources of undeclared length: codeload tarballs |
| `fetch_once <url> <dest>` | immutable release artefacts where non-empty means complete |

Chunk count is `CONNS`, default 8:

```bash
CONNS=4 ./targets/target-950pr/provision.sh cann
```

**pip is deliberately left on a single stream** against PyPI, because parallel
chunking makes Fastly slower, not faster.

### `cann_extra` — the libraries Huawei does not publish

**The publicly downloadable CANN toolkit is not a complete CANN install.** For
9.1.0, its `lib64` holds 150 shared objects against the 176 in Huawei's own
image for this SoC. Three of the twenty-six missing ones are load-bearing:

| Library | Why the build or runtime needs it |
|---|---|
| `libopapi.so` | `vllm-ascend` puts `opapi` in `VLLM_ASCEND_C_COMMON_LIBS` for **every** SoC; without it the link dies on `cannot find -lopapi` |
| `libopapi_math.so` | the compiled custom-op package refuses to install without it (`Shared library validation failed`) |
| `libhccl.so` | `torch_npu` records it in `DT_NEEDED`; without it a plain `import torch` dies with `undefined symbol: HcclReduceScatter` |

**None is separately downloadable** — probing the OBS bucket for
`Ascend-cann-kernels-{950,a5,910b}` and `-nnrt` returns 403 for every name while
the toolkit and NNAL return 206. So they are extracted from the vendor image,
and for the 950PR **without a `docker pull`**: the amd64 manifest is resolved
through the registry API, the single 4.4 GB CANN layer is fetched with the same
parallel range request (~70 s at ~20 MB/s, against ~2 MB/s single-stream), and
only the missing `.so` files are extracted. The 310P target obtains
`libhccl.so` the same way from the CANN 8.5.0 image.

### Seeding from local copies

If you already hold an artefact, point the matching variable at it and the
download is skipped:

```bash
CANN_RUN_SRC=~/cann-build/Ascend-cann-toolkit_8.5.0_linux-aarch64.run \
VLLM_WHEEL=~/vllm-build/dist/vllm-0.13.0+empty-cp310-cp310-manylinux2014_aarch64.whl \
VLLM_SRC=~/vllm-build/vllm VLLM_ASCEND_SRC=~/vllm-build/vllm-ascend \
./targets/target-310p/provision.sh ./deps
```

| Variable | Target | Effect |
|---|---|---|
| `CANN_RUN_SRC` | 310P | copy the CANN `.run` instead of downloading |
| `VLLM_WHEEL` / `VLLM_SRC` / `VLLM_ASCEND_SRC` | 310P | seed the wheel or the checkouts |
| `CANN_IMAGE` / `ARM_BASE` | 310P | vendor image for `cann_extra`; emulated base |
| `VENDOR_IMAGE` / `VENDOR_TAG` | 950PR | vendor image the `cann_extra` layer is pulled from |
| `PIP_INDEX_URL` | 950PR | pin the index and skip the reachability probe |
| `PIP_INDEX_FALLBACK` | 950PR | index used when `pypi.org/simple` is unreachable |
| `VLLM_REF` / `VLLM_ASCEND_REF` | both | source refs — **do not move one without the others** |

### Transferring the payload to a disconnected builder

`deps/` is git-ignored and never enters an image layer, so it moves as plain
files:

```bash
tar -C deps -cf - . | pigz -p "$(nproc)" > /mnt/d/transfer/deps-950pr.tar.gz
```

On the builder, restore it and let `build.sh`'s preflight confirm completeness —
for the 950PR that check is row-by-row against
[`targets/target-950pr/deps.manifest`](targets/target-950pr/deps.manifest),
which pins sizes and SHA-256 for the CANN artefacts.

---

## Phase 2 — offline air-gapped build

### The command

```bash
./targets/target-950pr/build.sh
```

which wraps exactly this:

```bash
docker buildx build \
    --platform linux/amd64 \
    --network=none \
    --progress=plain \
    --build-arg BASE_IMAGE=ubuntu:22.04 \
    --build-arg CANN_VERSION=9.1.0 \
    --build-arg SOC_VERSION=ascend950dt_9582 \
    -f targets/target-950pr/Dockerfile.x86_64 \
    -t vllm-ascend-950pr:x86_64-offline \
    --load \
    .
```

and for the 310P:

```bash
docker buildx build \
    --platform linux/arm64 \
    --network=none \
    --progress=plain \
    --build-arg BASE_IMAGE=ubuntu:22.04 \
    --build-arg UNPACKER_IMAGE=python:3.10-slim \
    -f targets/target-310p/Dockerfile.aarch64 \
    -t vllm-ascend-310p:aarch64-offline \
    --load \
    .
```

### What `--network=none` does and does not cover

It governs **`RUN` steps only**. Image resolution is not a `RUN` step, so
BuildKit can still reach a registry for the base image and its own dockerfile
frontend. On a builder that is going offline, cache them first:

```bash
docker pull docker/dockerfile:1.7
```

```bash
docker pull --platform linux/amd64 ubuntu:22.04
```

> **Do not run `docker pull --platform linux/arm64 ubuntu:22.04` on an x86_64
> builder.** It *replaces* the local `ubuntu:22.04` tag with the arm64 image and
> breaks the x86_64 builder image. Pre-pull `arm64v8/ubuntu:22.04` and pass it
> through instead:
>
> ```bash
> BASE_IMAGE=arm64v8/ubuntu:22.04 ./targets/target-310p/build.sh
> ```

### Preflight — what `build.sh` refuses to start without

Both scripts fail loudly *before* the build rather than hours into it:

| Check | 310P | 950PR |
|---|---|---|
| `docker` on PATH | ✓ | ✓ |
| `binfmt` handler registered (auto-registers) | ✓ | — |
| `buildx` offers the platform | `linux/arm64` | `linux/amd64` |
| Payload complete | CANN `.run`, `apt_debs/Packages.gz`, vLLM wheel, `vllm-ascend` + catlass | every row of `deps.manifest`, sizes included |
| Patch set present / absent | **must** contain `patches/*.patch` | **must not** — refuses if any exist |
| `SOC_VERSION` case | — | must start with lowercase `ascend950` |
| CUDA gate | — | no `nvidia_*`/`cudnn`/`cublas` wheels; torch must be `+cpu` |

The `SOC_VERSION` case check is not pedantry. `vllm-ascend` gates every 950 code
path on the CMake regex `SOC_VERSION MATCHES "ascend950"`, which is
**case-sensitive**, and `setup.py` demands a value starting with `ascend950`.
The vendor spelling `Ascend950PR` matches nothing and produces a
wrong-but-quiet build.

### Caching: how not to lose 88 minutes

BuildKit keys a layer on **the literal command string plus the content of its
mounts**. That single fact drives every caching rule here.

For the 950PR, stage 6 (the `vllm-ascend` build) compiles 493 kernel binaries
and takes ~88 minutes. It is invalidated by:

* any edit to that `RUN`'s command text — **including a comment inside it**;
* a content change in anything it mounts: `deps/950pr-x86_64/python_wheels`,
  `deps/950pr-x86_64/third_party`, `deps/950pr-x86_64/src/vllm-ascend`;
* any change to a stage *above* it.

It is **not** invalidated by edits to anything that lands after it. The
`entrypoint.sh` / `verify_runtime.sh` / `compiler_env.sh` `COPY` lines sit at
stage 8 deliberately, so:

```bash
./targets/target-950pr/build.sh
```

rebuilds in **~7 seconds** after a `verify_runtime.sh` edit.

Practical rules:

* **Batch your edits to the kernel stage.** Changing three things one at a time
  costs 4½ hours; changing them together costs 88 minutes.
* **Never reference an external script from that `RUN`.** This is why
  `common/patches/cmake_fetchcontent_local.sh` is *not* called from the ACLNN
  compile step and its logic is inlined in both Dockerfiles instead — a mount
  reference there would tie a 90-minute layer to a file people edit.
* **Do not re-run `provision.sh` before a rebuild unless you need to.** Adding
  a wheel to `python_wheels/` changes the mount digest and invalidates the
  install *and* kernel stages.
* **`docker image rm <tag>` does not evict the build cache.** Removing the tag
  and rebuilding is fast and safe.
* **`--no-cache` and `docker builder prune -a` do.** Use them only when you
  actually want a cold-build measurement.

A deliberately cold build, for regression measurement:

```bash
docker builder prune -a -f && docker system prune -f
```

then rebuild and compare against the baselines in the matrix (745 s for the
310P; 95 m 20 s for the 950PR, of which 88 m 30 s is the kernel stage).

> **The 950PR kernel stage looks like a hang and is not.** BuildKit buffers that
> stage's log, and the last ~10 `MlaPrologV3_*` kernels alone take ~30 minutes.
> Check `pgrep bisheng` on the host rather than assuming it is stuck.

### Export for air-gapped transfer

```bash
./targets/target-950pr/build.sh --save artifacts/vllm-ascend-950pr-x86_64-offline.tar.gz
```

A `.gz` destination streams `docker save` straight through `pigz` so the
uncompressed multi-GB tar never touches the disk. By hand:

```bash
docker save vllm-ascend-950pr:x86_64-offline | pigz -p "$(nproc)" > artifacts/vllm-ascend-950pr-x86_64-offline.tar.gz
```

```bash
sha256sum artifacts/vllm-ascend-950pr-x86_64-offline.tar.gz
```

`build.sh --save` prints the size and SHA-256 for you. **Record it** — it is
what you verify on the far side of the air gap.

`artifacts/` is git-ignored, excluded from the Docker build context by
`.dockerignore`, and lives on the Windows workspace drive so archives survive a
`wsl --shutdown` or a `docker system prune`.

> **Cross-filesystem integrity.** Copying from WSL's ext4 to `/mnt/d` crosses a
> 9p/drvfs boundary. Always verify the SHA-256 **on the destination**, and
> prefer `cp` + verify + `rm` over `mv`: a cross-filesystem `mv` is a
> copy-then-delete internally, so an interruption can leave you with neither
> copy of something that took 95 minutes to build.

---

## Phase 3 — deployment on the target machine

The target host needs **a Docker daemon and the Ascend driver**. The driver is a
host package and is never shipped in an image — the image ships an empty
`/usr/local/Ascend/driver` for the host's tree to be bind-mounted over.

### 3.1 Transfer and load

Copy the archive across (scp, USB, whatever the air gap allows), then verify it
landed intact before doing anything else:

```bash
sha256sum vllm-ascend-950pr-x86_64-offline.tar.gz
```

```bash
docker load < vllm-ascend-950pr-x86_64-offline.tar.gz
```

```bash
docker image ls vllm-ascend-950pr
```

`docker load` reads gzip natively, so there is no separate decompression step
and no need for 12 GB of scratch space.

### 3.2 Device nodes and driver mounts

The container needs **compute device nodes plus three control nodes**. The
control nodes are as mandatory as the compute device: without them the runtime
cannot open a context, and the failure surfaces much later as an opaque ACL
error.

| Node | Role |
|---|---|
| `/dev/davinci0` … `/dev/davinciN` | the compute devices — one `--device` per NPU you expose |
| `/dev/davinci_manager` | device management |
| `/dev/devmm_svm` | shared virtual memory |
| `/dev/hisi_hdc` | host-device communication |

Each `--device` does two things at once: it creates the node inside the
container **and** adds an allow rule to the container's device cgroup
(`c <major>:<minor> rwm`). If your site runs a restricted runtime or a custom
`--device-cgroup-rule` policy, all four node classes must be permitted, or the
open succeeds and the first ACL call fails.

Alongside the nodes, four host paths are bind-mounted read-only:

| Host path | Why |
|---|---|
| `/usr/local/Ascend/driver` | the driver libraries (`libascend_hal.so` and friends) |
| `/usr/local/dcmi` | device management interface |
| `/usr/local/bin/npu-smi` | the `npu-smi` tool the entrypoint calls |
| `/etc/ascend_install.info` | driver install metadata the runtime reads |

`LD_LIBRARY_PATH` in both images puts `/usr/local/Ascend/driver/lib64` **first**,
so a real host driver always wins over anything staged in the image.

### 3.3 Production inference container

```bash
docker run -d --restart unless-stopped \
    --name vllm-ascend-950pr \
    --device /dev/davinci0 \
    --device /dev/davinci_manager \
    --device /dev/devmm_svm \
    --device /dev/hisi_hdc \
    -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
    -v /usr/local/dcmi:/usr/local/dcmi:ro \
    -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi:ro \
    -v /etc/ascend_install.info:/etc/ascend_install.info:ro \
    -v /models:/models:ro \
    -e MODEL=/models/Qwen2.5-7B-Instruct \
    -p 8000:8000 \
    --shm-size=1g \
    vllm-ascend-950pr:x86_64-offline
```

For the 310P, swap the image tag and add `--platform linux/arm64` if the host is
not itself AArch64. For several NPUs, repeat `--device /dev/davinciN`
(`davinci0`, `davinci1`, …); the entrypoint sets `ASCEND_RT_VISIBLE_DEVICES` and
`--tensor-parallel-size` from what it finds.

`--shm-size=1g` matters once tensor parallelism is in play: vLLM's workers
communicate through shared memory and Docker's 64 MB default is not enough.

Then:

```bash
curl http://localhost:8000/v1/models
```

```bash
curl http://localhost:8000/v1/completions -H 'Content-Type: application/json' -d '{"model": "/models/Qwen2.5-7B-Instruct", "prompt": "Hello", "max_tokens": 32}'
```

### 3.4 The entrypoint contract

Both images share the same dispatch:

| Command | Effect |
|---|---|
| *(none)* | `serve` |
| `serve [model] [vllm flags…]` | `vllm serve` with the defaults below |
| `verify` | the in-image runtime verification suite |
| anything else | `exec`'d unchanged (`bash`, `python3 …`, `npu-smi info`) |

| Variable | 310P default | 950PR default |
|---|---|---|
| `MODEL` | *(required to serve)* | *(required to serve)* |
| `PORT` / `HOST` | `8000` / `0.0.0.0` | `8000` / `0.0.0.0` |
| `TENSOR_PARALLEL_SIZE` | number of `/dev/davinci*` found | number of `/dev/davinci*` found |
| `VLLM_DTYPE` | **`float16` forced** | passed through only if set |
| `ASCEND_RT_VISIBLE_DEVICES` | every NPU found | every NPU found |
| `ALLOW_NO_NPU` | `0` | `0` |
| `NO_JEMALLOC` | — | `0` (jemalloc is `LD_PRELOAD`ed) |

Each default applies only when you have not passed the corresponding flag
yourself, so `serve my-model --dtype bfloat16 --port 9000` overrides cleanly.

**`float16` is forced on the 310P on purpose:** `dav-m200` has no hardware
bfloat16, and most checkpoints declare `bfloat16` in `config.json`, so an
unqualified `vllm serve` would fail on dtype. **The 950PR forces nothing:**
DaVinci v3 has a bf16 path, so the checkpoint's own dtype is correct and
overriding it would degrade quality silently.

### 3.5 Development container

With a repository checkout on the host:

```bash
./targets/target-950pr/run_dev.sh
```

It starts an interactive shell with `--network=none`, passes through every
`/dev/davinci*` it finds (setting `ALLOW_NO_NPU=1` when there are none),
bind-mounts the host driver if present, and mounts:

| Mount | Contents |
|---|---|
| `/repo` (ro) | the checkout, for editing scripts against a live image |
| `/src/vllm-ascend` (ro) | plugin source, for out-of-image kernel work |
| `/third_party` (ro) | the archives CMake would otherwise fetch |
| `/patches` (ro) | `common/patches`, incl. `cmake_fetchcontent_local.sh` |
| `/work` (rw) | a named volume, scratch |

Inside, `. /usr/local/lib/ascend/compiler_env.sh` sets up the Ascend C build
environment. Without a checkout, the equivalent is a plain `docker run -it …
<image> bash`.

### 3.6 Post-deployment smoke test

```bash
./targets/target-950pr/run_dev.sh verify
```

or, with no checkout on the target host:

```bash
docker run --rm --device /dev/davinci0 --device /dev/davinci_manager --device /dev/devmm_svm --device /dev/hisi_hdc -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro vllm-ascend-950pr:x86_64-offline verify
```

What the suite asserts:

| # | 310P (9 checks) | 950PR (10 checks) |
|---|---|---|
| 1 | `aarch64` | `x86_64` |
| 2 | Python 3.10 | Python 3.10 / 3.11 / 3.12 |
| 3 | `libascendcl.so` is an AArch64 object | `libascendcl.so` is x86-64 **and** `libhccl.so` present |
| 4 | `set_env.sh` present | offline `torch`/`torch_npu`/`vllm`/`vllm_ascend` imports |
| 5 | offline imports | device family is `A5` |
| 6 | device family is `_310P` | `vllm_ascend_C` built into the wheel |
| 7 | `vllm_ascend_C` built into the wheel | no unresolved symbols beyond the Python C API |
| 8 | no unresolved symbols beyond the Python C API | **no 310P stub symbols** (no 310P patch leaked in) |
| 9 | `vllm` CLI on PATH | ACLNN custom ops installed (`libcust_opapi.so`) |
| 10 | — | `vllm` CLI on PATH |

**Checks that genuinely need hardware are reported as `[INFO]`, never as
failures**, so a clean run on a build host is not a claim that the NPU works —
only that the image is complete. On a host with `/dev/davinci*` the suite
additionally asserts that `vllm_ascend_C` **imports**, taking the 310P to 10 and
the 950PR to 11.

That import is device-gated for a reason that is CANN's, not this repository's:
`libvllm_ascend_kernels.so` registers its device binaries from an ELF
constructor that calls `AscendCheckSoCVersion()`. With no NPU,
`aclrtGetSocName()` returns `NULL`, the check builds a `std::string` from it,
and the process aborts before Python can catch anything:

```text
terminate called after throwing an instance of 'std::logic_error'
  what():  basic_string::_S_construct null not valid
```

For the same class of reason, `vllm serve --help` cannot run on a machine with
no NPU: it loads the platform plugin, which imports `triton-ascend`, whose
driver queries the NPU architecture at import time.

---

## 8. Repository layout

```text
<repo>/
├── README.md                        this document
├── README.aarch64.md                310P engineering deep-dive
├── download_deps.sh                 shared SHA-256-verified installer fetch
├── ascend-project.sample.yaml       descriptive manifest of every target
│
├── targets/                         one self-contained scaffold per target
│   ├── target-310p/                 Ascend 310P3, linux/arm64, emulated
│   │   ├── README.md                deployment guide
│   │   ├── Dockerfile.aarch64       provision.sh  build.sh  run_dev.sh
│   │   ├── entrypoint.sh            verify_runtime.sh
│   │   ├── packages.aarch64.txt     requirements*.aarch64.txt
│   │   ├── constraints.aarch64.txt  cann_extra.aarch64.txt
│   │   └── patches/                 the 310P kernel-gate patch
│   └── target-950pr/                Ascend 950, linux/amd64, native
│       ├── README.md                deployment guide
│       ├── Dockerfile.x86_64        provision.sh  build.sh  run_dev.sh
│       ├── entrypoint.sh            verify_runtime.sh
│       ├── deps.manifest            what deps/950pr-x86_64/ must contain
│       ├── packages/                requirements/
│       └── constraints.x86_64.txt
│
├── common/                          one implementation per problem
│   ├── scripts/                     fetch, apt archive, wheelhouse, dev shell
│   ├── docker/                      base stage, compiler env, driver plumbing
│   └── patches/                     vendor script shims
│
├── builders/builder-x86_64/         x86_64 → aarch64 cross-compilation image
│   ├── README.md                    its own guide
│   ├── Dockerfile  assemble_sysroot.sh  verify.sh
│
├── docs/                            design notes and build records
├── deps/<target>/                   offline payload                [GIT-IGNORED]
└── artifacts/                       deployable archives            [GIT-IGNORED]
```

**[docs/repository-layout.md](docs/repository-layout.md) is the authority on
what belongs in each directory**, and on the two rules that are easiest to break
by accident:

* `artifacts/` holds only final deployable archives, lives on the Windows
  workspace drive, and is kept out of both git and the Docker build context.
  The `.dockerignore` excludes everything by default (`*`) and re-includes only
  `deps`, `targets`, `builders` and `common` — the context is hashed and
  transferred on *every* build, and a stray 3 GB archive would be too.
* `deps/` is provisioned, never committed, and declared per target.

The test for the layout is: **deleting `deps/` must never lose anything that is
not re-downloadable from the target directory's own declarations.**

Check the enforcement rather than trusting it:

```bash
git status --short
```

---

## 9. The zero-CUDA guarantee

An Ascend image has no use for CUDA, and a CUDA `torch` actively breaks it by
shadowing the CPU build `torch_npu` is compiled against. PyPI's `torch` is a
CUDA build on **both** architectures — on x86_64 it declares fifteen
`nvidia-*-cu12` requirements gated on `platform_machine == "x86_64"`; on aarch64
it targets GH200/Jetson and an unconstrained resolve pulls ~5 GB of
`nvidia-*-cu13` wheels (cuDNN alone is 651 MB).

Four independent gates keep it out:

| # | Gate | Where |
|---|---|---|
| 1 | `torch==<version>+cpu` pinned from `download.pytorch.org` (PyPI publishes no `+cpu`, so the pin is unambiguous) | `constraints.{aarch64,x86_64}.txt` |
| 2 | The wheelhouse resolver refuses to finish a resolve that produced NVIDIA wheels | `common/scripts/fetch_wheels.sh` |
| 3 | Build preflight re-scans the staged payload — catching a wheel dropped in by hand | `targets/<target>/build.sh` |
| 4 | In-image assertion: no `nvidia-*` distribution installed, `torch.__version__` ends in `+cpu`, NVIDIA `triton` absent and `triton-ascend` present | `Dockerfile.*`, and again in `verify_runtime.sh` |

Gate 3 inspects **wheels only**, deliberately. Matching every file matched
thirty Helion autotuning configs in the vLLM source tree
(`vllm/kernels/helion/configs/**/nvidia_h100.json` and friends) — JSON named
after the GPU it was tuned on, not CUDA code, and not even in the build context.

A failure at any gate means a CUDA wheel reached the payload. **Fix the
staging; do not relax the check.**

---

## 10. Windows / WSL 2 operator notes

Docker Engine and the multi-GB payload live **inside** the WSL 2 distro; the
Windows checkout is source only.

### MSYS path translation

Git Bash / MSYS2 rewrites anything that looks like a POSIX path in a command
line into a Windows path before the program sees it, which corrupts every
container-side path you pass to `docker` or `wsl.exe`. Disable it for the
session:

```bash
export MSYS_NO_PATHCONV=1
```

```bash
export MSYS2_ARG_CONV_EXCL='*'
```

Without those, `-v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro` arrives
as `-v C:/Program Files/Git/usr/local/…` and the mount silently points at the
wrong tree.

### Driving WSL from Git Bash

Three further failure modes, all of which produce a *wrong command* rather than
an error:

* **Multi-line inline scripts collapse.** `wsl.exe -- bash -lc '<script>'` loses
  newlines, so `W=~/dir` on one line and `mkdir "$W"` on the next yields an
  empty variable. **Write the script to a file and run the file.**
* **Backslashes are halved in transit.** A heredoc piped through
  `wsl.exe -- tee` turns `\\` into `\`.
* **Session state is volatile.** `/tmp` is emptied and `binfmt_misc` is cleared
  between invocations, so `qemu-aarch64` unregisters itself and
  `--platform linux/arm64` starts failing with `exec format error`. **Register
  binfmt and use it in the same `wsl.exe` invocation**, and keep persistent
  helpers under `$HOME`, not `/tmp`.

Long provisioning runs should be detached inside WSL and logged there
(`setsid nohup … > "$HOME/provision.log" 2>&1 &`), because a shell redirect on
the Git Bash side writes to the Windows temp directory instead.

### Host network quirks worth knowing before blaming the link

* **Dead IPv6 egress with AAAA advertised first.** `curl` does happy-eyeballs
  and falls back instantly, but **pip/urllib3 walks `getaddrinfo` in order and
  waits out its full timeout on the dead address** — indistinguishable from a
  slow network. Every provisioning container in this repository writes
  `precedence ::ffff:0:0/96 100` into `/etc/gai.conf` to prefer IPv4.
* **Endpoints fail independently and briefly.** `pypi.org`'s *index* has timed
  out for minutes while its file CDN, `download.pytorch.org` and the Tsinghua
  mirror all answered. The 950PR provisioner probes and falls back accordingly.

---

## 11. Troubleshooting index

| Symptom | Cause and fix |
|---|---|
| `exec /bin/sh: exec format error` on an arm64 container | `binfmt_misc` cleared (WSL restart). Re-register with `multiarch/qemu-user-static --reset -p yes`. |
| `buildx does not offer linux/arm64` | Same cause; `docker buildx ls` abbreviates the platform column, so check `docker buildx inspect --bootstrap`. |
| Build fails on a missing `deps/` row | Run `provision.sh`. The 950PR preflight names the exact file and its source URL. |
| HTTP 403 from the Huawei OBS bucket | **The version string does not exist** — the bucket answers 403, not 404, for a missing key. Probe with a range request before assuming access issues. |
| CANN `.run` truncated after a dropped transfer | `curl --retry` with `-C -` restarts at byte 0. Use the `fetch.sh` primitives, which resume from the current file size. |
| pip crawls at a few KB/s | Dead IPv6 egress, not the link. See [§10](#10-windows--wsl-2-operator-notes). |
| `import torch` dies with `undefined symbol: HcclReduceScatter` | `libhccl.so` missing — the toolkit does not ship the aggregate. Re-stage `cann_extra`. |
| `/usr/bin/ld: cannot find -lopapi` | Same cause, 950PR: `libopapi.so` is one of the 26 libraries absent from the standalone toolkit. |
| `ldconfig` segfaults during apt (310P) | A `qemu-user` defect during the `libc-bin` trigger; every apt step stubs `ldconfig` out for the duration and restores it after. |
| ACLNN build dies on `Could not resolve: gitcode.com` | `deps/<target>/third_party` was not staged. Re-run the `thirdparty` stage. |
| `git submodule update` attempted during the build | The `catlass` submodule is missing from the staged source. Provisioning stages it explicitly; a codeload tarball carries only the empty directory. |
| The 950PR build appears hung for 30 minutes | It is compiling `MlaPrologV3_*`. BuildKit buffers the stage log — check `pgrep bisheng`. |
| `SystemError: get_arch returned NULL` from `vllm serve --help` | No NPU attached; `triton-ascend`'s driver queries the device at import. Expected on a build host. |
| `basic_string::_S_construct null not valid` on `import vllm_ascend_C` | No NPU attached; CANN's registration constructor aborts. Expected on a build host. |
| An `ACL` error long after container start | A control node was not passed through. All of `/dev/davinci_manager`, `/dev/devmm_svm`, `/dev/hisi_hdc` are mandatory. |
| `vllm serve` fails on dtype (310P) | The checkpoint declares bf16 and `dav-m200` has none. The entrypoint forces `float16`; do not override it. |

---

## 12. Document index

| Document | Covers |
|---|---|
| [targets/target-310p/README.md](targets/target-310p/README.md) | 310P deployment guide — provision, build, deploy, serve |
| [targets/target-950pr/README.md](targets/target-950pr/README.md) | 950PR deployment guide — same, plus the kernel-compile specifics |
| [README.aarch64.md](README.aarch64.md) | 310P engineering deep-dive: why emulation, the version matrix, the patch set, `SOC_VERSION` casing |
| [docs/target-950pr-x86_64.md](docs/target-950pr-x86_64.md) | 950PR deep-dive: how CANN 9.1.0 was established, the staging plan, operator coverage, measured results |
| [docs/repository-layout.md](docs/repository-layout.md) | what belongs in each directory and how it is enforced |
| [docs/soc-build-matrix.md](docs/soc-build-matrix.md) | what has to change to retarget another SoC (310P3 / 910B / 950) |
| [docs/cann-native-unpack.md](docs/cann-native-unpack.md) | the host-architecture CANN unpacker stage and how its output was verified |
| [docs/cross-compilation-analysis.md](docs/cross-compilation-analysis.md) | where the build time goes, with measurements |
| [builders/builder-x86_64/README.md](builders/builder-x86_64/README.md) | the x86_64 → aarch64 cross-compilation toolchain image |
| [ascend-project.sample.yaml](ascend-project.sample.yaml) | every target's release matrix, side by side |
