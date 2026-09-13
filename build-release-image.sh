#!/bin/bash
# build-release-image.sh — build a SANITISED, publishable image of this appliance.
#
# Run ON THE PI, as root, while booted normally from the appliance's own SD card or USB
# stick (overlay on is fine: the lower root is mounted read-only at /media/root-ro and is
# copied from there). Nothing on the boot device is modified except that a temporary
# 8 GiB work partition (#4) is created in the free space after gaindata; remove it
# afterwards with: umount /mnt/relwork; parted -s <disk> rm 4
# Runs rsync/zstd at low CPU+IO priority with 2 zstd threads and logs `free -m` every
# 30 s — the first attempt coincided with a dying SD card and was never diagnosed beyond
# that, so this keeps the box responsive and leaves evidence.
#
# What the release image is:
#   p1 boot     byte copy of the card's boot partition, then: overlayroot=tmpfs and the
#               imager's ds=nocloud removed from cmdline.txt; user-data/network-config/
#               meta-data deleted (cloud-init is disabled anyway and user-data carries
#               the original password hash)
#   p2 rootfs   fresh ext4, rsync of the running root MINUS: apt caches, shell history,
#               ~/.ssh, ~/.cache, ssh host keys, DHCP leases, random seed, machine-id
#               ALSO minus /var/swap (1.9 GB stock swap file; unusable under the overlay,
#               zram is used) with dphys-swapfile disabled, and minus /var/lib/cloud
#               (cloud-init's cached copy of the imager config: name, email, ssh key, hash)
#               A scrub grep for the author's name/email/keys outside /usr FAILS the build.
#               then: user renamed to $NEWUSER (uid 1000 kept), password $NEWPASS,
#               sudoers + linger renamed, gain-control unit made username-agnostic (%h),
#               lightspeed-firstboot.service installed + enabled
#   p3 gaindata fresh, offset 0
# The overlay is OFF in the release; lightspeed-firstboot.service turns it on after the
# first boot has generated host keys, and reboots. No login needed. See README.
# Needs lightspeed-firstboot.service next to this script (or in /tmp).
set -euo pipefail
NEWUSER=lightspeedpi; NEWPASS=lightspeedpi; OLDUSER=jonathan
SRC=/media/root-ro
ROOTDEV=$(findmnt -no SOURCE $SRC)                      # e.g. /dev/mmcblk0p2 or /dev/sda2
DISK=${ROOTDEV%p2}; [ "$DISK" = "$ROOTDEV" ] && DISK=${ROOTDEV%2}
part() { case "$DISK" in *[0-9]) echo "${DISK}p$1";; *) echo "${DISK}$1";; esac; }   # mmcblk0p1 vs sda1
WORKPART=$(part 4)
IMG_SECTORS=13778944; IMG_BYTES=$(( IMG_SECTORS * 512 ))
WORK=/mnt/relwork; IMG=$WORK/release.img; OUT=$WORK/lightspeed-bridge-8gb-release.img.zst
say() { echo; echo "### $*"; }; die() { echo "FATAL: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
[ -b "$DISK" ] && [ "$(findmnt -no FSTYPE /)" = overlay ] || die "expected to be booted from $DISK with the overlay on"
echo "boot device: $DISK  (root $ROOTDEV)  work partition: $WORKPART"
which openssl rsync losetup mkfs.ext4 sfdisk zstd >/dev/null || die "missing tool"
cleanup() { set +e; kill ${MEMLOG:-} 2>/dev/null; umount $WORK/p1 $WORK/p2 $WORK/p3 2>/dev/null; [ -n "${LOOP:-}" ] && losetup -d $LOOP 2>/dev/null; }
trap cleanup EXIT

say "1. work partition"
if [ ! -b $WORKPART ]; then
  parted -s -a optimal $DISK mkpart primary ext4 6728MiB 14920MiB; partprobe $DISK; sleep 1
  mkfs.ext4 -q -F -L relwork $WORKPART
fi
mkdir -p $WORK; mountpoint -q $WORK || mount $WORKPART $WORK; df -h $WORK | tail -1

say "2. sparse image + partition table (same geometry and PARTUUIDs as the card)"
rm -f $IMG; truncate -s $IMG_BYTES $IMG
LABEL_ID=$(sfdisk -d $DISK | awk '/^label-id/{print $2}')
sfdisk -q $IMG <<TABLE
label: dos
label-id: $LABEL_ID
unit: sectors
start=16384, size=1048576, type=c
start=1064960, size=12582912, type=83
start=13647872, size=131072, type=83
TABLE
LOOP=$(losetup -P -f --show $IMG); sleep 1; ls ${LOOP}p1 ${LOOP}p2 ${LOOP}p3 >/dev/null
mkdir -p $WORK/p1 $WORK/p2 $WORK/p3

say "3. boot partition: byte copy, then strip overlay + cloud-init"
dd if=$(part 1) of=${LOOP}p1 bs=4M status=none; mount ${LOOP}p1 $WORK/p1
sed -i -E 's/overlayroot=tmpfs *//; s/ *ds=nocloud[^ ]*//' $WORK/p1/cmdline.txt; cat $WORK/p1/cmdline.txt
rm -f $WORK/p1/user-data $WORK/p1/network-config $WORK/p1/meta-data
umount $WORK/p1

say "4. rootfs: fresh ext4 + rsync (this is the slow part)"
mkfs.ext4 -q -F -L rootfs ${LOOP}p2; mount ${LOOP}p2 $WORK/p2
( while sleep 30; do echo "[mem] $(free -m | awk 'NR==2{print "used "$3" free "$4" avail "$7" MB"}')"; done ) & MEMLOG=$!
nice -n 19 ionice -c3 rsync -aHAX --numeric-ids -x --stats \
  --exclude='/var/swap' \
  --exclude='/var/cache/apt/archives/*.deb' --exclude='/var/cache/apt/*.bin' --exclude='/var/lib/apt/lists/*' \
  --exclude='/home/*/.bash_history' --exclude='/home/*/.ssh' --exclude='/home/*/.cache' --exclude='/home/*/.sudo_as_admin_successful' \
  --exclude='/root/.bash_history' --exclude='/root/.ssh' --exclude='/etc/ssh/ssh_host_*' \
  --exclude='/var/lib/NetworkManager/*.lease' --exclude='/var/lib/systemd/random-seed' --exclude='/var/lib/systemd/timesync/*' \
  --exclude='/var/log/*' --exclude='/tmp/*' --exclude='/var/tmp/*' --exclude='/etc/machine-id' \
  --exclude='/var/lib/cloud/*' \
  $SRC/ $WORK/p2/
mkdir -p $WORK/p2/var/lib/apt/lists/partial $WORK/p2/var/cache/apt/archives/partial $WORK/p2/var/log
: > $WORK/p2/etc/machine-id                 # empty => systemd "first boot" => host keys regenerated

say "5. rename $OLDUSER -> $NEWUSER (if present), default password, sudoers, linger, unit"
R=$WORK/p2
if [ -d $R/home/$OLDUSER ]; then          # building from the original private box
  for f in passwd shadow group gshadow subuid subgid; do sed -i -E "s/\b$OLDUSER\b/$NEWUSER/g" $R/etc/$f; done
  sed -i -E "s#/home/$OLDUSER#/home/$NEWUSER#" $R/etc/passwd
  mv $R/home/$OLDUSER $R/home/$NEWUSER
  [ -e $R/var/lib/systemd/linger/$OLDUSER ] && mv $R/var/lib/systemd/linger/$OLDUSER $R/var/lib/systemd/linger/$NEWUSER
else                                       # building from a box that already runs the release (dogfooding)
  [ -d $R/home/$NEWUSER ] || die "neither /home/$OLDUSER nor /home/$NEWUSER in the source"
  echo "  source already uses $NEWUSER — no rename"
fi
for f in passwd shadow group gshadow subuid subgid; do rm -f $R/etc/$f-; done   # the *- backups hold old hashes
HASH=$(openssl passwd -6 "$NEWPASS")
awk -F: -v u=$NEWUSER -v h="$HASH" 'BEGIN{OFS=":"} $1==u {$2=h} {print}' $R/etc/shadow > $R/etc/shadow.new && cat $R/etc/shadow.new > $R/etc/shadow && rm $R/etc/shadow.new
rm -f $R/etc/sudoers.d/010_${OLDUSER}-nopasswd; printf '%s ALL=(ALL) NOPASSWD: ALL\n' $NEWUSER > $R/etc/sudoers.d/010_${NEWUSER}-nopasswd; chmod 0440 $R/etc/sudoers.d/010_${NEWUSER}-nopasswd
[ -e $R/var/lib/systemd/linger/$NEWUSER ] || die "linger file for $NEWUSER missing"
sed -i -E "s#ExecStart=/home/[^/]+/#ExecStart=%h/#" $R/home/$NEWUSER/.config/systemd/user/gain-control.service
rm -f $R/etc/systemd/system/multi-user.target.wants/dphys-swapfile.service     # no swap file in the release
UNIT=$(dirname "$0")/lightspeed-firstboot.service; [ -f "$UNIT" ] || UNIT=/tmp/lightspeed-firstboot.service; [ -f "$UNIT" ] || die "lightspeed-firstboot.service not found"
install -m 644 "$UNIT" $R/etc/systemd/system/lightspeed-firstboot.service
ln -sf ../lightspeed-firstboot.service $R/etc/systemd/system/multi-user.target.wants/lightspeed-firstboot.service
rm -f $R/var/lib/lightspeed-firstboot-done
# SSH: Raspberry Pi Imager disables password login when it installs an SSH key (a drop-in
# under sshd_config.d). The release has no keys, so password login MUST work. sshd takes the
# FIRST value it sees for a keyword and Includes sshd_config.d/*.conf before its own body, so
# a 00- drop-in wins over anything else; the imager/cloud-init drop-ins are removed anyway.
rm -f $R/etc/ssh/sshd_config.d/50-cloud-init.conf $R/etc/ssh/sshd_config.d/rename_user.conf
printf 'PasswordAuthentication yes\nKbdInteractiveAuthentication yes\n' > $R/etc/ssh/sshd_config.d/00-lightspeed-password-login.conf
echo "  sshd drop-ins now: $(ls $R/etc/ssh/sshd_config.d/ | tr '\n' ' ')"; grep -rn "PasswordAuthentication" $R/etc/ssh/sshd_config $R/etc/ssh/sshd_config.d/ | sed 's/^/    /'
# Install the repo's current status-screen unit too (system unit; source box may lag)
SS=$(dirname "$0")/gain-status-screen.service; [ -f "$SS" ] || SS=/tmp/gain-status-screen.service
[ -f "$SS" ] && install -m 644 "$SS" $R/etc/systemd/system/gain-status-screen.service && echo "  installed gain-status-screen.service from $SS"
# Install the repo's current daemon (the source box may lag behind it)
GC=$(dirname "$0")/gain-control.py; [ -f "$GC" ] || GC=/tmp/gain-control.py
[ -f "$GC" ] && install -m 755 -o 1000 -g 1000 "$GC" $R/home/$NEWUSER/.local/bin/gain-control.py && echo "  installed gain-control.py from $GC"
# Hard scrub check: the old user's home path and account line, plus any patterns in a
# gitignored scrub-patterns.txt next to this script (one extended-regex per line: put your
# email address, an SSH public-key fragment, etc. there — NOT in this public script), must
# not appear anywhere outside /usr. (Cloud-init's cached instance data once carried the
# author's email and key.) A bare search for a first name or "gmail.com" is NOT fatal —
# Debian package metadata is full of maintainers with Gmail addresses — it is printed for
# a human to eyeball.
FATAL_PAT="/home/$OLDUSER|^$OLDUSER:"
SCRUB_FILE=$(dirname "$0")/scrub-patterns.txt; [ -f "$SCRUB_FILE" ] || SCRUB_FILE=/tmp/scrub-patterns.txt
if [ -f "$SCRUB_FILE" ]; then FATAL_PAT="$FATAL_PAT|$(grep -vE '^\s*(#|$)' "$SCRUB_FILE" | paste -sd'|' -)"; echo "  scrub patterns: $(grep -cvE '^\s*(#|$)' "$SCRUB_FILE") from $SCRUB_FILE"; else echo "  WARNING: no scrub-patterns.txt — only the old user's paths are checked"; fi
if HITS=$(grep -rIlE "$FATAL_PAT" $R/etc $R/home $R/var $R/root $R/opt $R/boot 2>/dev/null); [ -n "$HITS" ]; then
  echo "$HITS" | sed 's/^/  SCRUB FAILED: /'; die "personal data still present in the release rootfs — fix the exclusions"
fi
echo "  scrub check passed (no personal data outside /usr)"
echo "  bare-name mentions outside /usr and /var/lib/dpkg (expect Debian metadata only):"
grep -rIlw "$OLDUSER" $R/etc $R/home $R/var $R/root $R/opt $R/boot 2>/dev/null | grep -vE "/var/lib/dpkg/|/var/cache/debconf/|/var/backups/dpkg" | sed 's/^/    /' || echo "    (none)"
grep -E "^$NEWUSER" $R/etc/passwd; grep -E "^$NEWUSER" $R/etc/shadow | cut -d: -f1,3,4; cat $R/home/$NEWUSER/.config/systemd/user/gain-control.service | grep ExecStart
umount $WORK/p2; e2fsck -f -n ${LOOP}p2 | tail -1

say "6. gaindata"
mkfs.ext4 -q -F -L gaindata -m 0 ${LOOP}p3; mount ${LOOP}p3 $WORK/p3; echo '{"offset": 0.0}' > $WORK/p3/offset.json; chown -R 1000:1000 $WORK/p3; umount $WORK/p3

losetup -d $LOOP; LOOP=
say "7. compress"
nice -n 19 ionice -c3 zstd -T2 -9 -q -f -o $OUT $IMG; rm -f $IMG
kill $MEMLOG 2>/dev/null || true
(cd $WORK && sha256sum $(basename $OUT) | tee $(basename $OUT).sha256); ls -la $OUT
say "DONE: $OUT"
echo "(work partition kept until the file has been copied off; remove with: umount $WORK; parted -s $DISK rm 4)"
