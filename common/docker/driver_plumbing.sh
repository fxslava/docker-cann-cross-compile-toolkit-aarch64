#!/bin/sh
# Creates the accounts and directories the Ascend driver's helper daemons
# expect. Run once per image, after the toolkit install.
#
#   sh /tmp/driver_plumbing.sh
#
# PRECONDITION - the uid/gid values below match a stock Ascend host install.
# They are fixed, not arbitrary: bind-mounted device nodes carry host ownership,
# and a mismatch makes /dev/davinci* unopenable inside the container.
#
# /usr/local/Ascend/driver/lib64 is created empty on purpose. The host driver is
# bind-mounted over it at run time; nothing ships it in the image.
#
# The /lib64 symlink is required on arm64 only - driver binaries are linked
# against /lib64/ld-linux-aarch64.so.1, which Ubuntu arm64 does not create.
# amd64 already has /lib64, so the guard makes this a no-op there.
set -eu

mkdir -m 750 -p /var/driver /var/dmp /usr/slog /home/drv/hdc_ppc /var/log/npu/slog
mkdir -m 755 -p /usr/local/Ascend/driver/lib64
[ -e /lib64 ] || ln -sf /lib /lib64

groupadd -g 1000 HwHiAiUser && useradd -u 1000 -g HwHiAiUser -d /home/HwHiAiUser -m HwHiAiUser
groupadd -g 1101 HwDmUser   && useradd -u 1101 -g HwDmUser   -d /home/HwDmUser   -m HwDmUser
groupadd -g 1102 HwBaseUser && useradd -u 1102 -g HwBaseUser -d /home/HwBaseUser -m HwBaseUser
groupadd -g 1100 HwSysUser  && useradd -u 1100 -g HwSysUser  -d /home/HwSysUser  -m HwSysUser
usermod -a -G HwBaseUser HwHiAiUser
usermod -a -G HwDmUser   HwHiAiUser

chown HwDmUser:HwDmUser     /var/dmp
chown HwHiAiUser:HwHiAiUser /var/driver /usr/slog /home/drv/hdc_ppc /var/log/npu/slog
ldconfig
