#!/bin/bash
# ---------------------------------------------------------------------------
# Runs INSIDE an arm64v8/ubuntu:22.04 container (under QEMU) with network.
# Downloads the arm64 .deb closure listed in /prov/packages.txt and writes a
# local apt repository index next to it in /out, so that Dockerfile.aarch64 can
# apt-get install from file:/debs with --network=none.
#
#   docker run --platform linux/arm64 -v <prov>:/prov:ro -v <debs>:/out \
#       arm64v8/ubuntu:22.04 bash /prov/fetch_debs.sh
# ---------------------------------------------------------------------------
set -eu
export DEBIAN_FRONTEND=noninteractive

# ldconfig segfaults intermittently under qemu-user while dpkg runs the
# libc-bin trigger, which aborts the whole apt transaction. Stub it out for the
# duration and restore the real binary afterwards.
cp -aL /usr/sbin/ldconfig /usr/sbin/ldconfig.orig
printf '#!/bin/sh\nexit 0\n' > /usr/sbin/ldconfig
chmod 0755 /usr/sbin/ldconfig

PKGS=$(grep -vE '^[[:space:]]*(#|$)' /prov/packages.txt | tr '\n' ' ')
echo "[debs] arch=$(dpkg --print-architecture) packages: $PKGS"

apt-get update -qq
apt-get install -y --no-install-recommends --download-only $PKGS

# Move the payload out BEFORE pulling dpkg-dev in, otherwise dpkg-dev's own
# debs land in the archive too and the offline image ends up installing a build
# toolchain nobody asked for.
mkdir -p /out
cp -n /var/cache/apt/archives/*.deb /out/
echo "[debs] downloaded $(find /out -name '*.deb' | wc -l) packages"

apt-get install -y --no-install-recommends dpkg-dev >/dev/null
cd /out
dpkg-scanpackages --multiversion . /dev/null > Packages 2>/dev/null
gzip -9c Packages > Packages.gz

mv -f /usr/sbin/ldconfig.orig /usr/sbin/ldconfig
echo "[debs] index: $(grep -c '^Package:' Packages) entries, $(du -sh /out | cut -f1) total"
