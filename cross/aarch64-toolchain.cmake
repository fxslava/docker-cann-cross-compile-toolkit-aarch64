# ---------------------------------------------------------------------------
# CMake toolchain file: x86_64 host -> aarch64 / Huawei Ascend 310P3 target.
#
# Baked into the image at /opt/cross/aarch64-toolchain.cmake and exported
# through the CMAKE_TOOLCHAIN_FILE environment variable by
# build-vllm-ascend-wheel.sh, because vllm-ascend's setup.py builds its own
# cmake command line and offers no way to pass -DCMAKE_TOOLCHAIN_FILE.
# CMake picks the variable up from the environment (documented behaviour since
# CMake 3.21).
#
# Usable standalone as well:
#
#   cmake -B build -S . \
#     -DCMAKE_TOOLCHAIN_FILE=/opt/cross/aarch64-toolchain.cmake \
#     -DCANN_AARCH64_ROOT="${CANN_AARCH64_ROOT}"
#
# Inputs (cache variable first, environment variable as fallback):
#   CANN_AARCH64_ROOT      aarch64 CANN sysroot built by assemble_sysroot.sh
#   LIBTORCH_AARCH64_ROOT  aarch64 LibTorch unpacked from the torch wheel
#   CROSS_PYTHON_SYSROOT   aarch64 Python headers unpacked from the arm64 debs
#   CROSS_STAGE_ROOT       pip --target staging root holding torch / torch_npu
# ---------------------------------------------------------------------------
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_C_COMPILER   aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
set(CMAKE_AR           aarch64-linux-gnu-ar)
set(CMAKE_RANLIB       aarch64-linux-gnu-ranlib)
set(CMAKE_STRIP        aarch64-linux-gnu-strip)
set(CMAKE_OBJCOPY      aarch64-linux-gnu-objcopy)

# Jammy has no pkg-config-aarch64-linux-gnu package; the Dockerfile installs
# this wrapper by hand.
if(EXISTS /usr/bin/aarch64-linux-gnu-pkg-config)
  set(PKG_CONFIG_EXECUTABLE /usr/bin/aarch64-linux-gnu-pkg-config)
endif()

# Ascend C headers (kernel_operator.h and friends) use C++14+ constexpr, and
# the torch headers require 17. Compiling with the gcc default fails.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# --------------------------------------------------------------------------
# Resolve the four staging roots, cache variable winning over environment.
# --------------------------------------------------------------------------
foreach(_var CANN_AARCH64_ROOT LIBTORCH_AARCH64_ROOT CROSS_PYTHON_SYSROOT CROSS_STAGE_ROOT)
  if(NOT DEFINED ${_var} AND DEFINED ENV{${_var}})
    set(${_var} "$ENV{${_var}}")
  endif()
endforeach()

if(NOT CANN_AARCH64_ROOT)
  set(CANN_AARCH64_ROOT "/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux")
endif()

set(_CANN_LIB64  "${CANN_AARCH64_ROOT}/lib64")
set(_CANN_DEVLIB "${CANN_AARCH64_ROOT}/devlib/linux/aarch64")

# --------------------------------------------------------------------------
# Search behaviour
#
# PROGRAM is NEVER: an executable found under a staging root would be an
# AArch64 binary this host cannot run. Everything else is BOTH rather than
# ONLY, because the CMake package configs we must consume (pybind11, and Torch
# itself) are installed on the HOST side while the libraries they point at
# live in the staging roots.
# --------------------------------------------------------------------------
# ORDER MATTERS. The pip --target staging root comes FIRST so that the torch
# libraries an extension links against are the ones from the wheel that will
# actually be installed on the target. /opt/libtorch-aarch64 is baked into the
# image from whatever torch wheel happened to be in the build context; if the
# two ever diverge, find_library(c10 ...) silently picking the image's copy
# would produce a wheel linked against a different libtorch than it runs on.
if(CROSS_STAGE_ROOT)
  list(APPEND CMAKE_FIND_ROOT_PATH "${CROSS_STAGE_ROOT}/torch" "${CROSS_STAGE_ROOT}/torch_npu")
endif()
if(LIBTORCH_AARCH64_ROOT)
  list(APPEND CMAKE_FIND_ROOT_PATH "${LIBTORCH_AARCH64_ROOT}")
endif()
list(APPEND CMAKE_FIND_ROOT_PATH "${CANN_AARCH64_ROOT}")
if(CROSS_PYTHON_SYSROOT)
  list(APPEND CMAKE_FIND_ROOT_PATH "${CROSS_PYTHON_SYSROOT}/usr")
endif()

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

# ---------------------------------------------------------------------------
# Keep the HOST-arch CANN libraries out of every find_library() result.
#
# The image puts <toolkit>/bin on PATH so ccec and the op tools are runnable.
# find_library() derives extra default search directories from PATH by
# replacing a trailing /bin with /lib and /lib64, and those defaults are
# searched BEFORE a call's own PATHS argument - PATHS is the lowest-priority
# location in a find_ command. CANN's own Findmetadef.cmake (vendored by
# vllm-ascend under csrc/cmake/modules/) does
#
#     find_library(EXEGRAPH_LIB_DIR NAME exe_graph
#                  PATHS ${ASCEND_DIR}/${SYSTEM_PREFIX} PATH_SUFFIXES lib64)
#
# which SHOULD resolve to <toolkit>/aarch64-linux/lib64, but the PATH-derived
# <toolkit>/lib64 wins, and the IMPORTED target ends up pointing at an x86_64
# object:
#     ld: .../x86_64-linux/lib64/libexe_graph.so: error adding symbols: file in wrong format
#
# Ignoring the host library directories outright is the correct answer for a
# cross build - nothing produced here may ever link a host CANN library. Both
# the symlinked and the resolved spelling are listed because <toolkit> is
# itself a symlink into cann-<version>/x86_64-linux.
get_filename_component(_ASCEND_TOOLKIT_ROOT "${CANN_AARCH64_ROOT}" DIRECTORY)
get_filename_component(_ASCEND_TOOLKIT_REAL "${_ASCEND_TOOLKIT_ROOT}" REALPATH)
foreach(_root "${_ASCEND_TOOLKIT_ROOT}" "${_ASCEND_TOOLKIT_REAL}")
  list(APPEND CMAKE_IGNORE_PATH
    "${_root}/lib64"
    "${_root}/lib"
    "${_root}/devlib"
    "${_root}/x86_64-linux/lib64"
    "${_root}/x86_64-linux/devlib")
endforeach()
list(REMOVE_DUPLICATES CMAKE_IGNORE_PATH)

# --------------------------------------------------------------------------
# Include and link paths
# --------------------------------------------------------------------------
include_directories(SYSTEM "${CANN_AARCH64_ROOT}/include")

# AArch64 pyconfig.h, unpacked from libpython3.10-dev:arm64. Debian's
# /usr/include/python3.10/pyconfig.h is a multiarch redirect to
# <x86_64-linux-gnu/python3.10/pyconfig.h> on this host, so without these the
# extension would be compiled against the host's word-size assumptions.
if(CROSS_PYTHON_SYSROOT AND EXISTS "${CROSS_PYTHON_SYSROOT}/usr/include/aarch64-linux-gnu/python3.10")
  include_directories(SYSTEM
    "${CROSS_PYTHON_SYSROOT}/usr/include/aarch64-linux-gnu/python3.10"
    "${CROSS_PYTHON_SYSROOT}/usr/include/python3.10")
endif()

link_directories("${_CANN_LIB64}" "${_CANN_DEVLIB}")

# -rpath-link, not -rpath: libascendcl.so pulls in toolkit libraries through
# DT_NEEDED which in turn need driver symbols (drvHdc*, hal*). The driver
# itself lives on the device, so the link needs the stub directory while the
# runtime must NOT bake this build host's paths into the artefact.
# -L the target sysroot FIRST. CANN's op-project build system (which
# vllm-ascend vendors under csrc/cmake/) adds the HOST-arch library directory
# unconditionally - intf_pub.cmake does
#     link_directories(${ASCEND_CANN_PACKAGE_PATH}/lib64)
# and the aclnn template's func.cmake passes `-L ${ASCEND_CANN_PACKAGE_PATH}/lib64
# -lexe_graph`. In a cross build that resolves to the x86_64 libraries and the
# link dies with
#     ld: .../x86_64-linux/lib64/libexe_graph.so: error adding symbols: file in wrong format
# CMake emits <LINK_FLAGS> before the -L entries contributed by
# link_directories(), so putting the AArch64 directories here makes the
# correct library win without patching upstream's cmake.
set(_CROSS_LINK_FLAGS "-L${_CANN_LIB64} -L${_CANN_DEVLIB}")
set(_CROSS_LINK_FLAGS "${_CROSS_LINK_FLAGS} -Wl,-rpath-link,${_CANN_LIB64} -Wl,-rpath-link,${_CANN_DEVLIB}")
# Same ordering rule as CMAKE_FIND_ROOT_PATH above: the staging root wins over
# the image's baked-in LibTorch.
if(CROSS_STAGE_ROOT)
  foreach(_d "${CROSS_STAGE_ROOT}/torch/lib" "${CROSS_STAGE_ROOT}/torch_npu/lib")
    if(EXISTS "${_d}")
      set(_CROSS_LINK_FLAGS "${_CROSS_LINK_FLAGS} -Wl,-rpath-link,${_d}")
      link_directories("${_d}")
    endif()
  endforeach()
endif()
if(LIBTORCH_AARCH64_ROOT AND EXISTS "${LIBTORCH_AARCH64_ROOT}/lib")
  set(_CROSS_LINK_FLAGS "${_CROSS_LINK_FLAGS} -Wl,-rpath-link,${LIBTORCH_AARCH64_ROOT}/lib")
endif()

# --allow-shlib-undefined is required for ANY link against libascendcl.so, not
# just for Python extensions. libascendcl pulls in libmsprofiler.so, whose
# DT_NEEDED lists libprofapi.so - a thin dispatch shim that dlopen()s
# libprofimpl.so at runtime. ProfAcl*/MsprofReportData are therefore undefined
# across the link-time DT_NEEDED closure by design, and defined at runtime on
# the device. The flag relaxes undefined symbols in SHARED LIBRARIES only, so
# a real undefined reference in the target being linked is still an error.
# For a Python extension it additionally covers the CPython and torch_python
# symbols, which the interpreter supplies when it dlopen()s the module.
set(_CROSS_LINK_FLAGS "${_CROSS_LINK_FLAGS} -Wl,--allow-shlib-undefined")

set(CMAKE_EXE_LINKER_FLAGS_INIT    "${_CROSS_LINK_FLAGS}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${_CROSS_LINK_FLAGS}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${_CROSS_LINK_FLAGS}")
