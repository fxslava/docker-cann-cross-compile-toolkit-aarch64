#!/usr/bin/env bash
# Put the CANN CAModel cycle-accurate simulator in front of the real runtime,
# so ACL programs run with no NPU attached. Source it, or use it as a wrapper:
#
#   . /usr/local/bin/ascend-sim-env.sh          # activate in this shell
#   ascend-sim-env.sh ctest --test-dir build    # activate for one command
#
# Deactivating means starting a new shell. Nothing here is a global ENV in the
# image on purpose: LD_PRELOAD applies to every process that inherits it, and
# an image that preloads a device runtime into apt, dpkg, cmake and gcc is an
# image that fails in ways nobody traces back to here.
#
# ---------------------------------------------------------------------------
# THE WIRING, AND WHY IT IS THIS AND NOT SOMETHING SIMPLER
#
# Measured on CANN 8.5.0, x86_64, against a five-line aclInit/aclrtSetDevice
# probe. Four configurations, one works:
#
#   toolkit alone                      aclInit -> EE1001, "init soc version
#                                      failed", chipType=0
#   libruntime.so symlinked to the     aclInit -> EH9999, still "init soc
#   CAModel build                      version failed"
#   + libsocshim.so preloaded          aclInit OK, aclrtSetDevice -> 107001
#                                      "open device 0 failed"
#   + libnpu_drv_camodel.so preloaded  "CA Model Init Suc", then SIGSEGV in
#                                      thread RT_RECV:
#                                        DriverFactory::GetDriver
#                                        Engine::ReportHeartBreakProcV2
#                                        AsyncHwtsEngine::ReceivingRun
#   libruntime_camodel.so PRELOADED    everything returns 0, aclrtGetSocName()
#   instead of symlinked               reports Ascend310P3
#
# So the CAModel runtime has to be *interposed*, not substituted. Preloading it
# is also what CANN's own launcher expects - tools/msopt/mskpp/launcher/driver.py
# calls is_lib_preloaded('libruntime_camodel.so') to decide it is in simulation,
# and its comment records the other half of the contract:
#
#   "if set_device/reset_device are not used in pairs during simulation, the
#    simulator will core dump"
#
# which is why it force-resets the device afterwards. csrc/tests pairs them in
# AscendDevice's constructor and destructor, so nothing extra is needed there.
#
# libruntime.so -> libruntime_camodel.so still exists in /opt/ascend-sim/lib and
# is still on the path, ahead of lib64: it makes the swap total for anything
# that dlopens the runtime by name rather than inheriting the preload.
#
# libsocshim.so is one function; see common/patches/soc_shim.c. With the
# runtime preloaded the CAModel answers the SoC query itself and the shim is
# not on the critical path, but it costs nothing and it is what keeps the
# symlink-only and dlopen paths from tripping over devlib's lying stub.
# ---------------------------------------------------------------------------
set -u

ascend_sim_activate() {
    local tk="${ASCEND_TOOLKIT_HOME:-/usr/local/Ascend/ascend-toolkit/latest}"
    local soc="${ASCEND_SIM_SOC_VERSION:-${SOC_VERSION:-Ascend310P3}}"
    local shim_dir=/opt/ascend-sim/lib
    local sim_lib="${tk}/tools/simulator/${soc}/lib"

    if [ ! -d "$sim_lib" ]; then
        echo "ascend-sim-env: no simulator for ${soc} at ${sim_lib}" >&2
        echo "  available: $(ls "${tk}/tools/simulator" 2>/dev/null | tr '\n' ' ')" >&2
        return 1
    fi
    for lib in libruntime_camodel.so libnpu_drv_camodel.so; do
        [ -f "${sim_lib}/${lib}" ] || {
            echo "ascend-sim-env: ${sim_lib}/${lib} missing" >&2; return 1; }
    done
    [ -f "${shim_dir}/libsocshim.so" ] || {
        echo "ascend-sim-env: ${shim_dir}/libsocshim.so missing; rebuild the image" >&2
        return 1; }

    # The vendor scripts are not nounset-clean - nnal/atb/set_env.sh tests
    # $ZSH_VERSION - so nounset is lifted for the sourcing only and restored.
    local restore_u=0
    case "$-" in *u*) restore_u=1 ;; esac
    set +u
    [ -f "${tk}/../set_env.sh" ] && . "${tk}/../set_env.sh"
    [ "$restore_u" = "1" ] && set -u

    # Both spellings: SOC_VERSION is what CMake and ccec read, the other is what
    # common/patches/soc_shim.c answers halGetSocVersion with.
    export SOC_VERSION="$soc"
    export ASCEND_SIM_SOC_VERSION="$soc"
    export ASCEND_HOME_PATH="$tk"
    export ASCEND_OPP_PATH="${tk}/opp"

    # devlib stays LAST: on a host that has a real driver, /usr/local/Ascend/
    # driver/lib64 must win over CANN's link-time stubs.
    export LD_LIBRARY_PATH="${shim_dir}:${sim_lib}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    # Order matters: the shim first so its halGetSocVersion beats devlib's, the
    # CAModel runtime next so cce::runtime resolves to the simulator, its driver
    # last so the hal* surface behind it is the model's and not devlib's.
    export LD_PRELOAD="${shim_dir}/libsocshim.so:${sim_lib}/libruntime_camodel.so:${sim_lib}/libnpu_drv_camodel.so${LD_PRELOAD:+:$LD_PRELOAD}"

    # The model writes one core*_instr_log.dump per AI Core into $PWD at every
    # run - 48 files for a 310P3. Keep them out of a build tree unless asked.
    export CAMODEL_LOG_PATH="${CAMODEL_LOG_PATH:-${TMPDIR:-/tmp}/camodel}"
    mkdir -p "$CAMODEL_LOG_PATH" 2>/dev/null || true

    echo "[ascend-sim] ${soc} CAModel active (toolkit ${tk})"
}

# Sourced: mutate this shell. Executed with arguments: activate and hand over.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    ascend_sim_activate
else
    ascend_sim_activate || exit 1
    [ "$#" -gt 0 ] || { echo "usage: ascend-sim-env.sh <command> [args...]" >&2; exit 2; }
    exec "$@"
fi
