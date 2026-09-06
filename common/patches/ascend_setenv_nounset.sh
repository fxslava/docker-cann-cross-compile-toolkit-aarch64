#!/bin/bash
# Sources CANN's vendor environment scripts under `set -u`. Source; do not execute.
#
#   . /usr/local/lib/ascend/setenv.sh
#
# FAILURE MODE - nnal/atb/set_env.sh tests $ZSH_VERSION to decide how it was
# sourced. Under `set -u` that unset variable aborts the shell:
#     set_env.sh: line 43: ZSH_VERSION: unbound variable
# and the enclosing RUN or entrypoint exits 127. Vendor environment scripts are
# not written to be nounset-clean.
#
# nounset is lifted for the sourcing only and restored immediately after, so it
# stays in force for the caller. A missing script is skipped: ATB is present on
# 950PR (NNAL is installed) and absent on 310P.
ascend_source_setenv() {
    local base="${ASCEND_BASE:-/usr/local/Ascend}" env_sh
    local restore_u=0
    case "$-" in *u*) restore_u=1 ;; esac
    set +u
    for env_sh in "${base}/ascend-toolkit/set_env.sh" \
                  "${base}/nnal/atb/set_env.sh"; do
        [ -f "$env_sh" ] && . "$env_sh"
    done
    [ "$restore_u" = "1" ] && set -u
    return 0
}
