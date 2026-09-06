# CANN 8.5.0 Cross-Compilation Toolchain (x86_64 → AArch64 / Ascend 310P3)

A self-contained `linux/amd64` Docker image for **cross-compiling** Huawei
Ascend 310P3 applications, DaVinci AI Core kernels and Python wheels from an
x86_64 host — no emulation, no NPU required.

This is the **builder**, not a deployable image. It is the sibling of the
inference targets documented in [the root README](../../README.md), and they
solve different problems:

| | `builders/builder-x86_64` (this image) | `targets/target-310p` |
|---|---|---|
| Image architecture | `linux/amd64` | `linux/arm64` (QEMU-emulated at build time) |
| Purpose | cross-compile Ascend C kernels and ACL apps | run inference on the target |
| CANN | x86_64 toolkit **+ an assembled aarch64 sysroot** | aarch64 toolkit installed natively |
| Python stack | host-side tooling only | full torch / torch_npu / vLLM / vllm-ascend |
| Network at build | apt + pip from the internet | **none** (`--network=none`) |

If your goal is a deployable inference image, you want
[targets/target-310p/README.md](../../targets/target-310p/README.md). Use this
image when you are developing kernels or ACL applications and want a fast
compile-link cycle without paying the emulation tax.

---

## Hardware and architecture

| | |
|---|---|
| Host architecture | x86_64 (Linux / WSL 2 Ubuntu 22.04) |
| Target architecture | AArch64 (Linux ARM64) |
| Target SoC | Huawei Ascend 310P3 |
| AI Core microarchitecture | `dav-m200` |
| Target ELF machine code | `0x1029` (DaVinci AI Core) |
| CANN stack | 8.5.0 |

---

## What the image contains

Both halves of an Ascend cross build:

* **Host side** — the `aarch64-linux-gnu` GCC toolchain, CMake (≥ 3.26, which
  `vllm-ascend`'s wheel build requires), Ninja, and a hand-installed
  `aarch64-linux-gnu-pkg-config` wrapper. Jammy has **no**
  `pkg-config-aarch64-linux-gnu` package — it only appears from 24.04 — so the
  standard Debian cross wrapper is written by hand.
* **Device side** — CANN's Bisheng/`ccec` compiler for Ascend C kernels.
* **An assembled AArch64 sysroot** at `${CANN_AARCH64_ROOT}`, laid out to match
  `cmake/aarch64-toolchain.cmake` in `vllm-ascend` so it can be passed straight
  through as `-DCANN_AARCH64_ROOT`.

### Environment baked into the image

| Variable | Value |
|---|---|
| `ASCEND_TOOLKIT_HOME` | `/usr/local/Ascend/ascend-toolkit/latest` |
| `CANN_AARCH64_ROOT` | `${ASCEND_TOOLKIT_HOME}/aarch64-linux` |
| `ASCEND_CROSS_SYSROOT` | `${ASCEND_TOOLKIT_HOME}/aarch64-linux` |
| `SOC_VERSION` | `Ascend310P3` |
| `ASCEND_AICORE_ARCH` | `dav-m200` |
| `CC_aarch64_linux_gnu` / `CXX_aarch64_linux_gnu` | `aarch64-linux-gnu-gcc` / `-g++` |
| `LIBTORCH_AARCH64_ROOT` | `/opt/libtorch-aarch64` (only with `WITH_LIBTORCH=1`) |

> **`SOC_VERSION` is `Ascend310P3` here, capitalised — and that is correct for
> *this* image.** It is CANN's own spelling, which is what `ccec` and the
> `ascendc` CMake modules expect. The inference target uses the lowercase
> `ascend310p3` because `vllm-ascend`'s `setup.py` asserts against an
> all-lowercase dict; see
> [README.aarch64.md](../../README.aarch64.md) §"Why `SOC_VERSION` is
> lowercase".

---

## 1. Download dependencies

The build context is the **repository root**, and the installers are
bind-mounted from `deps/` so ~2.2 GB never lands in an image layer.

```bash
./download_deps.sh deps
```

This fetches, verifying each by SHA-256 and size:

* `Ascend-cann-toolkit_8.5.0_linux-x86_64.run` (~1.1 GB)
* `Ascend-cann-toolkit_8.5.0_linux-aarch64.run` (~1.1 GB)
* `torch-2.10.0+cpu-cp310-cp310-manylinux_2_28_aarch64.whl` (~146 MB) —
  optional, the AArch64 LibTorch headers and libraries

PyTorch publishes no `libtorch-*.zip` for arm64 Linux; the
`manylinux_2_28_aarch64` **wheel is the distribution channel** for LibTorch
there. Note that the `+` in the version must be percent-encoded as `%2B` in the
URL — a literal `+` returns 403.

---

## 2. Build the image

From the repository root, always with `-f`:

```bash
DOCKER_BUILDKIT=1 docker build -f builders/builder-x86_64/Dockerfile -t cann85-cross-310p:latest .
```

With AArch64 LibTorch baked in — recommended if you are building `vllm-ascend`
wheels:

```bash
DOCKER_BUILDKIT=1 docker build -f builders/builder-x86_64/Dockerfile --build-arg WITH_LIBTORCH=1 -t cann85-cross-310p:latest .
```

### How the sysroot is assembled

The aarch64 `.run` **refuses to install on an x86_64 host**: its payload
binaries and its post-install steps are ARM64. So `assemble_sysroot.sh` uses
makeself's `--noexec --extract=` to drop the raw payload — which is all a cross
sysroot needs — and lays it out as:

```text
${CANN_AARCH64_ROOT}/
├── include -> ../include          headers are architecture-independent
├── lib64/                         flat aggregate of every AArch64 ELF .so
└── devlib/linux/aarch64/          driver link-time stubs (drvHdc*, hal*)
```

Two details that took debugging and are easy to reintroduce:

* **Never pre-create an extraction target.** The outer Huawei wrapper
  (`label=ASCEND_RUN_PACKAGE`) tolerates an existing directory; the inner
  packages fail outright. `assemble_sysroot.sh` manages scratch directories
  dynamically.
* **Symlinks must be dereferenced.** The script uses
  `find \( -type f -o -type l \)` with `cp -aL`, so every shared-object alias
  (`libascend_protobuf.so` and friends) survives.

---

## 3. Verify the toolchain

```bash
docker run --rm cann85-cross-310p:latest verify-cann-cross.sh
```

The suite covers, and fails the run if any check fails:

1. **Host cross-toolchain** — `aarch64-linux-gnu-gcc`, `-g++`, the
   `pkg-config` wrapper, and CMake ≥ 3.26.
2. **Ascend device compiler** — `ccec` / Bisheng Clang.
3. **Sysroot integrity** — `libascendcl.so` and `libacl_op_compiler.so` present
   and AArch64, `include/acl/acl.h` resolving, the driver stubs under
   `devlib/linux/aarch64` populated, and **no non-AArch64 ELF leaked into the
   sysroot**.
4. **A real Ascend C kernel compile** for `dav-m200` with `-std=c++17`,
   asserting the object's ELF machine is `0x1029`.
5. **A real cross link** — an AArch64 host application linked against the
   target `libascendcl.so`.

> CANN ships **no plain `libhccl.so`** in the toolkit. On aarch64, HCCL is
> `libhccl_{alg,plf,legacy}.so` (`libhccl_fwk.so` is x86_64-only in 8.5.0), so
> the suite checks for those rather than the aggregate. The inference target
> stages the real aggregate out of a vendor container instead — see the root
> README's `cann_extra` section.

---

## 4. Use it

### Interactive shell

```bash
docker run --rm -it -v "$PWD":/work cann85-cross-310p:latest
```

The working directory inside the image is `/work`.

### Compiling an Ascend C device kernel

```bash
ccec -c kernel.cpp -std=c++17 \
  --cce-aicore-arch=dav-m200 \
  --cce-aicore-only \
  --cce-auto-sync \
  --cce-mask-opt \
  -o kernel.o
```

`-std=c++17` is **mandatory**: the TikCFW headers use C++14-and-later
`constexpr`, and the compiler default (C++11) produces `-Wc++14-extensions`
errors.

### Compiling an AArch64 host application

```bash
aarch64-linux-gnu-g++ main.cpp -std=c++17 \
  -I"${CANN_AARCH64_ROOT}/include" \
  -L"${CANN_AARCH64_ROOT}/lib64" \
  -Wl,-rpath-link,"${CANN_AARCH64_ROOT}/lib64:${CANN_AARCH64_ROOT}/devlib/linux/aarch64" \
  -lascendcl \
  -o app_arm64
```

The `-rpath-link` to `devlib/linux/aarch64` is not optional: cross-linking
against `libascendcl.so` needs the device driver link stubs (`drvHdc*`, `hal*`),
which live only there.

### Cross-compiling `vllm-ascend`'s native pieces

```bash
cmake -B build -S . \
  -DCMAKE_TOOLCHAIN_FILE=cmake/aarch64-toolchain.cmake \
  -DCANN_AARCH64_ROOT="${CANN_AARCH64_ROOT}" \
  -DSOC_VERSION=Ascend310P3 \
  -DASCEND_AICORE_ARCH=dav-m200
```

```bash
cmake --build build -j"$(nproc)"
```

> **This cross-compiles the C++/Ascend C layer, not the wheel.** The
> `vllm-ascend` *wheel* cannot be cross-built at all: `CMakeLists.txt` runs
> `import torch` for the version check and `setup.py` shells out to
> `pip show torch-npu` for the target headers, so build-host and target Python
> must be the same interpreter. That is precisely why
> `targets/target-310p` builds under emulation instead. See
> [docs/cross-compilation-analysis.md](../../docs/cross-compilation-analysis.md)
> for how far a split host/target build actually gets, with measurements.

---

## Gotchas

* **CANN version strings.** The Huawei OBS bucket answers a request for a key
  that does not exist with **HTTP 403, not 404**. A 403 means "wrong version
  string", not "you are blocked". The 8.5 line is published as `8.5.0`, never
  `8.5.RC1`. Probe with a range request before assuming access problems.
* **Makeself extraction targets must not pre-exist** — see §2.
* **Symlink resolution** matters when copying the payload — see §2.
* **`-std=c++17`** for anything touching `kernel_operator.h` — see §4.
