#!/bin/bash
# Builds a local apt repository from a target's package list.
# Runs inside a container matching the target's base image and architecture.
#
#   PKG_LIST   package list, one name per line, # comments  [/prov/packages.txt]
#   OUT        output archive directory                     [/out]
#   EMULATED   1 when running under qemu-user               [0]
#
#   docker run --rm --platform <p> -v <common>:/common:ro -v <prov>:/prov:ro \
#       -v <debs>:/out -e EMULATED=<0|1> <base> bash /common/fetch_debs.sh
#
# Output is a `deb [trusted=yes] file:/debs ./` repository: the .deb closure
# plus a dpkg-scanpackages index. The image installs from it with --network=none.
set -eu
export DEBIAN_FRONTEND=noninteractive
. /common/container_prelude.sh

PKG_LIST="${PKG_LIST:-/prov/packages.txt}"
OUT="${OUT:-/out}"
EMULATED="${EMULATED:-0}"

prelude_network
[ "$EMULATED" = "1" ] && prelude_ldconfig_stub on

PKGS=$(grep -vE '^[[:space:]]*(#|$)' "$PKG_LIST" | tr '\n' ' ')
echo "[debs] arch=$(dpkg --print-architecture) emulated=$EMULATED"
echo "[debs] packages: $PKGS"

apt-get update -qq
apt-get install -y --no-install-recommends --download-only $PKGS

# FAILURE MODE - pulling dpkg-dev before the payload is moved out puts
# dpkg-dev's own .debs in the archive, and the offline image then installs a
# build toolchain it never asked for. Order is load-bearing.
mkdir -p "$OUT"
cp -n /var/cache/apt/archives/*.deb "$OUT"/
echo "[debs] downloaded $(find "$OUT" -name '*.deb' | wc -l) packages"

apt-get install -y --no-install-recommends dpkg-dev >/dev/null
cd "$OUT"
dpkg-scanpackages --multiversion . /dev/null > Packages 2>/dev/null
gzip -9c Packages > Packages.gz

[ "$EMULATED" = "1" ] && prelude_ldconfig_stub off
echo "[debs] index: $(grep -c '^Package:' Packages) entries, $(du -sh "$OUT" | cut -f1)"
