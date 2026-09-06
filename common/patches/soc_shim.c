/*
 * halGetSocVersion for a CANN runtime driving the CAModel simulator.
 *
 * Compiled into /opt/ascend-sim/lib/libsocshim.so by the builder image and put
 * first on LD_PRELOAD by /usr/local/bin/ascend-sim-env.sh. Not linked by
 * anything: it exists purely to interpose one driver symbol.
 *
 * FAILURE MODE - without it, `aclInit` fails before the simulator is ever
 * reached:
 *
 *   Invalid_Argument(EE1001): rtGetDevMsg execution failed, the feature is not
 *   supported.
 *     [Init][Version]init soc version failed.
 *     chipType=0 does not support get device msg feature.
 *
 * The cause is a collision between two halves of the toolkit that were never
 * meant to meet. CANN resolves `halGetSocVersion` out of `libascend_hal.so`,
 * which ships with the host *driver*; on a machine with no NPU the only
 * `libascend_hal.so` on the path is the link-time stub in
 * ${ASCEND_TOOLKIT_HOME}/devlib, and that stub is a no-op:
 *
 *   halGetSocVersion:
 *     sub sp, sp, #0x10
 *     str w0, [sp, #12]     ; devId
 *     str x1, [sp]          ; socVersion   - stored, never written through
 *     str w2, [sp, #8]      ; len
 *     mov w0, #0x0          ; returns SUCCESS
 *     ret
 *
 * It reports success and leaves the caller's buffer untouched, so the runtime
 * reads an uninitialised SoC name, derives chipType=0 and aborts. A stub that
 * *failed* would be caught; one that lies is not.
 *
 * The simulator's own fake driver does not cover the gap:
 * tools/simulator/Ascend310P3/lib/libnpu_drv_camodel.so defines 129 symbols and
 * `halGetSocVersion` is not among them (it has halGetDeviceInfo,
 * halGetChipCapability and the memory/queue surface, but nothing that names the
 * part). So the value has to come from somewhere, and this is the smallest
 * somewhere available.
 *
 * The interposition is safe on real silicon because it never happens there:
 * ascend-sim-env.sh is the only thing that sets LD_PRELOAD, it is sourced
 * explicitly, and a host with a driver resolves the real libascend_hal.so from
 * /usr/local/Ascend/driver/lib64, which LD_LIBRARY_PATH keeps ahead of devlib.
 *
 * Build:
 *   gcc -shared -fPIC -O2 -Wall -Wextra -Werror -o libsocshim.so soc_shim.c
 *
 * The -Wall -Wextra -Werror is not decoration. An earlier revision omitted
 * <stdlib.h>; `getenv` was then implicitly declared as returning `int`, its
 * result truncated to 32 bits on aarch64, and the first dereference segfaulted
 * the whole process inside the dynamic loader - before main(), with no
 * diagnostic beyond "Segmentation fault".
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* The part the simulator is configured for. Overridden at run time by
 * ASCEND_SIM_SOC_VERSION so one image can drive another 310P variant without a
 * rebuild; ascend-sim-env.sh exports it alongside SOC_VERSION. */
#ifndef ASCEND_SIM_SOC_VERSION_DEFAULT
#define ASCEND_SIM_SOC_VERSION_DEFAULT "Ascend310P3"
#endif

/* Signature read off the devlib stub's own prologue rather than a header:
 * (w0, x1, w2) = (uint32_t, char *, uint32_t), returning a 32-bit status.
 * CANN spells the return type drvError_t; 0 is DRV_ERROR_NONE. */
int halGetSocVersion(uint32_t devId, char *socVersion, uint32_t len)
{
    const char *version = getenv("ASCEND_SIM_SOC_VERSION");
    size_t n;

    /* The simulator is a single virtual part; every device id answers alike. */
    (void)devId;

    if (version == NULL || version[0] == '\0') {
        version = ASCEND_SIM_SOC_VERSION_DEFAULT;
    }
    if (socVersion == NULL || len == 0) {
        return 1;
    }

    /* Refuse rather than truncate. A short SoC name is a name for a different
     * part, and the runtime would dispatch on it without complaint. */
    n = strlen(version);
    if (n + 1 > (size_t)len) {
        return 1;
    }

    memcpy(socVersion, version, n + 1);
    return 0;
}
