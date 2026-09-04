# CANN 8.5.0 Cross-Compilation Toolkit for Ascend 310P3 (AArch64)

Self-contained, reproducible Docker build environment for cross-compiling Huawei Ascend 310P3 applications, DaVinci AI Core kernels, and Python wheels (such as `vllm-ascend`) from an x86_64 host.

---

## Hardware & Architecture Specs

* **Host Architecture:** x86_64 (Linux / WSL 2 Ubuntu 22.04)
* **Target Architecture:** AArch64 (Linux ARM64)
* **Target SoC:** Huawei Ascend 310P3
* **AI Core Microarchitecture:** `dav-m200`
* **Target ELF Machine Code:** `0x1029` (DaVinci AI Core)
* **CANN Stack:** Version `8.5.0`

---

## Repository Structure

```text
.
├── Dockerfile              # Multi-stage / BuildKit image recipe
├── assemble_sysroot.sh     # Extracts 170+ target AArch64 CANN libraries & driver stubs
├── download_deps.sh        # Idempotent downloader with SHA-256 integrity verification
├── verify.sh               # 15-point automated verification suite
├── .dockerignore           # Context exclusion to prevent image layer bloat
├── .gitattributes          # Enforces LF endings across all platforms
└── README.md

```

---

## Prerequisites

1. **Docker with BuildKit support:** Docker 20.10+ (Docker Desktop or native Docker daemon inside WSL 2).
2. **Build Utilities:** `bash`, `wget`, `curl`, `sha256sum`, `stat`.
3. **WSL 2 Recommendation:** Always clone and run the repository inside the native Linux filesystem (e.g. `~/docker-cann-cross-compile-toolkit-aarch64`), **not** on Windows mounts (`/mnt/c/...`), to avoid disk I/O bottlenecks and file permission conflicts.

---

## Step-by-Step Instructions

### 1. Make Scripts Executable

Grant execution permissions to the build and verification scripts:

```bash
chmod +x download_deps.sh assemble_sysroot.sh verify.sh

```

---

### 2. Download Dependencies

Run the dependency downloader. The script verifies existing files via SHA-256 and fetches any missing artifacts into the current build context:

```bash
./download_deps.sh .

```

This step pulls:

* `Ascend-cann-toolkit_8.5.0_linux-x86_64.run` (~1.1 GB)
* `Ascend-cann-toolkit_8.5.0_linux-aarch64.run` (~1.1 GB)
* `torch-2.10.0+cpu-cp310-cp310-manylinux_2_28_aarch64.whl` (LibTorch AArch64 headers and libs, ~146 MB)

---

### 3. Build the Docker Image

The `Dockerfile` uses BuildKit bind-mounts (`--mount=type=bind`) so large installer packages are never copied into the image layers.

* **Standard Build (Host cross-compiler + Ascend C kernel compiler):**
```bash
DOCKER_BUILDKIT=1 docker build -t cann85-cross-310p:latest .

```


* **Build with AArch64 LibTorch baked in (Recommended for `vllm-ascend` wheel builds):**
```bash
DOCKER_BUILDKIT=1 docker build \
  --build-arg WITH_LIBTORCH=1 \
  -t cann85-cross-310p:latest .

```



---

### 4. Verify the Build Environment

Run the self-contained verification suite inside a disposable container:

```bash
docker run --rm cann85-cross-310p:latest verify-cann-cross.sh

```

**What the verification covers (15 checks):**

1. Availability and versions of `aarch64-linux-gnu-gcc`, `aarch64-linux-gnu-g++`, `cmake` (>= 3.26), and cross `pkg-config`.
2. Ascend Device compiler (`ccec` / Bisheng Clang).
3. AArch64 sysroot integrity (`libascendcl.so`, `libacl_op_compiler.so`, driver stubs under `devlib/linux/aarch64`).
4. Compilation of an Ascend C DaVinci vector kernel for `dav-m200` (`-std=c++17`, producing ELF machine `0x1029`).
5. Cross-linking of an AArch64 host binary against the target ACL runtime.

---

## Usage

### Interactive Shell

Mount your workspace into the container:

```bash
docker run --rm -it \
  -v "$PWD":/work \
  cann85-cross-310p:latest

```

### Compiling Ascend C Kernels (Device-side)

```bash
ccec -c kernel.cpp -std=c++17 \
  --cce-aicore-arch=dav-m200 \
  --cce-aicore-only \
  --cce-auto-sync \
  --cce-mask-opt \
  -o kernel.o

```

### Compiling Host Applications (AArch64)

```bash
aarch64-linux-gnu-g++ main.cpp -std=c++17 \
  -I"${CANN_AARCH64_ROOT}/include" \
  -L"${CANN_AARCH64_ROOT}/lib64" \
  -Wl,-rpath-link,"${CANN_AARCH64_ROOT}/lib64:${CANN_AARCH64_ROOT}/devlib/linux/aarch64" \
  -lascendcl \
  -o app_arm64

```

### Cross-Compiling `vllm-ascend`

Pass the built-in sysroot path directly to CMake:

```bash
cmake -B build -S . \
  -DCMAKE_TOOLCHAIN_FILE=cmake/aarch64-toolchain.cmake \
  -DCANN_AARCH64_ROOT="${CANN_AARCH64_ROOT}" \
  -DSOC_VERSION=Ascend310P3 \
  -DASCEND_AICORE_ARCH=dav-m200
cmake --build build -j$(nproc)

```

---

## Technical Notes & Gotchas

* **CANN Version String:** Upstream Huawei OBS returns HTTP `403 Forbidden` on nonexistent keys. Use version `8.5.0` (not `8.5.RC1`).
* **Makeself Extraction:** Inner packages fail if extraction target directories already exist. `assemble_sysroot.sh` manages scratch directories dynamically.
* **Symlink Resolution:** `assemble_sysroot.sh` uses `find \( -type f -o -type l \)` with `cp -aL` to dereference and preserve all shared object aliases (e.g. `libascend_protobuf.so`).
* **Driver Link-Time Stubs:** Cross-linking host binaries against `libascendcl.so` requires device driver link stubs (`drvHdc*`, `hal*`) located under `${CANN_AARCH64_ROOT}/devlib/linux/aarch64/`.
* **C++ Standard:** Ascend C headers (`kernel_operator.h`) require `-std=c++17`. Compiling with default C++11 will fail.