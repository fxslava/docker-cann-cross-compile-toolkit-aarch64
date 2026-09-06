#!/bin/sh
# Stages the archives vllm-ascend's CMake would otherwise FetchContent from
# gitcode.com, so csrc/build_aclnn.sh runs with no network.
#
#   THIRD_PARTY=<deps>/third_party ASCEND_TOOLKIT_HOME=<path> \
#       sh cmake_fetchcontent_local.sh <vllm-ascend-checkout>
#
# FAILURE MODE - under --network=none each dependency fails with
# "Could not resolve: gitcode.com" after five CMake retries and takes the wheel
# build with it, minutes into the run.
#
# CANN_3RD_LIB_PATH defaults to csrc/third_party (csrc/build.sh) and is passed
# through as -DCANN_3RD_LIB_PATH. Each dependency checks it before the network:
#
#   pkg/abseil-cpp-20230802.1.tar.gz  abseil-cpp.cmake, "pkg" branch
#   pkg/protobuf-25.1.tar.gz          ascend_protobuf.cmake, "pkg" branch
#                                     (CMakeLists includes ascend_protobuf.cmake,
#                                     NOT protobuf.cmake - staging for the wrong
#                                     one silently does nothing)
#   json/include/nlohmann/json.hpp    json.cmake short-circuits on find_path
#   makeself/{makeself,makeself-header}.sh   makeself-fetch.cmake
#
# makeself carries no payload entry: CANN ships a copy under
# op_project_templates and it is copied from the installed toolkit.
#
# THE TARGET DOCKERFILES INLINE THIS LOGIC RATHER THAN CALLING IT. BuildKit keys
# a layer on the literal command string plus its mounts, so referencing this
# file from the RUN that compiles the ACLNN kernels would invalidate that layer
# and restart a ~90-minute compile. Keep the two in step by hand; this copy is
# what run_dev.sh and any out-of-image build use.
set -eu
SRC="${1:?usage: cmake_fetchcontent_local.sh <vllm-ascend-checkout>}"
THIRD_PARTY="${THIRD_PARTY:?THIRD_PARTY must point at the staged third_party tree}"
TK="${ASCEND_TOOLKIT_HOME:-/usr/local/Ascend/ascend-toolkit/latest}"
MAKESELF="${TK}/tools/op_project_templates/ascendc/customize/cmake/util/makeself"

cd "$SRC"
mkdir -p csrc/third_party
cp -a "${THIRD_PARTY}/." csrc/third_party/

if [ -f csrc/cmake/third_party/makeself-fetch.cmake ] \
   && [ ! -f csrc/third_party/makeself/makeself.sh ]; then
    [ -f "${MAKESELF}/makeself.sh" ] \
        || { echo "this ref needs makeself and the toolkit does not carry it" >&2; exit 1; }
    cp -a "$MAKESELF" csrc/third_party/makeself
fi
if [ -f csrc/third_party/makeself/makeself.sh ]; then
    chmod 0755 csrc/third_party/makeself/makeself.sh \
               csrc/third_party/makeself/makeself-header.sh
fi
echo "third_party staged under $(pwd)/csrc/third_party"
