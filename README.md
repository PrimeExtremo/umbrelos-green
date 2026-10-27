# UmbrelOS on the Home Assistant Green

Scripts and notes for running **UmbrelOS 2.0** on a **Home Assistant Green** (Rockchip RK3566, 4 GB RAM, 32 GB eMMC), installed on the internal eMMC so no SD card is needed.

This is a community project. It is not affiliated with Umbrel or Nabu Casa. Use at your own risk.

> **Installing erases Home Assistant from the Green.** Make a Home Assistant backup first if you want to keep your setup.
> The Green can always be returned to Home Assistant with Nabu Casa's official microSD installer. The Green boots from microSD before eMMC, so a broken eMMC install is recoverable.

## Status

Tested on one Green (October 2026):

- UmbrelOS boots from the internal eMMC with no SD card and the web UI works at `http://umbrel.local`.
- Known issue from earlier testing: **Restart** in the Umbrel UI may leave the box unreachable. Unplug power for 15 seconds and plug it back in.
- Not yet verified: UmbrelOS over-the-air updates. An update may replace the boot files this port depends on.

## What had to change

| Problem | Fix |
|---|---|
| UmbrelOS has no Green bootloader | Nabu Casa's Green U-Boot from [NabuCasa/buildroot-installer](https://github.com/NabuCasa/buildroot-installer), written at sector 64 |
| GRUB (EFI) never ran its config under that U-Boot | Boot the kernel directly with `/extlinux/extlinux.conf` on the FAT partition |
| Windows rewrites the primary GPT header of any SD card it sees, so Linux finds no partitions | Kernel argument `gpt`, so Linux uses the backup GPT |
| SD card tuning at SDR104 fails on some boots (`All phases bad`) | Remove `sd-uhs-sdr104` from the SD controller in the device tree |

## Repository layout

- `umbrel-patch/` — patch for the UmbrelOS 2.0.0 source (commit `9298257b`) that adds a Green board layer, and the script that builds the ARM64 image.
- `image/build-green-image.sh` — turns that UmbrelOS image into a Green image (bootloader, extlinux, `gpt`, device tree).
- `installer/` — eMMC installer built on Nabu Casa's buildroot-installer. `umbrel-flash` replaces `haos-flash`: it reads the UmbrelOS image from a raw region 1 GiB into the SD card, checks its SHA-256, writes it to the eMMC, reads the eMMC back, then powers off. `test-umbrel-flash.sh` tests it on a PC.
- `windows/` — guarded PowerShell writers used to put the installer and the image on the SD card. They refuse to run unless the disk matches a hard-coded USB card ID, size and path: **edit those values for your own card reader before use.**

No disk images are included. UmbrelOS is under its own license, so build the image yourself.

## Build

Linux (or WSL2) with Docker, Buildroot prerequisites, `sgdisk`, `debugfs`, `mtools` and `device-tree-compiler`.

1. **UmbrelOS ARM64 image**: check out Umbrel at commit `9298257b0e904ca8d8270b1702672666343f0b86`, apply `umbrel-patch/umbrel-green-experimental.patch`, and build with `umbrel-patch/build-arm64-baseline.sh` (adjust it to allow the patched tree).
2. **Nabu U-Boot and installer**: clone [NabuCasa/buildroot-installer](https://github.com/NabuCasa/buildroot-installer) and build it once with `make green_installer`. This produces `output/green_installer/images/u-boot-rockchip.bin`.
3. **Green image**:
   ```bash
   bash image/build-green-image.sh umbrelos-arm64.img u-boot-rockchip.bin umbrelos-green.img
   ```
4. **Installer**: put the SHA-256 printed in step 3 into `UMBREL_IMAGE_SHA256` in `installer/umbrel-flash`, and its size in MiB (rounded up) into `UMBREL_IMAGE_MIB`. Edit the paths in `installer/apply-overlay.sh`, then run it. It copies `umbrel-flash` and the autostart unit into the installer overlay and rebuilds. Run `installer/test-umbrel-flash.sh` to test the flash script.

## Install

1. Write the installer image (`output/green_installer/images/boot.img.xz`, decompressed) to the start of a microSD card of at least 16 GB.
2. Write the UmbrelOS Green image to the same card **at byte offset 1 GiB (1073741824)**, without touching the installer. `windows/write-umbrel-region.ps1` does this and verifies it; on Linux use `dd if=umbrelos-green.img of=/dev/sdX bs=1M seek=1024 conv=fsync`.
3. Unplug the Green, insert the card, power on. The LED blinks fast while it verifies and copies UmbrelOS (10–20 minutes).
4. When the LED stays solid and the Green powers off, remove the card and power on again. If the LED turns off and the Green stays on, the install failed: the eMMC was not written or failed verification.
5. Open `http://umbrel.local`.

## Testing from SD first (optional)

The Green image also boots straight from microSD (write it at offset 0). That runs UmbrelOS without touching the eMMC.

## Back to Home Assistant

Write Nabu Casa's official Green installer (from the [buildroot-installer releases](https://github.com/NabuCasa/buildroot-installer/releases)) to a microSD card and boot from it. It reinstalls Home Assistant OS on the eMMC.

## Credits

- [Umbrel](https://github.com/getumbrel/umbrel) — UmbrelOS
- [Nabu Casa](https://github.com/NabuCasa/buildroot-installer) — Green U-Boot, kernel and the installer this is built on
