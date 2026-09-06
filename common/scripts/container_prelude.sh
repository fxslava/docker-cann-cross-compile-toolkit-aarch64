#!/bin/bash
# Environment normalisation for provisioning containers. Source; do not execute.
#
#   . /common/container_prelude.sh
#   prelude_network                 IPv4 preference
#   prelude_ldconfig_stub on|off    qemu-user workaround, emulated targets only
#   prelude_apt_install <pkg>...    from /debs when mounted, else the network
#   $PIP_NET                        pip retry/timeout flags
#
# Two host defects and one emulation defect. They are not symmetric across
# targets, hence parameters rather than duplication.

# FAILURE MODE - the host advertises AAAA records for PyPI and has no working
# IPv6 route. curl runs happy-eyeballs and fails over in milliseconds; pip and
# urllib3 walk getaddrinfo in order and wait out the full timeout, which
# presents as a slow link. Measured: pip moved 1.5 kB in 89 s while the host
# fetched the same URL in 1.3 s.
prelude_network() {
    printf 'precedence ::ffff:0:0/96  100\n' >> /etc/gai.conf
}

# FAILURE MODE - ldconfig segfaults intermittently under qemu-user while dpkg
# runs the libc-bin trigger, aborting the apt transaction. Required for
# emulated (aarch64-under-QEMU) targets; inert noise on native ones.
prelude_ldconfig_stub() {
    case "$1" in
        on)
            cp -aL /usr/sbin/ldconfig /usr/sbin/ldconfig.orig
            printf '#!/bin/sh\nexit 0\n' > /usr/sbin/ldconfig
            chmod 0755 /usr/sbin/ldconfig
            ;;
        off)
            [ -e /usr/sbin/ldconfig.orig ] && mv -f /usr/sbin/ldconfig.orig /usr/sbin/ldconfig
            ;;
    esac
}

# The staged archive is the closure of the target's package list and a superset
# of what provisioning needs, so this step needs no apt network when /debs is
# mounted. The online sources are moved aside and restored, never deleted.
prelude_apt_install() {
    if [ -f /debs/Packages.gz ]; then
        mv /etc/apt/sources.list /etc/apt/sources.list.online 2>/dev/null || true
        mv /etc/apt/sources.list.d /etc/apt/sources.list.d.online 2>/dev/null || true
        mkdir -p /etc/apt/sources.list.d
        echo 'deb [trusted=yes] file:/debs ./' > /etc/apt/sources.list.d/offline.list
        apt-get update -qq
        apt-get install -y --no-install-recommends "$@" >/dev/null
        rm -f /etc/apt/sources.list.d/offline.list
        mv /etc/apt/sources.list.online /etc/apt/sources.list 2>/dev/null || true
        rm -rf /etc/apt/sources.list.d
        mv /etc/apt/sources.list.d.online /etc/apt/sources.list.d 2>/dev/null || true
    else
        apt-get update -qq
        apt-get install -y --no-install-recommends "$@" >/dev/null
    fi
}

# Many short attempts, not a few long ones. Raising --timeout made stalls worse:
# a dead peer held the transfer for the full window. --timeout is socket
# inactivity, so a slow but flowing download is unaffected.
PIP_NET="--retries 20 --timeout 20"
