#!/bin/bash
# Turns an UmbrelOS 2.0 ARM64 image built with ../umbrel-patch into an image that boots on the
# Home Assistant Green (RK3566), from microSD or from the internal eMMC.
#
# Usage: build-green-image.sh <umbrelos-arm64.img> <nabu u-boot-rockchip.bin> <output.img>
#
# Changes made to a copy of the input:
#  1. Nabu Casa's Green U-Boot replaces the image bootloader (sector 64, before partition 1).
#  2. GRUB is bypassed: the kernel and initrd from the boot partition are copied to the FAT
#     partition and booted with /extlinux/extlinux.conf. GRUB's EFI program never ran its
#     config under this U-Boot.
#  3. The kernel gets the `gpt` argument, so Linux falls back to the backup GPT. Windows
#     rewrites the primary GPT header of SD cards it sees, which leaves Linux with no partitions.
#  4. SDR104 is removed from the SD controller in the device tree. Tuning at SDR104 failed on
#     some boots ("All phases bad"); the card then runs at 50 MHz high speed.
#
# Needs: sgdisk, debugfs, mtools, fdtput (device-tree-compiler).
set -euo pipefail
SRC=${1:?input image}; UB=${2:?u-boot-rockchip.bin}; OUT=${3:?output image}
P1_SECTOR=34816        # FAT partition start in the UmbrelOS image
P2_SECTOR=559104       # slot A boot partition (kernel, initrd)
P2_SECTORS=1048576
export MTOOLS_SKIP_CHECK=1
P1="@@$((P1_SECTOR * 512))"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

[ "$(sgdisk -i 1 "$SRC" | awk '/First sector/ {print $3}')" = "$P1_SECTOR" ] || { echo "unexpected partition layout"; exit 1; }
ROOT_UUID=$(sgdisk -i 4 "$SRC" | awk '/Partition unique GUID/ {print tolower($4)}')
cp "$SRC" "$OUT"

# 1. Bootloader
dd if=/dev/zero of="$OUT" bs=512 seek=64 count=$((P1_SECTOR - 64)) conv=notrunc status=none
dd if="$UB" of="$OUT" bs=512 seek=64 conv=notrunc status=none

# 2. Kernel and initrd onto the FAT partition, extlinux config
dd if="$OUT" bs=512 skip=$P2_SECTOR count=$P2_SECTORS status=none of="$W/p2.img"
debugfs -R "dump /vmlinuz $W/Image" "$W/p2.img" 2>/dev/null
debugfs -R "dump /initrd.img $W/initrd.img" "$W/p2.img" 2>/dev/null
rm -f "$W/p2.img"
cat > "$W/extlinux.conf" <<CONF
default umbrelos
timeout 1

label umbrelos
  kernel /umbrel/Image
  devicetree /rockchip/rk3566-ha-green.dtb
  initrd /umbrel/initrd.img
  append console=ttyS2,1500000n8 console=tty0 loglevel=7 panic=0 module_blacklist=esp4,esp6,rxrpc initcall_blacklist=esp4_init,esp6_init,af_rxrpc_init gpt ro init=/usr/bin/rugix-ctrl root=PARTUUID=$ROOT_UUID
CONF
mmd -i "$OUT$P1" ::/umbrel ::/extlinux
mcopy -i "$OUT$P1" "$W/Image" "$W/initrd.img" ::/umbrel/
mcopy -i "$OUT$P1" "$W/extlinux.conf" ::/extlinux/extlinux.conf
mren -i "$OUT$P1" ::/EFI/BOOT/BOOTAA64.efi ::/EFI/BOOT/BOOTAA64.efi.disabled
mren -i "$OUT$P1" ::/boot.scr ::/boot.scr.disabled

# 4. Device tree: no SDR104 on the SD slot
mcopy -n -i "$OUT$P1" ::/rockchip/rk3566-ha-green.dtb "$W/green.dtb"
fdtput -d "$W/green.dtb" /mmc@fe2b0000 sd-uhs-sdr104
mcopy -o -i "$OUT$P1" "$W/green.dtb" ::/rockchip/rk3566-ha-green.dtb

# Checks
cmp -n "$(stat -c %s "$UB")" "$UB" <(dd if="$OUT" bs=512 skip=64 status=none) && echo "bootloader ok"
mcopy -n -i "$OUT$P1" ::/umbrel/Image - | cmp - "$W/Image" && echo "kernel ok"
mcopy -n -i "$OUT$P1" ::/umbrel/initrd.img - | cmp - "$W/initrd.img" && echo "initrd ok"
sgdisk -v "$OUT" | tail -1
sha256sum "$OUT" | tee "$OUT.sha256"
