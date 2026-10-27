#!/bin/bash
# Applies the UmbrelOS changes to the Nabu installer overlay and rebuilds.
set -e
S=/home/jener/nabu-installer/src
U=/mnt/c/Users/jener/Documents/Codex/2026-10-22/i-x20/work/umbrel-installer
O=$S/buildroot-external/board/nabucasa/green/rootfs-overlay
install -m 0755 "$U/umbrel-flash" "$O/usr/bin/umbrel-flash"
install -m 0644 "$U/install-autostart.service" "$O/usr/lib/systemd/system/install-autostart.service"
sed -i 's/\r$//' "$O/usr/bin/umbrel-flash" "$O/usr/lib/systemd/system/install-autostart.service"
sed -i 's/^BR2_TARGET_GENERIC_HOSTNAME=.*/BR2_TARGET_GENERIC_HOSTNAME="green-umbrel-installer"/' "$S/buildroot-external/configs/green_installer_defconfig"
cd "$S"
git status --short
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
make green_installer > /home/jener/nabu-umbrel-build.log 2>&1
echo "EXIT=$?"
tail -5 /home/jener/nabu-umbrel-build.log
T=$S/output/green_installer/target
ls -l "$T/usr/bin/umbrel-flash"
grep ExecStart "$T/usr/lib/systemd/system/install-autostart.service"
ls -l "$S/output/green_installer/images/boot.img.xz"
sha256sum "$S/output/green_installer/images/boot.img.xz"
