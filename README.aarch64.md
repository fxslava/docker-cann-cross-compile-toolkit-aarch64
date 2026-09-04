# Native AArch64 Offline Inference Image for Ascend 310P3

A `linux/arm64` Docker image built **on an x86_64 host under QEMU emulation**, carrying CANN 8.5.0, Python 3.10, PyTorch 2.10.0+cpu, `torch_npu`, upstream vLLM and the `vllm-ascend` plugin — all installed from local artefacts with **zero network access**, so the result can be exported to a tar and run on an air-gapped Ascend 310P3 server with a plain `vllm serve`.

This is the sibling of the cross-compilation image documented in [README.md](README.md). They solve different problems:

| | `Dockerfile` (x86_64) | `Dockerfile.aarch64` (this document) |
|---|---|---|
| Image architecture | `linux/amd64` | `linux/arm64` (QEMU-emulated at build time) |
| Purpose | cross-compile Ascend C kernels and ACL apps | run inference on the target |
| CANN | x86_64 toolkit + assembled aarch64 sysroot | aarch64 toolkit installed natively |
| Python stack | host-side tooling only | full torch / torch_npu / vLLM / vllm-ascend |
| Network at build | apt + pip from the internet | **none** (`--network=none`) |

### Why emulate instead of cross-compile

`vllm-ascend` cannot be cross-built. Its `CMakeLists.txt` runs `import torch` to check the version, and its `setup.py` shells out to `pip show torch-npu` to locate the target headers — build-host and target Python must therefore be the *same interpreter*. Building the whole thing as AArch64 also removes the `op_build` `dlopen` architecture mismatch, because `op_build` and the libraries it loads are then both AArch64.

The cost is speed: every instruction runs through `qemu-aarch64`, so the build takes hours rather than minutes.

---

## 1. Prerequisites

* Docker 20.10+ with BuildKit (Docker Engine inside WSL 2, or Docker Desktop).
* `qemu-user-static` + `binfmt-support` active on the host kernel — see below.
* ~40 GB free disk: ~10 GB for `deps/`, the rest for image layers.
* Work inside the WSL 2 native filesystem (`~/...`), **not** on `/mnt/c` or `/mnt/d`. The build context is several GB and the 9P mount makes every layer noticeably slower.

---

## 2. QEMU emulation setup

Register the QEMU interpreters with the host kernel's `binfmt_misc`:

```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

Verify — the `F` flag is the important part, it is what lets the handler work inside a container that does not itself ship `qemu-aarch64-static`:

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

This must print `aarch64`. The registration does **not** survive a WSL restart (`wsl --shutdown`), so re-run it after one; `provision_deps_aarch64.sh` and `build_aarch64.sh` both re-register automatically if the handler is gone.

---

## 3. Provision the offline payload

This is the only step that touches the network. It fills `./deps/` with everything the image build needs.

```bash
./provision_deps_aarch64.sh ./deps
```

| Path | Contents |
|---|---|
| `deps/Ascend-cann-toolkit_8.5.0_linux-aarch64.run` | CANN toolkit, AArch64 (~1.1 GB, SHA-256 verified) |
| `deps/apt_debs/` | arm64 `.deb` closure of `packages.aarch64.txt` + `dpkg-scanpackages` index |
| `deps/python_wheels/` | cp310 / manylinux-aarch64 wheelhouse (torch, torch_npu, vLLM and every transitive dependency) |
| `deps/src/vllm-ascend/` | `vllm-ascend` checkout **including the `catlass` submodule** |
| `deps/MANIFEST.txt` | inventory of the above |

Everything that must be resolved *as* AArch64 runs inside a throwaway `arm64v8/ubuntu:22.04` container:

* **apt** honours `Architecture: arm64` only when it runs on arm64.
* **pip** must evaluate `platform_machine == "aarch64"` markers — vLLM gates `llguidance` and `xgrammar` on exactly that, and pip does not evaluate those markers reliably against a cross `--platform` target.

If you already have some artefacts locally, seed them and skip the downloads:

```bash
CANN_RUN_SRC=~/cann-build/Ascend-cann-toolkit_8.5.0_linux-aarch64.run \
TORCH_WHEEL_SRC=~/cann-build/torch-2.10.0+cpu-cp310-cp310-manylinux_2_28_aarch64.whl \
VLLM_WHEEL=~/vllm-build/dist/vllm-0.27.1+empty-cp310-cp310-manylinux2014_aarch64.whl \
VLLM_ASCEND_SRC=~/vllm-build/vllm-ascend \
./provision_deps_aarch64.sh ./deps
```

### The vLLM wheel is built, not downloaded

vLLM does publish an aarch64 wheel on PyPI, but it is a **CUDA** build. The Ascend backend lives entirely in `vllm-ascend`, so vLLM itself is built with `VLLM_TARGET_DEVICE=empty` — the same thing upstream's `Dockerfile.310p` does. `provision_deps_aarch64.sh` builds that wheel in the emulated container unless you seed one.

### Why `constraints.aarch64.txt` exists

On aarch64 the `torch` wheels on PyPI are CUDA builds targeting GH200/Jetson. vLLM's `compressed-tensors==0.17.0` only asks for `torch>=2.10.0`, so an unconstrained resolve jumps to torch 2.14.0 and pulls in ~5 GB of `nvidia-*-cu13` wheels (cuDNN alone is 651 MB) that an Ascend NPU cannot use and that would shadow the CPU build `torch_npu` is compiled against. Pinning the `+cpu` local-version builds from `download.pytorch.org` keeps the whole CUDA subtree out.

---

## 4. Build the image under emulation

```bash
./build_aarch64.sh
```

which wraps:

```bash
docker buildx build \
    --platform linux/arm64 \
    --network=none \
    -f Dockerfile.aarch64 \
    -t vllm-ascend-310p:aarch64-offline \
    --load \
    .
```

`--network=none` applies to every `RUN` instruction, so a successful build is itself the proof that `deps/` is complete. The only two things fetched from a registry — and only when not already cached — are the arm64 `ubuntu:22.04` base image and the BuildKit dockerfile frontend. Pre-pull them once if the build host is going offline:

```bash
docker pull --platform linux/arm64 ubuntu:22.04
docker pull docker/dockerfile:1.7
```

### What the build does

1. **apt, offline.** `deps/apt_debs` is exposed as a `deb [trusted=yes] file:/debs ./` repository and the packages in `packages.aarch64.txt` are installed as a normal apt transaction.
2. **pip bootstrap, offline.** jammy ships pip 22.0.2, which chokes on `Metadata-Version: 2.4` wheels, so a newer pip is the first thing installed from the wheelhouse.
3. **CANN.** `Ascend-cann-toolkit_8.5.0_linux-aarch64.run --full --quiet --install-path=/usr/local/Ascend --install-for-all`, running natively under emulation. `--full` rather than the narrower `--install` because `vllm-ascend`'s ACLNN custom-op build needs the development/op-package payload.
4. **Python stack**, in three separate `pip install --no-index --find-links=/opt/wheels` transactions (see the note on fastapi below).
5. **`vllm-ascend`**, built from `deps/src/vllm-ascend` for `SOC_VERSION=ascend310p3` and installed.
6. **Driver plumbing** — `HwHiAiUser` and friends, `/var/driver`, `/usr/slog`, `/lib64 -> /lib`.
7. **A build-time import check.** The image cannot be produced unless `import torch, torch_npu, vllm, vllm_ascend` all succeed.

### Why `SOC_VERSION` is lowercase `ascend310p3`

CANN spells the chip `Ascend310P3`, but `vllm-ascend` gates on the value twice with *case-sensitive* matches:

* `CMakeLists.txt`: `if(SOC_VERSION MATCHES "ascend310p.*")` decides to **skip** the `ascendc_library` kernel target — 310P has no MLAPO or `batch_matmul_transpose` support. `Ascend310P3` misses that branch and tries to build kernels the SoC does not have.
* `csrc/build_aclnn.sh`: `[[ "$SOC_VERSION" =~ ^ascend310 ]]` selects the four 310P custom ACLNN ops and sets `SOC_ARG=ascend310p`.

`vllm_ascend/device/hardware.py` lowercases before its own lookup, so `ascend310p3` is accepted everywhere and resolves to device family `_310P`. Same chip, spelling that satisfies every consumer.

### Why three pip transactions

vLLM's metadata declares `fastapi[standard]>=0.133.0`; `vllm-ascend`'s `requirements.txt` declares `fastapi<0.124.0`. Those cannot both hold, so a single resolve simply fails. Upstream's own `Dockerfile.310p` hits the same conflict and lets the later install win — this image does the same, deliberately and with the reason written down.

`vllm-ascend` itself is installed with `--no-build-isolation --no-deps`: its `pyproject.toml` build-system requires `triton-ascend==3.2.2`, which is published only on Huawei's mirror and which upstream uninstalls again immediately afterwards. An isolated build environment would try to fetch it, and there is no network.

---

## 5. Verify

```bash
docker run --rm vllm-ascend-310p:aarch64-offline verify
```

`verify_runtime.sh` checks the architecture, the Python version, the CANN install, the compiled `vllm_ascend_C` extension, and that `vllm_ascend` was built for device family `_310P`. Its core assertion is the acceptance check:

```bash
docker run --rm --network=none vllm-ascend-310p:aarch64-offline \
    python3 -c "import torch; import torch_npu; import vllm; import vllm_ascend; print('ALL RUNTIME IMPORTS SUCCEEDED')"
```

Checks that genuinely need hardware are reported as `[INFO]`, never as failures, so the suite passes on the x86_64 build host too.

---

## 6. Export for air-gapped deployment

```bash
./build_aarch64.sh --save vllm-ascend-310p-aarch64.tar
```

or by hand:

```bash
docker save vllm-ascend-310p:aarch64-offline -o vllm-ascend-310p-aarch64.tar
gzip -1 vllm-ascend-310p-aarch64.tar          # optional, roughly halves it
```

Copy the tar to the target server and load it:

```bash
docker load -i vllm-ascend-310p-aarch64.tar
docker image ls vllm-ascend-310p
```

The tar is self-contained: the target host needs a Docker daemon and the Ascend **driver** (which is a host package, never shipped in an image), nothing else.

---

## 7. Run on an Ascend 310P3 host

The container needs four device nodes and the host's driver tree. `/dev/davinci0` is the compute device — add one `--device` per NPU you want to expose. The other three are control nodes; without them the runtime cannot open a context and the failure surfaces much later as an opaque ACL error.

```bash
docker run -it --rm \
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

For several NPUs, repeat `--device /dev/davinciN` (`davinci0`, `davinci1`, …); the entrypoint sets `ASCEND_RT_VISIBLE_DEVICES` and `--tensor-parallel-size` from what it finds.

Then:

```bash
curl http://localhost:8000/v1/models
curl http://localhost:8000/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{"model": "/models/Qwen2.5-7B-Instruct", "prompt": "Hello", "max_tokens": 32}'
```

### Entrypoint

`entrypoint.sh` sources the CANN environment, enumerates `/dev/davinci*`, warns about missing control nodes or an unmounted host driver, then dispatches:

| Command | Effect |
|---|---|
| *(none)* | `serve` |
| `serve [model] [vllm flags…]` | `vllm serve` with the defaults below |
| `verify` | the runtime verification suite |
| anything else | `exec`'d unchanged (`bash`, `python3 …`, `npu-smi info`) |

| Variable | Default |
|---|---|
| `MODEL` | *(required to serve)* model id or path |
| `PORT` / `HOST` | `8000` / `0.0.0.0` |
| `TENSOR_PARALLEL_SIZE` | number of `/dev/davinci*` found |
| `VLLM_DTYPE` | `float16` |
| `ASCEND_RT_VISIBLE_DEVICES` | every NPU found |
| `ALLOW_NO_NPU` | `0`; set to `1` to start without an NPU |

Each default is only applied when you have not passed the corresponding flag yourself, so `serve my-model --dtype bfloat16 --port 9000` overrides cleanly.

**`float16` is the default on purpose.** Ascend 310P3 has no hardware bfloat16, and most checkpoints declare `bfloat16` in `config.json`, so an unqualified `vllm serve` would fail on dtype.

---

## 8. Repository layout

```text
Dockerfile.aarch64             native AArch64 offline inference image
build_aarch64.sh               preflight + buildx wrapper + docker save
provision_deps_aarch64.sh      fills deps/ (the only networked step)
scripts/fetch_debs.sh          arm64 .deb closure + apt index   (runs in-container)
scripts/fetch_wheels.sh        aarch64 wheelhouse               (runs in-container)
scripts/build_vllm_wheel.sh    vLLM wheel, VLLM_TARGET_DEVICE=empty (in-container)
packages.aarch64.txt           apt package list, shared by provisioning and build
requirements.aarch64.txt       torch stack + build backend pins
requirements-optional.aarch64.txt  best-effort extras (a miss is not fatal)
constraints.aarch64.txt        keeps the resolve on +cpu torch, off CUDA
entrypoint.sh                  NPU detection + vllm serve launcher
verify_runtime.sh              in-image verification suite
deps/                          provisioned payload (git-ignored)
```

---

## 9. Gotchas worth knowing

* **`ldconfig` segfaults under `qemu-user`** while `dpkg` runs the `libc-bin` trigger, which aborts the entire apt transaction. Every apt step in this repo stubs `ldconfig` out for the duration and restores the real binary afterwards.
* **`binfmt_misc` registration is not persistent.** After `wsl --shutdown` you must re-register; both scripts here do it for you.
* **The `catlass` submodule must be present before the build.** `csrc/build_aclnn.sh` runs `git submodule update --init` when `csrc/third_party/catlass/include` is missing — which would need network inside the offline build. `provision_deps_aarch64.sh` clones with `--recurse-submodules` and fails loudly if it is absent.
* **`deps/` is git-ignored.** It is provisioned, not committed: the CANN toolkit alone is 1.1 GB.
* **A wheel-only wheelhouse.** Everything is downloaded with `--only-binary=:all:` so the offline install never has to compile an sdist. Packages with no cp310 aarch64 wheel are listed in `requirements-optional.aarch64.txt`, downloaded one at a time, and recorded in `deps/MANIFEST.txt` when they are missing — none of them is needed for `import vllm_ascend` or for `vllm serve`.
