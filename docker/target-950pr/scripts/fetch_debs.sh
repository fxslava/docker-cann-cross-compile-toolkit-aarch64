#!/bin/bash
# ---------------------------------------------------------------------------
# Runs INSIDE an ubuntu:22.04 container (NATIVELY - this target is amd64, so
# there is no QEMU and none of the ldconfig stubbing the 310P script needs).
# Downloads the amd64 .deb closure listed in /prov/packages.txt and writes a
# local apt repository index next to it in /out, so Dockerfile.x86_64 can
# apt-get install from file:/debs with --network=none.
#
#   docker run --platform linux/amd64 -v <prov>:/prov:ro -v <debs>:/out \
#       ubuntu:22.04 bash /prov/fetch_debs.sh
#
# The container must be jammy, not noble: the .debs have to match the base
# image the offline build installs them into. clang-15 comes from
# jammy-updates (1:15.0.7-0ubuntu0.22.04.3), which stock ubuntu:22.04 enables.
# ---------------------------------------------------------------------------
set -eu
export DEBIAN_FRONTEND=noninteractive

# Prefer IPv4: this host publishes AAAA records with no working IPv6 route, and
# apt's http method waits on them. See build_vllm_wheel.sh for the full story.
printf 'precedence ::ffff:0:0/96  100\n' >> /etc/gai.conf

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

echo "[debs] index: $(grep -c '^Package:' Packages) entries, $(du -sh /out | cut -f1) total"
