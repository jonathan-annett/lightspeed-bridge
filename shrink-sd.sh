#!/bin/bash
# shrink-sd.sh — compact the appliance SD card so the image fits an 8 GB card.
#
# RUN ON THE PI, BOOTED FROM ANOTHER DEVICE (the original USB stick), with the SD card
# hot-inserted and NOT mounted. Refuses to touch the disk it booted from.
#
# Before:  p1 boot 512 MiB | p2 rootfs 14.1 GiB (4.0 GiB used) | p3 gaindata 64 MiB @ 14.6 GiB
# After:   p1 boot 512 MiB | p2 rootfs 6 GiB               | p3 gaindata 64 MiB right after
# Total after: 13,778,944 sectors = 7,054,819,328 bytes (6.57 GiB).
# PARTUUIDs are preserved (same disklabel id): cmdline root= and fstab keep working.
# Also deploys the pending gain-control.py (fast-poll tweak) into the SD rootfs if
# /tmp/gain-control.py is present.
set -euo pipefail
DISK=/dev/mmcblk0
P1=${DISK}p1; P2=${DISK}p2; P3=${DISK}p3
ROOT_GIB=6
P2_START=1064960
P2_SIZE=$(( ROOT_GIB * 1024 * 1024 * 1024 / 512 ))     # 12582912 sectors
P3_START=$(( P2_START + P2_SIZE ))                       # 13647872 (2048-aligned)
P3_SIZE=131072
say() { echo; echo "### $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"
[ -b "$DISK" ] || die "$DISK not present — insert the SD card"
case "$(findmnt -no SOURCE /)" in *mmcblk0*) die "booted from $DISK — boot from the USB stick instead";; esac
findmnt -no SOURCE | grep -q mmcblk0 && die "something on $DISK is mounted — unmount it first"
sfdisk -d "$DISK" | grep -q "^$P2 : start= *$P2_START," || die "unexpected partition table (p2 start != $P2_START)"
sfdisk -d "$DISK" | grep -q "^$P3 " || die "p3 (gaindata) missing — nothing to do?"
say "current table"; sfdisk -d "$DISK"

say "1. save gaindata contents"; mkdir -p /tmp/gaindata; mount -o ro "$P3" /mnt; cp -a /mnt/offset.json /tmp/gaindata/ 2>/dev/null || echo "(no offset.json)"; umount /mnt; ls -la /tmp/gaindata

say "2. fsck + shrink rootfs to ${ROOT_GIB} GiB"; e2fsck -f -y "$P2" || [ $? -le 1 ]
resize2fs "$P2" "${ROOT_GIB}G"
BLOCKS=$(tune2fs -l "$P2" | awk '/^Block count/{print $3}'); [ "$BLOCKS" = $(( P2_SIZE / 8 )) ] || die "fs block count $BLOCKS != expected $(( P2_SIZE / 8 ))"

say "3. rewrite partition table (same label-id -> same PARTUUIDs)"
LABEL_ID=$(sfdisk -d "$DISK" | awk '/^label-id/{print $2}')
sfdisk --no-reread --no-tell-kernel "$DISK" <<TABLE
label: dos
label-id: $LABEL_ID
unit: sectors
$P1 : start=16384, size=1048576, type=c
$P2 : start=$P2_START, size=$P2_SIZE, type=83
$P3 : start=$P3_START, size=$P3_SIZE, type=83
TABLE
partprobe "$DISK"; sleep 1; sfdisk -d "$DISK"

say "4. recreate gaindata"; mkfs.ext4 -q -F -L gaindata -m 0 "$P3"; mount "$P3" /mnt; chown 1000:1000 /mnt
[ -f /tmp/gaindata/offset.json ] && cp -a /tmp/gaindata/offset.json /mnt/ && chown 1000:1000 /mnt/offset.json; ls -la /mnt; umount /mnt

say "5. verify rootfs, deploy pending gain-control.py if provided"; e2fsck -f -n "$P2" >/dev/null && echo "rootfs clean"
if [ -f /tmp/gain-control.py ]; then mount "$P2" /mnt; install -m 755 -o 1000 -g 1000 /tmp/gain-control.py /mnt/home/jonathan/.local/bin/gain-control.py; sha256sum /mnt/home/jonathan/.local/bin/gain-control.py; umount /mnt; fi
sync
IMG_BYTES=$(( (P3_START + P3_SIZE) * 512 ))
say "DONE. Image length to capture: $(( P3_START + P3_SIZE )) sectors = $IMG_BYTES bytes"
echo "capture from this Pi:  sudo dd if=$DISK bs=524288 count=$(( IMG_BYTES / 524288 )) status=progress | zstd -T0 -12 > /tmp/lightspeed-bridge-8gb.img.zst"
