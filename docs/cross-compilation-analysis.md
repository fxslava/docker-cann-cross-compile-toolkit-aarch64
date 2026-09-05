# Cross-compilation of the AArch64 image: measurements and feasibility

Where the emulated build actually spends its time, how far a split
host/target build gets today, and what is left to close it.

All timings are from `--progress=plain` buildx logs on the WSL2 x86_64 host
(12 cores), building `docker/target-310p/Dockerfile.aarch64` under `qemu-aarch64`. Reproduce with
`docs/analyze_build.py <build.log>`.

---

## 1. Where the time goes

> **Superseded in part.** These are the numbers *before* the CANN toolkit
> install moved to a host-architecture stage (§4). Step 4/13 below is now ~93 s
> rather than 617 s, and a cold build is ~13 min rather than ~22. The relative
> picture for the *wheel* build, which is what §2 and §3 are about, is
> unchanged.

### Cold build — every layer rebuilt: **~1305 s (21.8 min)**

| Step | What it does | Time | Share |
|---|---|---:|---:|
| 4/13 | CANN 8.5.0 toolkit `.run --full` | **617 s** | **47%** |
| 6/13 | pip: torch stack, vLLM, vllm-ascend deps | 275 s | 21% |
| 7/13 | vllm-ascend wheel build | **315 s** | **24%** |
| 2/13 | apt from the local arm64 archive | 71 s | 5% |
| 12/13 | final import check | 25 s | 2% |
| 3,5,8/13 | pip bootstrap, cann_extra, driver plumbing | ~7 s | <1% |

### Inside the wheel build (step 7/13), 315 s total

| Phase | Time |
|---|---:|
| copy source, apply patches, stage third_party | ~19 s |
| **CMake configure** (pybind11, Torch, ascendc codegen) | **118 s** |
| Ascend C device kernels (`ccec`) + host stub pass | 48 s |
| host C++ TUs (`torch_binding.cpp` …) + link `vllm_ascend_C` | 111 s |
| wheel packaging + `pip install` | 18 s |

### Warm build — the loop a developer actually runs: **~340 s**

Changing a patch or a source file invalidates only step 7/13 onward. Stages
1–6 stay cached, so an iteration is the 315 s wheel build plus the 25 s import
check.

### What this means

Two conclusions, and they point in different directions:

* **For a cold build, compilation is not the bottleneck.** Actual C++/Ascend C
  compilation is 159 s of 1305 s — 12%. The CANN installer alone is nearly
  four times that, and it is not compiling anything: it is a shell-and-Python
  installer running under emulation.
* **For a warm build, compilation is nearly all of it.** 277 s of ~340 s is
  CMake configure plus compilation, and that is what a split build removes.

So a host/target split is worth roughly **16% off a cold build** but plausibly
**3–4× off the iteration loop**, which is where the time is actually spent.

---

## 2. What was proven to work

Experiments run in `cann85-cross-310p:latest` (the sibling `docker/builder-x86_64/Dockerfile`
image: `aarch64-linux-gnu` GCC 11 + the x86_64 CANN 8.5.0 toolkit + the
aarch64 CANN sysroot from `assemble_sysroot.sh`).

| Question | Result |
|---|---|
| Does the x86_64 `ascendc_pack_kernel` accept an **AArch64** host-stub object? | **Yes.** It rewrote the `.ascend.kernel.*` section of an aarch64 object and the embedded bytes matched the device blob byte-for-byte; the result still links into an aarch64 `.so`. |
| Can vllm-ascend's CMake be configured for a cross target? | **Yes**, and it takes **0.6 s instead of 118 s**. It resolves the aarch64 `libpython3.10.so` and the aarch64 `libtorch.so`, and reports `Building for the 310P family: ON`. |
| Does the Ascend C **device** pass cross-compile? | **Yes.** `ccec` is host-architecture-independent; it produced the same `m200` device objects. |
| Does the generated `host_stub.cpp` cross-compile? | **Yes** — `host_stub.cpp.o` came out AArch64 under the toolchain file. |
| Are all the target-side inputs available offline? | **Yes.** aarch64 `torch` 2.8.0+cpu and `torch_npu` 2.8.0.post2 wheels, the arm64 `libpython3.10-dev` deb, and the aarch64 `libascendc_runtime.a` are all already in `deps/`. |

Two details that made the configure work, both worth keeping:

* **A stub `torch` module on the host.** `CMakeLists.txt` asks the build
  interpreter two questions — `torch.__version__` and
  `torch.utils.cmake_prefix_path`. The real aarch64 torch cannot be imported on
  x86_64, so a three-line stub package answers both, pointing
  `find_package(Torch)` at the unpacked aarch64 tree.
* **A CMake toolchain file** with `CMAKE_FIND_ROOT_PATH` covering the sysroot,
  the unpacked torch, and `$ASCEND_HOME_PATH/aarch64-linux`, with
  `..._MODE_PROGRAM NEVER` so `ccec` and `ascendc_pack_kernel` still come from
  the host.

---

## 3. What is still blocking it

The build reaches the **link** of `libvllm_ascend_kernels.so` and stops on two
issues inside CANN's own cmake (`tools/tikcpp/ascendc_kernel_cmake/legacy_modules`),
which is the path `ascendc_library()` takes.

### 3.1 `ASCENDC_RUNTIME` is hardcoded to the host archive

`legacy_modules/host_config.cmake:75`

```cmake
set(ASCENDC_RUNTIME ${ASCEND_CANN_PACKAGE_PATH}/lib64/libascendc_runtime.a)
```

There is no override. On an x86_64 toolkit that is the x86_64 archive, and the
aarch64 link fails with `Relocations in generic ELF (EM: 62) … file in wrong
format`. The x86_64 toolkit ships **no** aarch64 build of it under
`aarch64-linux/`.

*Workaround, verified to get past this step:* copy the real aarch64 archive —
`cann-asc-devkit_8.5.0_linux-aarch64/aarch64-linux/libascendc_runtime.a`, which
is inside the aarch64 `.run` already in `deps/` — over
`$ASCEND_HOME_PATH/lib64/libascendc_runtime.a` in the builder stage. It is a
static archive, never dlopened, so replacing it does not disturb the host
tools.

### 3.2 The bisheng host pass cannot be retargeted cleanly — **open**

`ascendc_library()` compiles each kernel `.cpp` a second time in "host" mode to
generate its launch stubs, in an `ExternalProject` whose `CONFIGURE_COMMAND`
forwards an explicit `-D` list that does **not** include `CMAKE_TOOLCHAIN_FILE`
or `CMAKE_CXX_COMPILER`. That sub-project sets its own compiler
(`bisheng_config.cmake:25-26`):

```cmake
set(CMAKE_C_COMPILER    "${CCEC_PATH}/bisheng")
set(CMAKE_CXX_COMPILER  "${CCEC_PATH}/bisheng")
```

so it always builds for the build host, producing x86_64 objects that cannot
link into an aarch64 `.so`.

There **is** a supported seam: the same `ExternalProject_Add` forwards
`-DASCENDC_HOST_COMPILE_OPTIONS=$<TARGET_PROPERTY:<target>_interface,HOST_COMPILE_OPTIONS>`,
and `host_project/CMakeLists.txt` applies it. Since bisheng is clang-based,
appending to that property does reach the compiler:

```cmake
set_property(TARGET vllm_ascend_kernels_interface APPEND
             PROPERTY HOST_COMPILE_OPTIONS --target=aarch64-linux-gnu ...)
```

Progress against that seam:

1. `--target=aarch64-linux-gnu --sysroot=/usr/aarch64-linux-gnu` — bisheng
   honours the triple; the error moves to `'cstdint' file not found`, i.e. it
   is now looking for aarch64 C++ headers.
2. Adding `-isystem /usr/aarch64-linux-gnu/include/c++/11` and the matching
   `aarch64-linux-gnu` and `include` directories — the header error clears and
   the next failure is:

   ```
   bisheng: error: cannot specify -o when generating multiple output files
   ```

That last one is where it stands. An explicit target triple appears to put
bisheng into a multi-target mode that conflicts with the single `-o` the
sub-project passes, even under `--cce-host-only`. Resolving it needs either the
right bisheng flag combination or wiring the pass to CANN's own bundled cross
toolchain at `$ASCEND_HOME_PATH/toolkit/toolchain/hcc`
(`aarch64-target-linux-gnu-g++`), which `fwk_modules/device_task.cmake` already
uses for a different target.

Note also that `fwk_modules/config.cmake:105-106` has a first-class cross hook:

```cmake
set(ASCENDC_CMAKE_COMPILER ${CMAKE_CXX_COMPILER})
set(CMAKE_CXX_COMPILER ${CMAKE_CROSS_PLATFORM_COMPILER})
```

but `ascendc_library()` goes through `legacy_modules`, which has no equivalent.
Getting vllm-ascend onto the `fwk_modules` path may be a shorter route than
fighting bisheng's flags.

### 3.3 Not yet reached

These were never exercised, because the build stops earlier. They are the
remaining unknowns for anyone continuing:

* Linking `vllm_ascend_C` itself against the aarch64 `libtorch`/`libtorch_npu`
  and `libpython3.10.so` — configure resolved them, but the link never ran.
* `setup.py bdist_wheel` end to end, including the `pip show torch-npu` lookup,
  which needs a host-side `torch_npu` dist-info pointing at the unpacked
  aarch64 tree.
* Whether the resulting wheel's ABI tags come out right for cp310 aarch64.

---

## 4. A separate, larger win that needs no cross-compiler — **now implemented**

The CANN installer was 47% of a cold build, and none of it is compilation. That
step now runs in stage 0 on the build host's own architecture and the arm64
image `COPY --from`s the result: **617 s → ~93 s**, taking a cold build from
~22 min to ~13 min.

The earlier note here proposed extracting the payload with `--noexec --extract=`
and reassembling the merged tree by hand, and warned that getting that merge
subtly wrong would surface only on real hardware. That turned out to be
unnecessary. Measurements that changed the plan:

| Phase | Emulated | Native |
|---|---:|---:|
| self-extraction (outer + 21 components) | 161 s | 38 s |
| install scripts (the merge itself) | ~456 s | ~50 s |

Decompression is only a quarter of the cost — the merge is the rest — so
extracting natively and merging under emulation would have saved little. The
installer, however, is pure shell whose only architecture dependency is reading
`arch` to choose component packages. Shimming that lets the **vendor installer
run unmodified** on the host, which is both faster and more faithful than any
hand-written merge.

See [cann-native-unpack.md](cann-native-unpack.md) for the mechanism and for the
manifest diff proving the resulting tree is identical to an emulated install.

---

## 5. Recommendation

1. **Do not restructure around cross-compilation for cold-build speed.** It
   addresses 12% of a cold build. The measurements do not support the premise
   that emulated compilation dominates.
2. **Do pursue it for iteration speed**, where it plausibly gives 3–4×. The
   hard parts are already proven: configure, the device pass, and
   `ascendc_pack_kernel` all cross correctly. One blocker remains (§3.2).
3. **Cost to be honest about:** a cross build additionally requires the x86_64
   CANN toolkit `.run` (~1.1 GB) in `deps/`, which today's offline payload does
   not carry, plus the stub-torch and toolchain-file machinery in §2. That is a
   real increase in the offline surface `provision_deps_aarch64.sh` has to
   guarantee.
4. **The CANN extraction in §4 is the better first optimisation** if cold-build
   time is the goal: bigger win, no new payload, no vendor-cmake surgery.
