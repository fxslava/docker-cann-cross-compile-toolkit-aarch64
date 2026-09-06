# `target-310p` — Ascend 310P3 (AArch64) Deployment Guide

Operator guide for the **`linux/arm64` offline inference image** for Huawei
Ascend 310P3. Provision it on a connected machine, build it air-gapped, carry it
to the target server, serve models with `vllm serve`.

For *why* the image is built the way it is — the emulation decision, the version
matrix, the patch set, the `SOC_VERSION` casing — read
[README.aarch64.md](../../README.aarch64.md). This document is the *how*.

| | |
|---|---|
| Image tag | `vllm-ascend-310p:aarch64-offline` |
| Platform | `linux/arm64` |
| Target SoC | Ascend 310P3 (Atlas 300I), AI Core `dav-m200` |
| `SOC_VERSION` | `ascend310p3` (**lowercase**) |
| Device family | `_310P` |
| Base | Ubuntu 22.04, Python 3.10 |
| Stack | CANN 8.5.0 · torch 2.8.0+cpu · torch_npu 2.8.0.post2 · vLLM v0.13.0 · vllm-ascend v0.13.0 |
| Payload | `deps/` (override with `DEPS_DIR`) |
| Build strategy | **QEMU emulation** on an x86_64 host, plus a native CANN unpacker stage |
| Cold build | 745 s (~12.5 min) · warm ~6 min |
| Artefact | 1,989,784,456 B (1.99 GB) from an 8.03 GB image |
| Verify | **9/9** on a build host, 10/10 with an NPU |

---

## The four entry points

```bash
./targets/target-310p/provision.sh      # 1. stage deps/ — the only networked step
```

```bash
./targets/target-310p/build.sh          # 2. build with --network=none
```

```bash
./targets/target-310p/run_dev.sh        # 3. interactive shell in the built image
```

```bash
./targets/target-310p/run_dev.sh verify # 4. the in-image check suite
```

All four are run **from the repository root** — the build context is the root,
never this directory.

---

## Prerequisites

* Docker 20.10+ with BuildKit and `docker buildx`.
* **QEMU `binfmt` registration** (this target only — see below).
* `pigz`, for `--save *.gz`.
* ~40 GB free disk; 8–16 GB RAM is adequate.
* Work inside the WSL 2 native filesystem, not `/mnt/c` or `/mnt/d`.

### QEMU registration

Every `RUN` step of this image executes under `qemu-aarch64`:

```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

```bash
cat /proc/sys/fs/binfmt_misc/qemu-aarch64
```

The `F` (fix binary) flag must be present — it is what lets the handler work
inside a container that does not itself ship `qemu-aarch64-static`. Confirm an
arm64 container actually runs:

```bash
docker run --rm --platform linux/arm64 arm64v8/ubuntu:22.04 uname -m
```

This must print `aarch64`. **The registration does not survive
`wsl --shutdown`.** Both `provision.sh` and `build.sh` re-register it if it has
gone; a bare `docker run --platform linux/arm64` will not.

---

## Phase 1 — provision (online)

```bash
./targets/target-310p/provision.sh
```

Takes an optional payload directory (default `<repo>/deps`):

```bash
./targets/target-310p/provision.sh ~/aarch64-offline/deps
```

### What it stages

| Path | Contents |
|---|---|
| `Ascend-cann-toolkit_8.5.0_linux-aarch64.run` | CANN toolkit, ~1.1 GB, SHA-256 verified by `download_deps.sh` |
| `cann_extra/` | the libraries the toolkit `.run` omits, listed in `cann_extra.aarch64.txt` |
| `apt_debs/` | arm64 `.deb` closure of `packages.aarch64.txt` + `Packages.gz` |
| `python_wheels/` | cp310 aarch64 wheelhouse, including the built vLLM wheel |
| `src/vllm-ascend/` | plugin checkout **with the `catlass` submodule** |
| `src/vllm/` | vLLM source, only when its wheel still has to be built |
| `third_party/` | ACLNN CMake archives (`pkg/`, `json/include/`, `makeself/`) |
| `MANIFEST.txt` | inventory, printed at the end |

### Everything resolves *as* AArch64

Steps that must produce arm64 artefacts run inside a throwaway
`arm64v8/ubuntu:22.04` container under QEMU, because:

* **apt** honours `Architecture: arm64` only when it runs on arm64;
* **pip** must evaluate `platform_machine == "aarch64"` markers — vLLM gates
  `llguidance` and `xgrammar` on exactly that, and pip does not evaluate those
  markers reliably against a cross `--platform` target.

### `libhccl.so` is staged from the vendor image, not the toolkit

The CANN 8.5.0 toolkit ships HCCL split into
`libhccl_{alg,fwk,legacy,plf}.so` and **no aggregate `libhccl.so`** — verified
by extracting all 21 component `.run` files, none of which contains one. But
every `torch_npu` build records `libhccl.so` in `DT_NEEDED`, and torch 2.8
auto-loads the `torch_npu` backend extension, so a plain `import torch` dies
with:

```text
ImportError: libtorch_npu.so: undefined symbol: HcclReduceScatter
```

Huawei's own CANN 8.5.0 image carries the real library at the same version, so
`provision.sh` lifts it from there. The pull is ~4 GB and happens once; nothing
about it reaches the image build, which stays `--network=none`.

### The vLLM wheel is built, not downloaded

vLLM publishes an aarch64 wheel on PyPI, but it is a **CUDA** build. The Ascend
backend lives entirely in `vllm-ascend`, so vLLM itself is built with
`VLLM_TARGET_DEVICE=empty` — exactly what upstream's `Dockerfile.310p` does.
Provisioning builds it under emulation unless you seed one.

### Seeding local copies

```bash
CANN_RUN_SRC=~/cann-build/Ascend-cann-toolkit_8.5.0_linux-aarch64.run \
VLLM_WHEEL=~/vllm-build/dist/vllm-0.13.0+empty-cp310-cp310-manylinux2014_aarch64.whl \
VLLM_SRC=~/vllm-build/vllm VLLM_ASCEND_SRC=~/vllm-build/vllm-ascend \
./targets/target-310p/provision.sh ./deps
```

| Variable | Default | Purpose |
|---|---|---|
| `CANN_RUN_SRC` | — | local CANN `.run` to copy instead of downloading |
| `VLLM_WHEEL` | — | pre-built vLLM wheel |
| `VLLM_SRC` / `VLLM_ASCEND_SRC` | — | local checkouts |
| `CANN_VERSION` | `8.5.0` | toolkit version |
| `CANN_IMAGE` | `quay.io/ascend/cann:8.5.0-310p-ubuntu22.04-py3.11` | source of `cann_extra` |
| `ARM_BASE` | `arm64v8/ubuntu:22.04` | emulated provisioning base |
| `VLLM_TAG` / `VLLM_ASCEND_REF` | `v0.13.0` / `v0.13.0` | source refs — move as a set |

---

## Phase 2 — build (air-gapped)

```bash
./targets/target-310p/build.sh
```

which wraps:

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

`--network=none` applies to every `RUN`, so a successful build **is** the proof
that `deps/` is complete. Three things may still be fetched from a registry, and
only when not already cached: the arm64 `$BASE_IMAGE`, the `$UNPACKER_IMAGE`
used by stage 0, and the BuildKit dockerfile frontend.

### Pre-pulling on a builder that is going offline

```bash
docker pull docker/dockerfile:1.7
```

```bash
docker pull python:3.10-slim
```

```bash
docker pull arm64v8/ubuntu:22.04
```

> **Do not `docker pull --platform linux/arm64 ubuntu:22.04`.** It *replaces*
> the local `ubuntu:22.04` tag with the arm64 image and breaks the x86_64
> builder image. Pass the explicitly-named arm64 image through instead:
>
> ```bash
> BASE_IMAGE=arm64v8/ubuntu:22.04 ./targets/target-310p/build.sh
> ```

### What the build does

| Stage | Step |
|---|---|
| 0 | **CANN installed on the build host's own architecture** and `COPY --from`ed in — 617 s emulated against ~74 s native, the single largest saving in this build |
| 1 | apt from `deps/apt_debs`, exposed as a `deb [trusted=yes] file:/debs ./` repository |
| 2 | pip bootstrap from the wheelhouse (jammy's pip 22.0.2 chokes on `Metadata-Version: 2.4` wheels) |
| 3 | `cann_extra` copied in; `libhccl.so` fallback wired via `common/patches/hccl_devlib_fallback.sh` |
| 4 | environment (`ASCEND_TOOLKIT_HOME`, `LD_LIBRARY_PATH`, `SOC_VERSION`, `ASCEND_AICORE_ARCH=dav-m200`, …) |
| 5 | torch stack, vLLM and the `vllm-ascend` dependency set in **three separate pip transactions** |
| 6 | `vllm-ascend` patched from `patches/`, built for `ascend310p3`, installed |
| 7 | driver plumbing (`HwHiAiUser`, `/var/driver`, `/usr/slog`, `/lib64 -> /lib`) |
| 8 | entrypoint + verify suite, then a build-time import assertion |

The image **cannot be produced** unless `import torch, torch_npu, vllm,
vllm_ascend` all succeed inside it.

### Preflight refuses to start without

* `docker` on PATH and a registered `binfmt` handler (auto-registered);
* `buildx` offering `linux/arm64`;
* **at least one `patches/*.patch`** — `vllm-ascend` v0.13.0 does not build for a
  310P without them, and a missing directory would otherwise surface as an
  opaque mount error hours in;
* the CANN `.run`, `apt_debs/Packages.gz`, a `vllm-*.whl`, `src/vllm-ascend` and
  its `catlass` submodule.

### Caching

BuildKit keys a layer on the literal command string plus its mounts. Stage 6
(the `vllm-ascend` wheel, ~285 s) is the expensive one; the entrypoint and
verify suite are `COPY`ed at stage 8, so editing them rebuilds in seconds.
`docker image rm` does **not** evict the build cache — only `--no-cache` or
`docker builder prune` do.

For a deliberately cold measurement:

```bash
docker builder prune -a -f && docker system prune -f
```

The baseline to regress against is **745 s** end to end, with the dominant steps
being the `vllm-ascend` wheel (285 s), the three pip transactions (259 s), the
CANN install on the host arch (95 s) and offline apt (76 s).

### Export

```bash
./targets/target-310p/build.sh --save artifacts/vllm-ascend-310p-aarch64-offline.tar.gz
```

or by hand, streaming straight into `pigz` so the uncompressed 8 GB tar never
touches disk:

```bash
docker save vllm-ascend-310p:aarch64-offline | pigz -p "$(nproc)" > artifacts/vllm-ascend-310p-aarch64-offline.tar.gz
```

```bash
sha256sum artifacts/vllm-ascend-310p-aarch64-offline.tar.gz
```

The 8.03 GB image compresses to **1.99 GB**.

---

## Phase 3 — deploy on an Ascend 310P3 host

### 3.1 Transfer and load

Verify the archive **on the destination** before loading it — a copy from WSL's
ext4 across a 9p/drvfs boundary is exactly where truncation hides:

```bash
sha256sum vllm-ascend-310p-aarch64-offline.tar.gz
```

```bash
docker load < vllm-ascend-310p-aarch64-offline.tar.gz
```

```bash
docker image ls vllm-ascend-310p
```

`docker load` reads gzip natively — no separate decompression step.

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

### 3.3 Production inference container

```bash
docker run -d --restart unless-stopped \
    --name vllm-ascend-310p \
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
    vllm-ascend-310p:aarch64-offline
```

For several NPUs, repeat `--device /dev/davinciN`; the entrypoint derives
`ASCEND_RT_VISIBLE_DEVICES` and `--tensor-parallel-size` from what it finds.

Add `--platform linux/arm64` if the host running Docker is not itself AArch64
(a build host under QEMU, for instance).

```bash
curl http://localhost:8000/v1/models
```

```bash
curl http://localhost:8000/v1/completions -H 'Content-Type: application/json' -d '{"model": "/models/Qwen2.5-7B-Instruct", "prompt": "Hello", "max_tokens": 32}'
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
| `TENSOR_PARALLEL_SIZE` | number of `/dev/davinci*` found |
| `VLLM_DTYPE` | **`float16`** |
| `ASCEND_RT_VISIBLE_DEVICES` | every NPU found |
| `ALLOW_NO_NPU` | `0`; set to `1` to start without an NPU |

Each default applies only when you have not passed the corresponding flag, so
`serve my-model --port 9000` overrides cleanly.

**`float16` is the default on purpose.** Ascend 310P3 has **no hardware
bfloat16**, and most checkpoints declare `bfloat16` in `config.json`, so an
unqualified `vllm serve` would fail on dtype. Do not override it with
`bfloat16` on this SoC.

### 3.5 Development container

```bash
./targets/target-310p/run_dev.sh
```

Starts a shell with `--network=none`, passes through every `/dev/davinci*` it
finds (setting `ALLOW_NO_NPU=1` when there are none), bind-mounts the host
driver if present, and mounts `/repo`, `/src/vllm-ascend`, `/third_party`,
`/patches` read-only plus a writable `/work` volume.

> On an x86_64 host every command in that shell runs under `qemu-user`, so
> register the binfmt handler first.

Inside:

```bash
. /usr/local/lib/ascend/compiler_env.sh
```

sets up the Ascend C build environment (the image already carries the same
values as `ENV`, so this is for dev shells only).

### 3.6 Smoke test

```bash
./targets/target-310p/run_dev.sh verify
```

or without a checkout on the target host:

```bash
docker run --rm --device /dev/davinci0 --device /dev/davinci_manager --device /dev/devmm_svm --device /dev/hisi_hdc -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro vllm-ascend-310p:aarch64-offline verify
```

Nine checks: architecture is `aarch64`; Python 3.10; `libascendcl.so` present
and AArch64; `set_env.sh` present; `torch`/`torch_npu`/`vllm`/`vllm_ascend` all
import offline; `_build_info.__device_type__` is `_310P`; `vllm_ascend_C` was
built into the wheel; `ldd -r` finds no unresolved symbols beyond the Python C
API; the `vllm` CLI is on PATH.

The core acceptance check on its own:

```bash
docker run --rm --network=none vllm-ascend-310p:aarch64-offline python3 -c "import torch; import torch_npu; import vllm; import vllm_ascend; print('ALL RUNTIME IMPORTS SUCCEEDED')"
```

**Hardware-dependent checks report `[INFO]`, never `FAIL`.** On a host with
`/dev/davinci*` the suite additionally asserts that `vllm_ascend_C` imports,
taking the total to 10. That import cannot be attempted without a device:
`libvllm_ascend_kernels.so` registers its device binaries from an ELF
constructor calling CANN's `AscendCheckSoCVersion()`, and with no NPU
`aclrtGetSocName()` returns `NULL`, so the process aborts before Python sees
anything catchable:

```text
terminate called after throwing an instance of 'std::logic_error'
  what():  basic_string::_S_construct null not valid
```

That is CANN's own generated stub, not a defect in this image.

---

## Target-specific gotchas

* **`ldconfig` segfaults under `qemu-user`** while `dpkg` runs the `libc-bin`
  trigger, aborting the whole apt transaction. Every apt step stubs `ldconfig`
  out for the duration and restores the real binary afterwards.
* **`binfmt_misc` registration is not persistent** across `wsl --shutdown`.
* **The `catlass` submodule must be present before the build.**
  `csrc/build_aclnn.sh` runs `git submodule update --init` when
  `csrc/third_party/catlass/include` is missing — which needs network inside an
  offline build. Provisioning clones with `--recurse-submodules` and fails
  loudly if it is absent.
* **`setuptools-scm` shells out to `git` during `bdist_wheel`**, and rejects the
  provisioning user's checkout as dubious ownership. Stage 6 deletes `.git`
  from its *copy* of the tree; the version comes from
  `SETUPTOOLS_SCM_PRETEND_VERSION`.
* **The patches are not optional.** `vllm-ascend` v0.13.0 cannot compile its
  bf16 and `PIPE_FIX` kernels for a `dav-m200` core; the patch excludes them and
  supplies a stub translation unit so the module still links. Details, per
  kernel, in the patch header and in
  [README.aarch64.md](../../README.aarch64.md).
* **`SOC_VERSION` must be lowercase `ascend310p3`.** `setup.py`'s
  `gen_build_info()` asserts against an all-lowercase dict and writes the device
  family the runtime dispatches on; `ASCEND310P3` fails that assert outright.
* **A wheel-only wheelhouse.** Everything is downloaded with
  `--only-binary=:all:`, so the offline install never compiles an sdist.
  Packages with no cp310 aarch64 wheel live in
  `requirements-optional.aarch64.txt`, are fetched one at a time, and a miss is
  recorded in `MANIFEST.txt` rather than failing the stage — none is needed for
  `import vllm_ascend` or for `vllm serve`.

---

## See also

* [README.aarch64.md](../../README.aarch64.md) — the engineering deep-dive
* [../../README.md](../../README.md) — repository overview and target comparison
* [docs/cann-native-unpack.md](../../docs/cann-native-unpack.md) — stage 0
* [docs/cross-compilation-analysis.md](../../docs/cross-compilation-analysis.md) — where the build time goes
* [docs/soc-build-matrix.md](../../docs/soc-build-matrix.md) — retargeting to another SoC
