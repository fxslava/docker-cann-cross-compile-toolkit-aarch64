# Native AArch64 Offline Inference Image for Ascend 310P3

A `linux/arm64` Docker image built **on an x86_64 host under QEMU emulation**, carrying CANN 8.5.0, Python 3.10, PyTorch 2.8.0+cpu, `torch_npu` 2.8.0.post2, vLLM v0.13.0 and the `vllm-ascend` v0.13.0 plugin — all installed from local artefacts with **zero network access**, so the result can be exported to a tar and run on an air-gapped Ascend 310P3 server with a plain `vllm serve`.

This is the sibling of the cross-compilation image documented in [README.md](README.md). They solve different problems:

| | `docker/builder-x86_64/Dockerfile` | `docker/target-310p/Dockerfile.aarch64` (this document) |
|---|---|---|
| Image architecture | `linux/amd64` | `linux/arm64` (QEMU-emulated at build time) |
| Purpose | cross-compile Ascend C kernels and ACL apps | run inference on the target |
| CANN | x86_64 toolkit + assembled aarch64 sysroot | aarch64 toolkit installed natively |
| Python stack | host-side tooling only | full torch / torch_npu / vLLM / vllm-ascend |
| Network at build | apt + pip from the internet | **none** (`--network=none`) |

### Why emulate instead of cross-compile

`vllm-ascend` cannot be cross-built. Its `CMakeLists.txt` runs `import torch` to check the version, and its `setup.py` shells out to `pip show torch-npu` to locate the target headers — build-host and target Python must therefore be the *same interpreter*. Building the whole thing as AArch64 also removes the `op_build` `dlopen` architecture mismatch, because `op_build` and the libraries it loads are then both AArch64.

The cost is speed: every instruction runs through `qemu-aarch64`, so the build takes hours rather than minutes.

### The version matrix is not negotiable

CANN 8.5.0 is what this repository pins, and that choice fixes everything above it. `vllm-ascend` releases are built against one specific CANN, and the mismatch is not a soft one — `vllm-ascend` at `main` references `platform_ascendc::SocVersion::ASCEND950` in about twenty `csrc` files, an enum member CANN 8.5.0's headers do not define, so the ACLNN op build fails to compile outright.

Upstream's own release-to-CANN mapping, read from each tag's `Dockerfile.310p`:

| `vllm-ascend` | CANN | vLLM |
|---|---|---|
| v0.11.0 | 8.3.rc2 | v0.11.0 |
| **v0.13.0** | **8.5.0** | **v0.13.0** |
| v0.18.0 | 8.5.1 | v0.18.0 |
| v0.21.0rc1 – v0.26.0rc1 | 9.1.0 | matching tag |
| `main` | 9.1.0 | v0.27.1 |

So this image pins the **v0.13.0** row: `vllm-ascend` v0.13.0, vLLM v0.13.0, torch 2.8.0, torch_npu 2.8.0.post2, numpy < 2. `vllm-ascend`'s `CMakeLists.txt` enforces the torch version itself (`FATAL_ERROR` unless it is exactly 2.8.0), so there is no room to drift on that one either.

Moving to a newer torch or vLLM means moving CANN too — change `CANN_VERSION` in `download_deps.sh` (with a new SHA-256), then `VLLM_TAG` and `VLLM_ASCEND_REF` in `provision_deps_aarch64.sh`, as a set.

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
| `deps/apt_debs/` | arm64 `.deb` closure of `docker/target-310p/packages.aarch64.txt` + `dpkg-scanpackages` index |
| `deps/python_wheels/` | cp310 / manylinux-aarch64 wheelhouse (torch 2.8.0+cpu, torch_npu, the vLLM wheel and every transitive dependency) |
| `deps/src/vllm-ascend/` | `vllm-ascend` checkout **including the `catlass` submodule** |
| `deps/MANIFEST.txt` | inventory of the above |

Everything that must be resolved *as* AArch64 runs inside a throwaway `arm64v8/ubuntu:22.04` container:

* **apt** honours `Architecture: arm64` only when it runs on arm64.
* **pip** must evaluate `platform_machine == "aarch64"` markers — vLLM gates `llguidance` and `xgrammar` on exactly that, and pip does not evaluate those markers reliably against a cross `--platform` target.

If you already have some artefacts locally, seed them and skip the downloads:

```bash
CANN_RUN_SRC=~/cann-build/Ascend-cann-toolkit_8.5.0_linux-aarch64.run \
VLLM_WHEEL=~/vllm-build/dist/vllm-0.13.0+empty-cp310-cp310-manylinux2014_aarch64.whl \
VLLM_SRC=~/vllm-build/vllm VLLM_ASCEND_SRC=~/vllm-build/vllm-ascend \
./provision_deps_aarch64.sh ./deps
```

### The vLLM wheel is built, not downloaded

vLLM does publish an aarch64 wheel on PyPI, but it is a **CUDA** build. The Ascend backend lives entirely in `vllm-ascend`, so vLLM itself is built with `VLLM_TARGET_DEVICE=empty` — the same thing upstream's `Dockerfile.310p` does. `provision_deps_aarch64.sh` builds that wheel in the emulated container unless you seed one.

### Why `constraints.aarch64.txt` exists

On aarch64 the `torch` wheels on PyPI are CUDA builds targeting GH200/Jetson. vLLM's `compressed-tensors` only declares a torch *lower* bound, so an unconstrained resolve jumps to the newest torch and pulls in ~5 GB of `nvidia-*-cu13` wheels (cuDNN alone is 651 MB) that an Ascend NPU cannot use and that would shadow the CPU build `torch_npu` is compiled against. Pinning `torch==2.8.0+cpu` from `download.pytorch.org` keeps the whole CUDA subtree out, and PyPI publishes no `2.8.0+cpu`, so the pin is unambiguous.

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
    -f docker/target-310p/Dockerfile.aarch64 \
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
3. **CANN.** `Ascend-cann-toolkit_8.5.0_linux-aarch64.run --full --quiet --install-path=/usr/local/Ascend --install-for-all`, run in stage 0 **on the build host's own architecture** and then `COPY --from`ed into the arm64 image. `--full` rather than the narrower `--install` because `vllm-ascend`'s ACLNN custom-op build needs the development/op-package payload. This is the largest single saving in the build — 617 s emulated against ~93 s — and it runs the vendor installer unmodified; see [docs/cann-native-unpack.md](docs/cann-native-unpack.md) for how it works and how the resulting tree was verified identical.
4. **Python stack**, in three separate `pip install --no-index --find-links=/opt/wheels` transactions (see the note on precedence below).
5. **`vllm-ascend`**, patched from `docker/target-310p/patches/`, then built from `deps/src/vllm-ascend` for `SOC_VERSION=ascend310p3` and installed.
6. **Driver plumbing** — `HwHiAiUser` and friends, `/var/driver`, `/usr/slog`, `/lib64 -> /lib`.
7. **A build-time import check.** The image cannot be produced unless `import torch, torch_npu, vllm, vllm_ascend` all succeed.

### `vllm-ascend` needs patching to build for a 310P at all

`deps/src/vllm-ascend` stays a pristine upstream checkout. The local changes live in `docker/target-310p/patches/` and are applied to the *copy* in stage 6, so re-provisioning never has to undo anything and bumping `VLLM_ASCEND_REF` only means rebasing the diff. Each patch carries its rationale in a header above the diff; `docker/target-310p/patches/0001-vllm-ascend-0.13.0-ascend310p-kernel-gates.patch` is the one that makes v0.13.0 build:

* **The SoC gates never fire.** `CMakeLists.txt` reads `if(SOC_VERSION STREQUAL "ASCEND310P3")` while `setup.py` accepts only the lowercase spelling (see below), so 910B-only kernels reach `ccec` and the build dies on `PIPE_FIX`, a sync pipe that exists only on 910/910B. The patch folds the case into a `SOC_IS_310P` flag matching the whole family.
* **`mla_preprocess` is missing from the exclusion list.** It is `ArchType::ASCEND_V220` code instantiating `MLAOperation` over `__bf16`, which the 310P AI Core does not have, so `ccec` rejects it with `unknown type name 'bfloat16_t'`. MLA is a DeepSeek path that does not run on a 310P regardless. The four LoRA entries in that list are also respelled: written as `${KERNEL_FILES}/bgmv_expand.cpp` against a `;`-list of absolute paths, they expanded to the wrong set — dropping `pos_encoding_kernels.cpp` and `get_masked_input_and_mask_kernel.cpp`, which *do* build here, and keeping a LoRA kernel, which does not.
* **The resulting module could not be imported.** The 310P branch also dropped `batch_matmul_transpose`'s host tiling TU that `csrc/torch_binding.cpp` still calls, leaving undefined `pp_matmul` symbols. That TU is ordinary host C++ and is now built on every SoC, and `csrc/soc_stubs/unsupported_310p.cpp` supplies the six `*_impl` entry points of the excluded kernels so the module links and a call raises instead of the extension failing to load.

`ldd -r` on the finished extension reports no unresolved symbols beyond the Python C API, which `verify_runtime.sh` asserts.

### Why `SOC_VERSION` is lowercase `ascend310p3`

CANN spells the chip `Ascend310P3`, and upstream's own `Dockerfile.310p` exports `ASCEND310P3` — but `vllm-ascend` v0.13.0 leaves no spelling that satisfies all of its readers at once:

* `setup.py`'s `gen_build_info()` does `assert soc_version in soc_to_device` against an **all-lowercase** dict, and writes the resulting device family into `vllm_ascend/_build_info.py`. That file is what the runtime dispatches on, and `gen_build_info` runs from `build_py` — so on every `setup.py bdist_wheel`. `ASCEND310P3` fails that assert outright.
* `CMakeLists.txt` gates its kernel-exclusion lists on `if(SOC_VERSION STREQUAL "ASCEND310P3")`, which no value the assert accepts can match.

The two cannot both be satisfied as shipped. `ascend310p3` is the side worth keeping: it is the real chip, it passes the assert, it yields `__device_type__ = '_310P'` so the installed plugin dispatches as an Atlas 300I, and it is what CANN's `ascendc` cmake stamps into the kernel library's own SoC check. Getting `_build_info` wrong would mis-dispatch at inference time. `verify_runtime.sh` asserts the resulting `_310P`.

The CMake side is then fixed rather than worked around: the patch above replaces both `STREQUAL` gates with one case-insensitive flag, so the exclusion happens with the spelling `setup.py` demands.

### Why three separate pip transactions

`vllm-ascend` pins several packages more tightly than vLLM does — `numpy<2.0.0`, `fastapi<0.124.0`, `opencv-python-headless<=4.11.0.86` — and it has to be the side that wins, which is the order upstream's own `Dockerfile.310p` uses. At other version pairings the two are not merely tighter but incompatible (vLLM 0.27.1 wants `fastapi>=0.133.0` against `vllm-ascend`'s `<0.124.0`), and a single joint resolve fails outright instead of picking a side. Splitting the transactions makes the precedence explicit either way.

`vllm-ascend` itself is installed with `--no-build-isolation --no-deps`: its `pyproject.toml` build-system requires `triton-ascend==3.2.2`, which is published only on Huawei's mirror and which upstream uninstalls again immediately afterwards. An isolated build environment would try to fetch it, and there is no network.

---

## 5. Verify

```bash
docker run --rm --platform linux/arm64 --network=none \
    vllm-ascend-310p:aarch64-offline verify
```

On a build host with no NPU that is **9 checks, all passing** — the two
hardware-only checks report as `[INFO]` (see below).

> **Build time.** A cold build is ~12.5 min (745 s measured end to end from a
> fully evicted BuildKit cache), down from ~22 min since the CANN toolkit
> install moved to a host-architecture stage
> ([docs/cann-native-unpack.md](docs/cann-native-unpack.md)). A warm rebuild
> after a source change is ~6 min, almost all of it the vllm-ascend wheel.
> [docs/cross-compilation-analysis.md](docs/cross-compilation-analysis.md) has
> the full per-step breakdown and measures how far a split host/target build of
> the wheel itself would get.

`verify_runtime.sh` checks the architecture, the Python version, the CANN install, the compiled `vllm_ascend_C` extension, and that `vllm_ascend` was built for device family `_310P`. Its core assertion is the acceptance check:

```bash
docker run --rm --network=none vllm-ascend-310p:aarch64-offline \
    python3 -c "import torch; import torch_npu; import vllm; import vllm_ascend; print('ALL RUNTIME IMPORTS SUCCEEDED')"
```

Checks that genuinely need hardware are reported as `[INFO]`, never as failures, so the suite passes on the x86_64 build host too.

**`import vllm_ascend.vllm_ascend_C` is one of those checks.** `libvllm_ascend_kernels.so` registers its device binaries from an ELF constructor that first calls CANN's `AscendCheckSoCVersion()`; with no NPU attached `aclrtGetSocName()` returns `NULL`, the check builds a `std::string` from it, and the process dies before Python sees anything it could catch:

```text
terminate called after throwing an instance of 'std::logic_error'
  what():  basic_string::_S_construct null not valid
```

That is CANN's own generated stub, not anything specific to this image — which is why nothing in `Dockerfile.aarch64` imports `vllm_ascend_C`, and why `vllm_ascend/utils.py::enable_custom_op()` is deliberately lazy. On the build host the suite proves what a build host can honestly prove — the extension exists and `ldd -r` finds no unresolved symbols beyond the Python C API — and only asserts the import where `/dev/davinci*` exists.

---

## 6. Export for air-gapped deployment

```bash
./build_aarch64.sh --save artifacts/vllm-ascend-310p-aarch64-offline.tar.gz
```

or by hand, streaming straight into `pigz` so the uncompressed 8 GB tar never
touches the disk:

```bash
docker save vllm-ascend-310p:aarch64-offline \
    | pigz -p "$(nproc)" > artifacts/vllm-ascend-310p-aarch64-offline.tar.gz
sha256sum artifacts/vllm-ascend-310p-aarch64-offline.tar.gz
```

The 8.03 GB image compresses to 1.99 GB. Copy the archive to the target server
and load it:

```bash
docker load -i artifacts/vllm-ascend-310p-aarch64-offline.tar.gz
docker image ls vllm-ascend-310p
```

`docker load` reads gzip natively, so there is no separate decompression step.

The archive is self-contained: the target host needs a Docker daemon and the Ascend **driver** (which is a host package, never shipped in an image), nothing else.

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

Build assets are partitioned by target; the orchestrators, the payload and the
docs stay at the root because both images share them.

```text
build_aarch64.sh               preflight + buildx wrapper + docker save
provision_deps_aarch64.sh      fills deps/ (the only networked step)
download_deps.sh               shared installer downloader, SHA-256 verified

docker/target-310p/            THIS image
  Dockerfile.aarch64           native AArch64 offline inference image
  entrypoint.sh                NPU detection + vllm serve launcher
  verify_runtime.sh            in-image verification suite
  packages.aarch64.txt         apt package list, shared by provisioning and build
  requirements.aarch64.txt     torch stack + build backend pins
  requirements-optional.aarch64.txt  best-effort extras (a miss is not fatal)
  constraints.aarch64.txt      keeps the resolve on +cpu torch, off CUDA
  cann_extra.aarch64.txt       CANN libraries the toolkit .run omits
  patches/                     local fixes applied to vllm-ascend at build time
  scripts/fetch_debs.sh        arm64 .deb closure + apt index   (runs in-container)
  scripts/fetch_wheels.sh      aarch64 wheelhouse               (runs in-container)
  scripts/build_vllm_wheel.sh  vLLM wheel, VLLM_TARGET_DEVICE=empty (in-container)

docker/builder-x86_64/         sibling cross-compilation image, see README.md
  Dockerfile                   x86_64 host toolchain + aarch64 CANN sysroot
  assemble_sysroot.sh          lays out the aarch64 sysroot from the .run payload
  verify.sh                    15-point cross-toolchain verification suite

docs/cann-native-unpack.md     stage 0: CANN installed on the build host's arch
docs/soc-build-matrix.md       what changes per target SoC (310P3 / 910B / 950)
docs/cross-compilation-analysis.md  where the build time goes, and how far a
                               split host/target build gets (with measurements)
docs/analyze_build.py          per-step timing breakdown of a buildx log

deps/                          provisioned payload (git-ignored)
artifacts/                     exported image tarballs (git-ignored)
```

**The build context is the repository root, not `docker/target-310p/`.** The
offline payload lives in `deps/`, so every mount and `COPY` in
`Dockerfile.aarch64` is repo-relative: `deps/...` for the payload,
`docker/target-310p/...` for the image's own files. `build_aarch64.sh` passes
`-f docker/target-310p/Dockerfile.aarch64` with the root as context; override
either half with `TARGET_DIR=` or `CONTEXT=`.

---

## 9. Gotchas worth knowing

* **`ldconfig` segfaults under `qemu-user`** while `dpkg` runs the `libc-bin` trigger, which aborts the entire apt transaction. Every apt step in this repo stubs `ldconfig` out for the duration and restores the real binary afterwards.
* **`binfmt_misc` registration is not persistent.** After `wsl --shutdown` you must re-register; both scripts here do it for you.
* **The `catlass` submodule must be present before the build.** `csrc/build_aclnn.sh` runs `git submodule update --init` when `csrc/third_party/catlass/include` is missing — which would need network inside the offline build. `provision_deps_aarch64.sh` clones with `--recurse-submodules` and fails loudly if it is absent.
* **`deps/` is git-ignored.** It is provisioned, not committed: the CANN toolkit alone is 1.1 GB.
* **The native extension cannot be imported on a machine with no NPU.** CANN's generated kernel-registration constructor aborts the process rather than returning an error; see the note in §5. It is not a symptom of a broken image, and it is why the build-time check stops at `import vllm_ascend`.
* **`setuptools-scm` shells out to `git` during `bdist_wheel`.** The copy of `deps/src/vllm-ascend` keeps the upstream `.git`, owned by the provisioning user, so git refuses it as dubious ownership and the wheel step fails. Stage 6 deletes `.git` from the copy first; the version comes from `SETUPTOOLS_SCM_PRETEND_VERSION`, and `git apply` needs no repository.
* **A wheel-only wheelhouse.** Everything is downloaded with `--only-binary=:all:` so the offline install never has to compile an sdist. Packages with no cp310 aarch64 wheel are listed in `requirements-optional.aarch64.txt`, downloaded one at a time, and recorded in `deps/MANIFEST.txt` when they are missing — none of them is needed for `import vllm_ascend` or for `vllm serve`.
