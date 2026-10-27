#!/bin/bash
# Runs umbrel-flash against small stand-in files: 2 MiB offset, 3 MiB image.
set -u
U=/mnt/c/Users/jener/Documents/Codex/2026-10-22/i-x20/work/umbrel-installer
t=$(mktemp -d)
head -c $((3*1024*1024)) /dev/urandom > "$t/image"
SHA=$(sha256sum "$t/image" | cut -d' ' -f1)
mk_sd() { head -c $((8*1024*1024)) /dev/zero > "$t/sd"; dd if="$t/image" of="$t/sd" bs=1M seek=2 conv=notrunc status=none; }
mk() { # build a test copy of the script pointed at files
  sed -e "s#^SD_DEV=.*#SD_DEV=$t/sd#" -e "s#^EMMC_DEV=.*#EMMC_DEV=$t/emmc#" \
      -e "s#^UMBREL_SD_OFFSET_MIB=.*#UMBREL_SD_OFFSET_MIB=2#" -e "s#^UMBREL_IMAGE_MIB=.*#UMBREL_IMAGE_MIB=3#" \
      -e "s#^UMBREL_IMAGE_SHA256=.*#UMBREL_IMAGE_SHA256=$1#" \
      -e "s#/sys/class/leds/user/[a-z_]*#/dev/null#g" -e "s#^\(\t*\)poweroff#\1echo POWEROFF#" \
      -e 's#\[ ! -b "\$SD_DEV" \] || \[ ! -b "\$EMMC_DEV" \]#[ ! -e "$SD_DEV" ] || [ ! -e "$EMMC_DEV" ]#' \
      "$U/umbrel-flash" > "$t/flash"; }
pass=0; fail=0
ck() { if [ "$1" = "$2" ]; then pass=$((pass+1)); echo "PASS $3"; else fail=$((fail+1)); echo "FAIL $3 (want $2 got $1)"; fi; }

# 1: good image -> written, verified, poweroff
mk_sd; head -c $((8*1024*1024)) /dev/zero > "$t/emmc"; mk "$SHA"
out=$(busybox ash "$t/flash" 2>&1); rc=$?
ck "$rc" 0 "good: exit 0"
ck "$(echo "$out" | grep -c POWEROFF)" 1 "good: powers off"
ck "$(head -c $((3*1024*1024)) "$t/emmc" | sha256sum | cut -d' ' -f1)" "$SHA" "good: eMMC holds image"

# 2: wrong expected hash -> refuses, eMMC untouched
mk_sd; head -c $((8*1024*1024)) /dev/zero > "$t/emmc"; cp "$t/emmc" "$t/emmc.before"; mk 0000
out=$(busybox ash "$t/flash" 2>&1); rc=$?
ck "$rc" 1 "bad hash: exit 1"
ck "$(cmp -s "$t/emmc" "$t/emmc.before" && echo same)" same "bad hash: eMMC untouched"
ck "$(echo "$out" | grep -c POWEROFF)" 0 "bad hash: no poweroff"

echo "pass=$pass fail=$fail"
rm -rf "$t"
