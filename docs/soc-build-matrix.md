# SoC build matrix: what changes per Ascend target

What has to move when this image is retargeted from the Ascend 310P3 to another
SoC. Everything below is read out of the CANN 8.5.0 payload in `deps/` and out
of `deps/src/vllm-ascend`, not from memory — the probe commands are given so the
claims can be rechecked against a different CANN release.

---

## 1. What CANN 8.5.0 actually supports

From `<toolkit>/ascendc_kernel_cmake/legacy_modules/host_config.cmake`:

| CANN SoC list | Members | `BUILD_MODE` | AI Core arch |
|---|---|---|---|
| `ascend910b_list` | `ascend910b1` `ascend910b2` `ascend910b2c` `ascend910b3` `ascend910b4` `ascend910b4-1` `ascend910_9391` `ascend910_9381` `ascend910_9372` `ascend910_9392` `ascend910_9382` `ascend910_9362` | `c220` | dav-c220 |
| `ascend910_list` | `ascend910a` `ascend910proa` `ascend910b` `ascend910prob` `ascend910premiuma` | `c100` | dav-c100 |
| `ascend310p_list` | `ascend310p1` **`ascend310p3`** `ascend310p5` `ascend310p7` + `ascend310p3vir01/02/04/08` | `m200` | **dav-m200** |
| `ascend310b_list` | `ascend310b1`…`b4` | `m300` | dav-m300 |
| `kirinx90_list` / `kirin9030_list` | `kirinx90` / `kirin9030` | `l300` / `l311` | — |

Note `ascend310b_list` is defined but **not** included in `all_product`, so
passing one of those SoCs fails the `SOC_VERSION ... does not support` guard even
though a `BUILD_MODE` exists for it.

Recheck with:

```bash
grep -nE '^set\((ascend|kirin)[a-z0-9_]*_list' \
  <toolkit>/ascendc_kernel_cmake/legacy_modules/host_config.cmake
```

---

## 2. The three targets

### Ascend 310P3 — what this repo builds today

| | |
|---|---|
| `SOC_VERSION` | `ascend310p3` (lowercase — see README §"Why SOC_VERSION is lowercase") |
| AI Core arch | `dav-m200`, `BUILD_MODE m200` |
| vllm-ascend `__device_type__` | `_310P` |
| Numeric formats | fp16 and int8. **No bf16 in the vector unit.** |
| Runtime dtype | must be `--dtype float16` |

The 310P is inference-only silicon and its AI Core has no bf16 path, which is
what `targets/target-310p/patches/0001-…-ascend310p-kernel-gates.patch` exists to handle: the
Ascend C kernels that instantiate over `__bf16`, and the ones using `PIPE_FIX`
(a 910/910B-only synchronisation pipe), cannot be compiled and are excluded,
with a stub translation unit supplying their `*_impl` symbols so the module
still links. See the patch header for the per-kernel reasoning.

### Ascend 910B — the realistic second target

| | |
|---|---|
| `SOC_VERSION` | one of `ascend910b1`…`ascend910b4` |
| AI Core arch | `dav-c220`, `BUILD_MODE c220` (also sets `DYNAMIC_MODE ON`) |
| vllm-ascend `__device_type__` | `A2` |
| Numeric formats | fp16, bf16, int8 |
| Runtime dtype | bf16 usable; no float16 lock needed |

What has to change:

* **`ARG SOC_VERSION`** in `targets/target-310p/Dockerfile.aarch64`, and **`ENV ASCEND_AICORE_ARCH`**
  from `dav-m200` to `dav-c220`.
* **`verify_runtime.sh`** asserts `__device_type__ = _310P`; that check has to
  become target-aware or it will fail the build for a correct 910B image.
* **The patch stays applied and becomes a near no-op.** Its gate is
  `if(SOC_VERSION_LOWER MATCHES "^ascend310p")`, so on a 910B the kernel
  exclusions and the stub TU are both skipped and every kernel compiles as
  upstream intends. The one unconditional change — building
  `batch_matmul_transpose/op_host/tiling/tiling_data.cpp` on every SoC — matches
  what upstream already did for non-310P targets, so it is not a behaviour
  change there.
* **`deps/cann_extra`** is the one to watch. Those 21 libraries (including the
  monolithic `libhccl.so` and `libopapi.so` that the standalone toolkit omits)
  are staged out of `quay.io/ascend/cann:8.5.0-310p-ubuntu22.04-py3.11`. For a
  910B image they should come from the corresponding 910b CANN image instead;
  `targets/target-310p/provision.sh` step 1b hardcodes the 310p tag.
* Model/parallelism defaults differ: 910B has far more HBM and supports real
  tensor parallelism across dies.

### Ascend 950PR — not buildable on CANN 8.5.0

CANN 8.5.0 has **no support for it at all**. Evidence, all from the payload in
`deps/`:

* Zero files in the entire extracted toolkit mention `ascend950` / `ASCEND950`
  (`grep -rl 'ascend950\|ASCEND950' <extracted payload>` → 0 files).
* It is absent from every SoC list in `host_config.cmake` above, so
  `ascendc_library()` would fail its `does not support` guard.
* `platform_ascendc.h`'s `SocVersion` enum stops at `ASCEND910_95`
  (`__DAV_C310__`) and `ASCEND910_55`; there is no `ASCEND950`.

This is the same wall that ended the earlier `vllm-ascend@main` / torch 2.10
attempt: that branch's SDK expected `platform_ascendc::SocVersion::ASCEND950`,
which CANN 8.5.0 does not define.

So targeting a 950-class part requires a **newer CANN release**, and with it a
matching `vllm-ascend` / `torch_npu` / vLLM set — a different release matrix, not
a parameter change to this one. Treat it as a separate image, and re-run the
probes in §1 against the new toolkit before assuming anything below transfers.

One forward-looking hint already present: vllm-ascend 0.13.0's `setup.py` maps
`ascend910_9579` to device family `A5`, so the plugin anticipates a generation
that this CANN does not yet build for.

**That separate image now exists, and it builds.** `targets/target-950pr/`
targets a 950-class part on CANN **9.1.0** and x86_64, natively rather than
under emulation; it builds air-gapped in ~87 minutes and verifies 10/10 on a
build host. [docs/target-950pr-x86_64.md](target-950pr-x86_64.md) carries its
release matrix, its staging plan, the probe evidence that 9.1.0 is the right
line to pin, and its measured results;
[targets/target-950pr/README.md](../targets/target-950pr/README.md) is the
operator guide. Three findings there change what this section implies:

* The real SoC string is lowercase `ascend950dt_9582`, not `Ascend950PR`; every
  upstream gate is the case-sensitive CMake regex `SOC_VERSION MATCHES "ascend950"`.
* `ascend950` is handled on the *same* CMake branch as `ascend310p`, so
  `ascendc_library(vllm_ascend_kernels)` is skipped and the image carries no
  `libvllm_ascend_kernels.so`.
* **But that gate governs only the kernels library.** `csrc/build_aclnn.sh`
  takes its own `ascend950` branch and compiles **27 ACLNN custom ops into 493
  kernel binaries**, `mla_prolog_v3` (MLAPO) and `chunk_kda_fwd` among them.
  An earlier revision of this file said the 950 operator set was a subset with
  MLAPO excluded; the build disproved it. The exclusion list it referred to
  applies to the `vllm_ascend_C` extension, not to the ACLNN package — which is
  the largest single product of the image.

---

## 3. The knobs, in one place

| Knob | Where | 310P3 | 910B | 950 |
|---|---|---|---|---|
| CANN line | `provision.sh` / `build.sh` | `8.5.0` | `8.5.0` | **`9.1.0`** |
| image platform | `build.sh` `--platform` | `linux/arm64` (emulated) | `linux/arm64` | **`linux/amd64` (native)** |
| `SOC_VERSION` | target `Dockerfile` `ARG` | `ascend310p3` | `ascend910b1`… | `ascend950dt_9582` |
| `ASCEND_AICORE_ARCH` | target `Dockerfile` `ENV` | `dav-m200` | `dav-c220` | `dav-v300` |
| device-family assert | `verify_runtime.sh` | `_310P` | `A2` | `A5` |
| kernel-exclusion patch | `targets/target-310p/patches/0001-…` | active | inert (gate does not match) | none — upstream builds unmodified |
| `cann_extra` source image | target `provision.sh` | `…:8.5.0-310p-…` | needs the 910b tag | `…:9.1.0-950-ubuntu22.04-py3.10` |
| ACLNN custom ops | `csrc/build_aclnn.sh` | not built | not built | **27 ops / 493 kernels** |
| serving dtype | runtime `--dtype` | `float16` (forced) | bf16 or fp16 | checkpoint's own |

A retarget is therefore mostly mechanical, with three things that are *not*
mechanical and need a human decision: which CANN image `cann_extra` comes from,
making the `verify_runtime.sh` device-family assertion target-aware rather than
hardcoded, and — as the 950 showed — checking what the plugin's *other* build
paths do for the new SoC rather than reading one CMake gate and generalising
from it.

---

## 4. Host-side CANN install and other architectures

Stage 0 of `Dockerfile.aarch64` installs the CANN toolkit on the build host's
own architecture and the arm64 stage `COPY --from`s the result (see
`docs/cann-native-unpack.md`). That works because the installer is pure shell
and picks its component packages from `arch`, which the stage shims.

The shim names the **target** architecture, so the same mechanism retargets
cleanly: the only assumption is that the `.run` being installed contains
component packages for the architecture the shim claims. Installing an
`x86_64` CANN toolkit would need `TARGET_ARCH=x86_64` and no shim at all.
