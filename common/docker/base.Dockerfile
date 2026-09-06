# ============================================================================
#  Shared base stage for the Ascend offline inference images.
#
#  Everything both targets do to a stock ubuntu:22.04 before anything
#  architecture-specific happens. It takes no network: the offline apt archive
#  is bind-mounted by the target Dockerfiles, not by this one.
#
#  Build (from the repository root, either architecture):
#    docker buildx build --platform linux/amd64 \
#        -f common/docker/base.Dockerfile -t ascend-base:jammy-amd64 .
#    docker buildx build --platform linux/arm64 \
#        -f common/docker/base.Dockerfile -t ascend-base:jammy-arm64 .
#
#  Consume it by pointing a target at the result:
#    BASE_IMAGE=ascend-base:jammy-amd64 ./targets/target-950pr/build.sh
#
#  THE TARGETS DEFAULT TO PLAIN ubuntu:22.04, NOT TO THIS IMAGE. Substituting
#  the base changes the first layer and invalidates every layer after it,
#  including the ~90-minute ACLNN kernel compile. Switch only as part of a run
#  that is already paying for a full rebuild.
# ============================================================================
ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ENV LANG=C.UTF-8
ENV PYTHONUNBUFFERED=1

# PEP 668. Jammy ships no /usr/lib/python3.10/EXTERNALLY-MANAGED marker, so this
# is a no-op on the default base. It is kept so that overriding BASE_IMAGE with
# a newer Ubuntu - noble marks its interpreter, and every `pip install` then
# fails with error: externally-managed-environment - does not silently break the
# build. A single-application container is the case the PEP carves out.
#
# The system interpreter is used deliberately, not a venv: the CANN installer
# shells out to the system pip3 for its --pylocal components and would not see
# one.
RUN rm -f /usr/lib/python3.*/EXTERNALLY-MANAGED

# CANN's set_env.sh scripts are bash, and the vendor scripts sourced from them
# are not nounset-clean. See common/patches/ascend_setenv_nounset.sh.
SHELL ["/bin/bash", "-c"]

# Ascend runtime knobs upstream sets in its own images.
ENV TASK_QUEUE_ENABLE=1
ENV OMP_NUM_THREADS=1

WORKDIR /workspace
