# CANN 8.5.0 Toolchain and 310P3 Simulator (x86_64)

A self-contained `linux/amd64` Docker image that does two things from one
x86_64 host, with no emulation and no NPU:

* **cross-compiles** Huawei Ascend 310P3 applications, DaVinci AI Core kernels
  and Python wheels for AArch64;
* **runs** 310P3 device code natively against CANN's **CAModel** cycle-accurate
  simulator, so `csrc/tests` in `vllm-ascend` executes and verifies its
  numerics against CPU references with no hardware attached.

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
* **The Ascend 310P operator package** — `libopapi.so`, the `ascend310p` binary
  kernels, and the host-side tiling functions. The toolkit `.run` ships none of
  it; see [§5](#5-the-310p-operator-package-and-why-it-is-not-in-the-toolkit).
* **CAModel simulator wiring** — `/opt/ascend-sim/lib` and
  `/usr/local/bin/ascend-sim-env.sh`; see [§6](#6-running-310p-code-on-the-camodel-simulator).
* **googletest 1.14.0** unpacked at `/opt/googletest`, so `csrc/tests`
  configures without `FetchContent` reaching github.com.

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
| `ASCEND_SIM_SOC_VERSION` | `Ascend310P3` — read by the `halGetSocVersion` shim |
| `GOOGLETEST_SOURCE_DIR` | `/opt/googletest` |

Two entries above are corrections over the obvious values, and both failed
silently rather than loudly:

> **`PATH` points at `tools/ccec_compiler/bin`, not `compiler/ccec_compiler/bin`.**
> The 8.5.0 toolkit has no `compiler/ccec_compiler` directory on either
> architecture. Pointing `PATH` at the old layout leaves `ccec` unresolved with
> no diagnostic until a kernel compile dies on `command not found`.

> **`LD_LIBRARY_PATH` ends with `${ASCEND_TOOLKIT_HOME}/devlib`.**
> `libascendcl.so` reaches `libascend_hal.so` through its dependency chain, and
> that library ships with the host *driver*; `devlib` holds CANN's link-time
> stubs for a machine without one. GNU `ld` resolves a shared library's own
> `DT_NEEDED` entries through `LD_LIBRARY_PATH`, so omitting it breaks the
> **link**, not just the run:
> `ld: lib64/libruntime.so: undefined reference to 'halGetDeviceInfo'`.
> It is last on the path so a bind-mounted real driver always wins.

> **`SOC_VERSION` is `Ascend310P3` here, capitalised — and that is correct for
> *this* image.** It is CANN's own spelling, which is what `ccec` and the
> `ascendc` CMake modules expect. The inference target uses the lowercase
> `ascend310p3` because `vllm-ascend`'s `setup.py` asserts against an
> all-lowercase dict; see
> [README.aarch64.md](../../README.aarch64.md) §"Why `SOC_VERSION` is
> lowercase".

---

## 1. Provision dependencies

The build context is the **repository root**, and everything large is
bind-mounted from `deps/` so none of it lands in an image layer.

```bash
./builders/builder-x86_64/provision.sh
```

This is the only networked step. It calls `download_deps.sh` for the installers
below, then stages the complete 310P operator package (~5.6 GB, lifted from the
vendor CANN image — see §5) and the googletest tarball into
`deps/builder-x86_64/`. Budget ~60 GB of free disk: the payload, the vendor
image it is lifted from, and the resulting ~13 GB build.

`download_deps.sh` fetches, verifying each by SHA-256 and size:

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

Cross-compilation only, with no operator package and no simulator — this is the
pre-simulator image, and it needs only `download_deps.sh`:

```bash
DOCKER_BUILDKIT=1 docker build -f builders/builder-x86_64/Dockerfile --build-arg WITH_SIMULATOR=0 -t cann85-cross-310p:latest .
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
6. **The operator package** — `libopapi.so` present and exporting all six
   operators `csrc/tests` resolves, the `ascend310p` kernel tree,
   `op_tiling/liboptiling.so`, and a complete `ops_legacy`.
7. **The CAModel simulator, end to end** — a *native x86_64* ACL application is
   compiled, run under `ascend-sim-env.sh`, and must open device 0, create a
   stream and report `aclrtGetSocName() == Ascend310P3`.

Checks 6 and 7 report `[INFO]` instead of failing on a `WITH_SIMULATOR=0`
image, where those pieces are absent by request.

A fully provisioned image scores **27 / 27**.

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

---

## 5. The 310P operator package, and why it is not in the toolkit

**The publicly downloadable CANN 8.5.0 toolkit is not a complete CANN install.**
Two things `csrc/tests` needs are missing from it, and they fail differently:

| Missing | Where it belongs | Symptom |
|---|---|---|
| `libopapi.so` (+ `_cv`, `_math`, `_nn`, `_transformer`) | `lib64/` | the suite dlopens it and gets nothing: *"failed to load libopapi.so; source the CANN set_env.sh first"* — **every device case skips** |
| the `ascend310p` binary kernels | `opp/built-in/op_impl/ai_core/tbe/kernel/` | the operator has no code to run |
| **`op_tiling/lib/linux/x86_64/liboptiling.so`** | `opp/built-in/op_impl/ai_core/tbe/` | *"`aclnnRmsNormGetWorkspaceSize` failed with status 561002 — `AclNN_Inner_Error(EZ9999): Do not find tiling func of RmsNorm!`"* |

The third one is the trap. `aclnn` resolves a **host-side tiling function** per
operator before it ever launches a kernel, and the toolkit ships **no
`op_tiling` directory at all** — its whole `opp/built-in` is 15 MB and contains
only `op_impl`, against 1.6 GB and five subtrees in the vendor image. Stage the
kernels without it and every case still fails, with an error that reads like a
missing kernel.

### It cannot be downloaded

The package that carries all of this is
`Ascend-cann-kernels-310p_8.5.0_linux-x86_64.run`. Probed against the OBS
bucket on 2026-09-06 — where **403 means "this key does not exist"**, not "you
are blocked":

```
Ascend-cann-kernels-310p_8.5.0_linux-aarch64.run   403
Ascend-cann-kernels-310p_8.5.0_linux-x86_64.run    403
Ascend-cann-kernels-310p_8.5.0_linux.run           403
Ascend-cann-nnrt_8.5.0_linux-aarch64.run           403
Ascend-cann-nnal_8.5.0_linux-aarch64.run           206
Ascend-cann-toolkit_8.5.0_linux-aarch64.run        206
```

The same holds on the 9.1.0 line for `-950`, `-a5`, `-910b` and `-nnrt`. Huawei
publishes the toolkit and NNAL and withholds every kernels package, so
`provision.sh` lifts the bytes out of the **vendor container image** instead —
the route `targets/target-310p/provision.sh` already takes for `libhccl.so` and
`targets/target-950pr/provision.sh` for its 26 `cann_extra` libraries. Set
`KERNELS_RUN=/path/to/the.run` if you have a copy from a support channel and
the Dockerfile will bind-mount and run the real installer instead.

`quay.io/ascend/cann:8.5.0-310p-ubuntu22.04-py3.11` is multi-arch; the
`linux/amd64` manifest is the one used here.

### What gets staged

| | |
|---|---|
| `lib64/` | 22 libraries, 158 MB — computed as a delta against the toolkit, not hard-coded |
| `opp/` | the tree **whole**, ~5.4 GB — every `ascend310p` kernel group plus the host-side tiling libraries |

### `ops_legacy` is staged, and that is deliberate

`kernel/ascend310p/ops_legacy` is 3.8 GB of the 3.9 GB kernel tree, and an
earlier revision of `provision.sh` dropped it: all six `aclnn` entry points the
suite calls live in `ops_nn` and `ops_transformer`, so the legacy tree looked
like dead weight.

**The entry point is not the kernel.** `aclnnMatmul` lowers onto a graph that
launches `TransData` around `MatMul`, and both of those are legacy operators.
With the trimmed tree the matmul suite fails 36 of 40 cases:

```
aclnnMatmulGetWorkspaceSize failed with status 561103
  AclNN_Inner_Error(EZ9999): cannot open op kernel bin json file [],
  reason : No such file or directory
  failed to get op kenrel bin json
    [.../opp/built-in/op_impl/ai_core/tbe//kernel/ascend310p/
     ops_legacy/trans_data/TransData_1f7d0991...json]
```

Add `trans_data` and the identical error comes back naming `ops_legacy/mat_mul`.
The closure is not readable off the operator names, it surfaces **one operator
per run**, and each run of the matmul suite is minutes of simulated cycles — so
the tree ships whole. This is what takes the image from ~7 GB to ~13 GB, and it
is the difference between a verification image that works and one that fails
somewhere new every time the suite is extended.

`provision.sh` and `verify.sh` both assert `ops_legacy/mat_mul` and
`ops_legacy/trans_data` are present, so a payload staged by the old revision is
rejected rather than silently reused.

---

## 6. Running 310P code on the CAModel simulator

CANN ships a cycle-accurate model of the AI Core at
`${ASCEND_TOOLKIT_HOME}/tools/simulator/<SoC>/lib`, on **both** architectures —
so an x86_64 host can execute 310P3 device code natively. Nothing is
downloaded for this; the toolkit already has it.

```bash
docker run --rm -it -v "$PWD":/work cann85-cross-310p:latest
. /usr/local/bin/ascend-sim-env.sh
```

or as a one-shot wrapper:

```bash
ascend-sim-env.sh ctest --test-dir build/csrc-tests --output-on-failure
```

### The wiring, and why it is not simpler

Measured against a five-call `aclInit`/`aclrtSetDevice` probe on CANN 8.5.0,
x86_64. Four configurations; one works:

| Configuration | Result |
|---|---|
| toolkit alone | `aclInit` → `EE1001`, *"init soc version failed"*, `chipType=0` |
| `libruntime.so` symlinked to the CAModel build | `aclInit` → `EH9999`, still *"init soc version failed"* |
| ⋯ plus `libsocshim.so` preloaded | `aclInit` OK; `aclrtSetDevice` → `107001` *"open device 0 failed"* |
| ⋯ plus `libnpu_drv_camodel.so` preloaded | `CA Model Init Suc`, then **SIGSEGV** in thread `RT_RECV`: `DriverFactory::GetDriver` ← `Engine::ReportHeartBreakProcV2` |
| **`libruntime_camodel.so` PRELOADED instead of symlinked** | **everything returns 0**, `aclrtGetSocName()` → `Ascend310P3` |

The CAModel runtime has to be **interposed, not substituted**. That is also
what CANN's own launcher expects: `tools/msopt/mskpp/launcher/driver.py` calls
`is_lib_preloaded('libruntime_camodel.so')` to decide it is in simulation, and
its comment records the other half of the contract — *"if set_device and
reset_device are not used in pairs during simulation, the simulator will core
dump"*. `csrc/tests` pairs them in `AscendDevice`'s constructor and destructor,
so nothing extra is needed there.

`libsocshim.so` ([`common/patches/soc_shim.c`](../../common/patches/soc_shim.c))
supplies one symbol, `halGetSocVersion`. CANN reads the part number through it;
the only `libascend_hal.so` on a machine with no NPU is `devlib`'s stub, and
that stub **returns SUCCESS without writing the caller's buffer** —

```
halGetSocVersion:
  str w0, [sp, #12]   ; devId
  str x1, [sp]        ; socVersion   <- stored, never written through
  str w2, [sp, #8]    ; len
  mov w0, #0x0        ; SUCCESS
  ret
```

so the runtime reads an uninitialised name, derives `chipType=0` and aborts. A
stub that *failed* would be caught; one that lies is not.

### Building and running `csrc/tests`

From a `vllm-ascend` checkout mounted at `/work`:

```bash
cmake -B build-x86_64 -S csrc/tests -DCMAKE_BUILD_TYPE=Release -DASCEND_HOME_PATH="$ASCEND_TOOLKIT_HOME" -DSOC_VERSION=Ascend310P3 -DVLLM_ASCEND_TESTS_BUILD_BENCHMARKS=OFF -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST=/opt/googletest
```

```bash
cmake --build build-x86_64 -j"$(nproc)"
```

```bash
ascend-sim-env.sh ctest --test-dir build-x86_64 -LE benchmark --output-on-failure
```

No toolchain file: this is a native host build, and the binaries have to run
here. `-DVLLM_ASCEND_TESTS_BUILD_BENCHMARKS=OFF` matters more than usual — a
benchmark issues 1,300+ launches per case, and every one of them is simulated
cycle by cycle.

`-DFETCHCONTENT_SOURCE_DIR_GOOGLETEST` has to be passed on the command line:
CMake reads it from the cache, not from the environment, so the image's
`GOOGLETEST_SOURCE_DIR` is a reminder rather than a mechanism.

### What it costs

The model is cycle-accurate, so run time scales with **the arithmetic**, not
with the number of cases. Measured on this host for `test_rmsnorm_310p`:

| Case | Wall clock |
|---|---|
| `tokens7_hidden1536` | 1.9 s |
| `tokens32_hidden4096` | 9.4 s |
| `tokens128_hidden2048` | 21.5 s |
| `tokens128_hidden4096` | 69.2 s |
| `tokens128_hidden8192` | 119.9 s |

The whole 51-case `test_rmsnorm_310p` suite is **12 m 24 s** (744 s).

> **Matmul is a different order of magnitude, and it is easy to be caught by
> it.** `Matmul310PTest.ZeroWeightsProduceZeroOutput/k2048_n2048` — the
> **smallest** shape in that suite — takes **427 s**. Cost tracks `k·n`; the
> six shapes span `k2048_n2048` to `k4096_n11008`, which is 10.8× the
> arithmetic, and they sum to ~25× the smallest. Across the suite's 22 cases
> that projects to roughly **11 hours**.
>
> This only became visible once `ops_legacy` was staged: before that every
> matmul case failed at plan time in under a second, and the suite "ran" in
> two minutes. **A suite that got dramatically slower is the evidence it
> started working.**
>
> The full sweep is deliberately not part of routine verification — run one
> shape as a gate here and validate heavy matmul on real silicon.

Budget accordingly, and filter (`--gtest_filter='*tokens1_*'`, or `ctest -R`)
while iterating. For matmul, pin a single shape:

```bash
ascend-sim-env.sh /build/test_matmul_310p --gtest_filter='*k2048_n2048'
```

### Measured results

From a clean `--no-cache` build (**5 m 59 s**, **14.4 GB**), running `csrc/tests`
inside a fresh container with nothing bind-mounted but the test source — the
operator package, the CAModel wiring, googletest and the activation script all
come from the image:

| Suite | Cases | Passed | Failed | Skipped | Status |
|---|--:|--:|--:|--:|---|
| `test_rmsnorm_310p` | 51 | **51** | 0 | 0 | ✅ numerics verified against the CPU reference |
| `test_matmul_310p` | 22 | 1 / 1 run | 0 | 0 | ✅ gate case only — the sweep is ~11 h, see above |
| `test_rotary_embedding_310p` | 31 | 4 | 54 | 0 | ❌ host tiling, `561002` |
| `test_activation_swiglu_310p` | 52 | 4 | 96 | 0 | ❌ kernel launch, `361001` |
| `test_paged_attention_310p` | 27 | 6 | 14 | 29 | ❌ `161001` |

**No suite reports a missing kernel.** The signature this whole exercise was
about — `cannot open op kernel bin json file` — does not appear anywhere in the
run. That is what the complete `opp` payload bought.

### The three residual failures are not payload gaps

Worth stating plainly, because the instinct on any of these is to go stage more
of the vendor image, and that is wasted effort:

| Suite | Status | Where it dies | Kernel present? |
|---|---|---|---|
| rotary | `561002` | `apply_rotary_pos_emb_tiling.cpp:451`, `GetPlatformInfo` — *"PrepareTiling fail to get core num"* | **yes**, `ops_transformer/apply_rotary_pos_emb` |
| swiglu | `361001` | `rtsLaunchKernelWithHostArgs` → runtime `107000` | **yes**, `ops_nn/swi_glu` |
| paged-attention | `161001` | `ReshapeAndCache310PTest` | only `ops_legacy/reshape_and_cache_nz` |

Two independent lines of evidence:

1. **The kernels are on disk.** Both failing operators have `ascend310p`
   binary kernel directories in the staged tree. Nothing is missing to load.
   Each dies *before* the kernel is reached — rotary in the host-side tiling
   function, swiglu at the launch call.
2. **Staging the whole tree changed nothing for them.** Against the trimmed
   payload these three scored 4/54, 4/96 and 6/14/29. Against the complete
   5.4 GB payload they score **4/54, 4/96 and 6/14/29** — bit-identical. The
   same change took matmul from 36 failures to passing.

Rotary's *"fail to get core num"* is consistent with an operator whose tiling
asks the platform for a core count that a 310P3 does not report — `Ascend310P3.ini`
carries `ai_core_cnt=8` and `vector_core_cnt=7`, and the AI Core on this part
is unified rather than split into separate cube and vector cores. If so it
would fail the same way on real 310P3 silicon, and the simulator is reporting
the truth. **Confirm on hardware before treating any of these as a simulator
defect** — that is where the boundary between "CANN 8.5.0 does not support this
op on 310P3" and "the CAModel does not implement this launch path" actually
gets settled.

## Gotchas

* **CANN version strings.** The Huawei OBS bucket answers a request for a key
  that does not exist with **HTTP 403, not 404**. A 403 means "wrong version
  string", not "you are blocked". The 8.5 line is published as `8.5.0`, never
  `8.5.RC1`. Probe with a range request before assuming access problems.
* **Makeself extraction targets must not pre-exist** — see §2.
* **Symlink resolution** matters when copying the payload — see §2.
* **`-std=c++17`** for anything touching `kernel_operator.h` — see §4.
* **An AArch64 link against `libascendcl.so` needs
  `-Wl,--allow-shlib-undefined`.** Without it the link fails with a dozen
  `undefined reference to 'ProfAcl…'` errors that look like a broken sysroot
  and are not. CANN's own dependency graph is incomplete on purpose:
  `libmsprofiler.so` references the `ProfAcl*` family but its `DT_NEEDED`
  lists only `libprofapi.so` — `libprofimpl.so`, which defines them, is
  **dlopened at run time**. Adding `-lprofimpl` by hand does not help; it just
  moves the failure down to `halProfSampleRegister` and
  `halProfSampleDataReport`, which are defined by the **real driver's**
  `libascend_hal.so`. `devlib`'s link-time stub does not define them, and no
  build host without an NPU has the real one. The flag says "these resolve at
  run time", which is exactly true here. `verify.sh` §4b uses it.
* **`.dockerignore` excludes `*.tar.gz` unanchored**, so it matches at any
  depth and would drop `deps/builder-x86_64/googletest-*.tar.gz` from the build
  context. There is an explicit re-include after it. The Dockerfile only
  *warns* when the tarball is absent, so losing it shows up much later as
  `csrc/tests` trying to clone googletest from github.com.
* **Do not write `nm … | grep -q "$sym"` in a loop under `set -o pipefail`.**
  `grep -q` exits at the first match, `nm` then dies of SIGPIPE, and the
  pipeline reports failure even though the symbol was found. This produced a
  confident, entirely false "`libopapi.so` exports none of the six operators"
  on an image where all six are present. Dump the symbols to a file once and
  grep the file.
