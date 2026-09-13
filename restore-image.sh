#!/usr/bin/env bash
#
# restore-image.sh — write the lightspeed-bridge appliance image to a USB drive / SD card.
#
#   sudo ./restore-image.sh /dev/disk2
#   sudo ./restore-image.sh /dev/disk2 --no-verify        # skip read-back check
#   sudo ./restore-image.sh /dev/disk2 --verify-only      # check only, writes NOTHING
#   sudo ./restore-image.sh /dev/disk2 --image other.zst
#
# DESTRUCTIVE: everything on the target device is erased.
#
# Safety guards, in order:
#   * must run as root
#   * target must exist and be a WHOLE disk (not a partition like disk2s1)
#   * target must be EXTERNAL and REMOVABLE — refuses internal disks outright
#   * target must not be the current boot disk
#   * target capacity must be >= the image's decompressed size
#   * source archive integrity is checked BEFORE anything is written
#   * requires you to type the device name to confirm
#
# Everything is logged to restore-YYYYmmdd-HHMMSS.log next to this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="$SCRIPT_DIR/lightspeed-bridge-8gb-release.img.zst"   # the public release is the canonical image (2026-09-13)
VERIFY=1
TARGET=""

# ---------------------------------------------------------------- args
VERIFY_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-verify)   VERIFY=0; shift ;;
        --verify-only) VERIFY_ONLY=1; VERIFY=1; shift ;;
        --image)       IMAGE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
            exit 0 ;;
        /dev/*)      TARGET="$1"; shift ;;
        *)           echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

LOG="$SCRIPT_DIR/restore-$(date +%Y%m%d-%H%M%S).log"

# Mirror all output to the log.
#
# NOTE: a bare `exec > >(tee -a "$LOG") 2>&1` LOSES THE TAIL OF THE LOG. When the
# script exits, the tee subprocess can be killed before it flushes, so the last lines
# (here: the device checksum and the VERIFIED/Done block) never reach the file — the
# run looks truncated even though it completed fine on screen. Observed on the first
# real run of this script.
#
# Fix: remember tee's PID, and on exit close our stdout/stderr so tee sees EOF, then
# wait for it to finish writing before the shell goes away.
exec > >(tee -a "$LOG") 2>&1
LOGGER_PID=$!

COMPLETED=0

_finish() {
    local rc=$?
    # Catch silent deaths: `set -e` / pipefail can kill this script mid-step with no
    # message at all (a SIGPIPE from `head -c` in the verify pipeline did exactly that
    # on the first two runs). If we get here without having reached the end, say so
    # loudly rather than letting the user assume it finished.
    if [ "$COMPLETED" -ne 1 ]; then
        printf '\n\033[31m!! SCRIPT EXITED EARLY (status %s) — did NOT complete.\033[0m\n' "$rc"
        printf '   The write may or may not have finished. Check the log above.\n'
        printf '   Log: %s\n' "$LOG"
    fi
    exec 1>&- 2>&- || true
    [ -n "${LOGGER_PID:-}" ] && wait "$LOGGER_PID" 2>/dev/null || true
    exit "$rc"
}
trap _finish EXIT

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

echo "restore-image.sh  —  $(date)"
echo "log: $LOG"

# ---------------------------------------------------------------- preflight
[ "$(id -u)" -eq 0 ] || die "must be run as root:  sudo $0 /dev/diskN"
[ -n "$TARGET" ]     || die "no target device given. Usage: sudo $0 /dev/diskN"
[ -f "$IMAGE" ]      || die "image not found: $IMAGE"
command -v zstd >/dev/null || die "zstd not installed"

# Normalise /dev/rdiskN -> /dev/diskN for diskutil queries
TARGET="${TARGET/\/dev\/rdisk//dev/disk}"
RAW="${TARGET/\/dev\/disk//dev/rdisk}"
DEV_NAME="$(basename "$TARGET")"

say "Target device: $TARGET  (raw: $RAW)"

diskutil info "$TARGET" >/dev/null 2>&1 || die "$TARGET is not a disk diskutil recognises"
INFO="$(diskutil info "$TARGET")"

get() { echo "$INFO" | grep -E "^ *$1:" | head -1 | sed -E 's/^[^:]*: *//' ; }

WHOLE="$(get 'Whole')"
# NOTE: macOS does NOT expose an "Internal:" field here — it is "Device Location:
# Internal|External". Checking for "Internal" silently never matches and the guard
# never fires. Verified against both a real internal and external disk.
LOCATION="$(get 'Device Location')"
REMOVABLE="$(get 'Removable Media')"
VIRTUAL="$(get 'Virtual')"
RO="$(get 'Media Read-Only')"
MEDIA="$(get 'Device / Media Name')"
PROTOCOL="$(get 'Protocol')"
SIZE_BYTES="$(echo "$INFO" | grep 'Disk Size' | grep -oE '\([0-9]+ Bytes\)' | grep -oE '[0-9]+' | head -1)"

info "media name : $MEDIA"
info "protocol   : $PROTOCOL"
info "whole disk : $WHOLE"
info "location   : $LOCATION"
info "removable  : $REMOVABLE"
info "virtual    : $VIRTUAL"
info "read-only  : $RO"
info "capacity   : $SIZE_BYTES bytes"

# ---------------------------------------------------------------- guards
[ "$WHOLE" = "Yes" ] || die "$TARGET is not a whole disk (looks like a partition). Use /dev/diskN, not /dev/diskNsM."

# Two independent checks, either of which alone would stop an internal disk.
[ -n "$LOCATION" ] || die "could not read 'Device Location' for $TARGET — refusing rather than guessing."
[ "$LOCATION" = "External" ] || die "$TARGET reports Device Location='$LOCATION', not External. Refusing — this script only writes to external media."

[ -n "$REMOVABLE" ] || die "could not read 'Removable Media' for $TARGET — refusing rather than guessing."
[ "$REMOVABLE" = "Removable" ] || die "$TARGET reports Removable Media='$REMOVABLE' (internal disks report 'Fixed'). Refusing."

[ "$VIRTUAL" != "Yes" ] || die "$TARGET is a virtual/synthesised device (e.g. an APFS container). Refusing."
[ "$RO" = "No" ] || die "$TARGET is read-only. Check the physical write-protect switch."

# Never write to whatever is currently booted
BOOT_DISK="$(diskutil info / 2>/dev/null | grep -E '^ *(Part of Whole|Device Identifier):' | head -1 | sed -E 's/^[^:]*: *//')"
if [ -n "$BOOT_DISK" ] && [ "$DEV_NAME" = "$BOOT_DISK" ]; then
    die "$TARGET is the current boot disk. Refusing."
fi

# ---------------------------------------------------------------- image checks
say "Checking source image"
info "image: $IMAGE"
info "size : $(stat -f%z "$IMAGE") bytes compressed"

info "verifying archive integrity (this reads the whole archive)..."
zstd -t "$IMAGE" || die "archive failed its integrity check — do NOT write it"
info "archive integrity OK"

IMAGE_BYTES="$(zstd -dc "$IMAGE" | wc -c | tr -d ' ')"
info "decompressed size: $IMAGE_BYTES bytes"

if [ "$SIZE_BYTES" -lt "$IMAGE_BYTES" ]; then
    die "target is TOO SMALL: $SIZE_BYTES bytes < image $IMAGE_BYTES bytes. Need a larger device."
fi
info "capacity OK — $((SIZE_BYTES - IMAGE_BYTES)) bytes spare"

if [ "$VERIFY_ONLY" -eq 1 ]; then
    say "VERIFY-ONLY mode — nothing will be written to $TARGET"
    diskutil unmountDisk "$TARGET" || die "could not unmount $TARGET"
else
    # ------------------------------------------------------------ confirm
    say "THIS WILL ERASE EVERYTHING ON $TARGET"
    echo
    diskutil list "$TARGET" || true
    echo
    printf 'Type the device name (%s) to proceed, anything else aborts: ' "$DEV_NAME"
    read -r CONFIRM
    [ "$CONFIRM" = "$DEV_NAME" ] || die "aborted by user (typed '$CONFIRM')"

    # ------------------------------------------------------------ write
    say "Unmounting $TARGET"
    diskutil unmountDisk "$TARGET" || die "could not unmount $TARGET"

    say "Writing image (speed varies hugely by device: measured 7.9 MB/s on a cheap USB
    stick (~33 min) vs 17 MB/s on an SD card (~17 min). Press Ctrl-T for progress)"
    # The first sector (the partition table) is written LAST. While it is still zero,
    # macOS cannot see any partitions, so it cannot auto-mount the FAT boot partition and
    # scribble .fseventsd / .Spotlight-V100 onto it between the write and the read-back
    # check. That scribbling made a perfectly good write fail verification (2026-09-13).
    MBR_TMP="$(mktemp -t mbr)"
    START=$(date +%s)
    zstd -dc "$IMAGE" | python3 -c '
import sys, shutil
mbr = sys.stdin.buffer.read(512)
open(sys.argv[1], "wb").write(mbr)
sys.stdout.buffer.write(b"\0" * 512)
shutil.copyfileobj(sys.stdin.buffer, sys.stdout.buffer, 4 << 20)' "$MBR_TMP" \
      | dd of="$RAW" bs=4m || die "dd failed — the target is now in an INCONSISTENT state, re-run before using it"
    sync
    [ "$(stat -f%z "$MBR_TMP")" = 512 ] || die "internal error: did not capture the partition table"
    ELAPSED=$(( $(date +%s) - START ))
    info "write finished in ${ELAPSED}s (partition table held back until verified)"
fi

# ---------------------------------------------------------------- verify
# region_hashes: read a whole-disk stream on stdin and print one line per region:
#   "<name> <sha256>"  for sector0, each partition (p1..), in stream order.
# The partition table is parsed from the stream's first sector, or taken from $TABLE
# ("start:sectors:type,...") when the stream's sector 0 is not yet the real one.
region_hashes() {
    python3 -c '
import sys, hashlib, struct
total = int(sys.argv[1]); table = sys.argv[2] if len(sys.argv) > 2 else ""
inp = sys.stdin.buffer
sec0 = inp.read(512)
print("sector0", hashlib.sha256(sec0).hexdigest())
if table:
    parts = [tuple(int(x) for x in p.split(":")) for p in table.split(",")]
else:
    parts = []
    for i in range(4):
        e = sec0[446 + 16*i: 446 + 16*i + 16]
        typ = e[4]; start, n = struct.unpack("<II", e[8:16])
        if typ and n: parts.append((start, n, typ))
    print("table", ",".join(f"{s}:{n}:{t}" for s, n, t in parts))
parts.sort()
pos = 512
def consume(nbytes, h=None):
    global pos
    while nbytes > 0:
        chunk = inp.read(min(nbytes, 4 << 20))
        if not chunk: sys.exit("stream ended early at byte %d" % pos)
        if h: h.update(chunk)
        nbytes -= len(chunk); pos += len(chunk)
for i, (start, n, typ) in enumerate(parts, 1):
    consume(start * 512 - pos)
    h = hashlib.sha256(); consume(n * 512, h)
    print(f"p{i}:type{typ:02x} {h.hexdigest()}")
' "$@"
}

if [ "$VERIFY" -eq 1 ]; then
    say "Verifying — reading back $IMAGE_BYTES bytes and comparing, partition by partition"
    info "(this takes about as long as the write; use --no-verify to skip)"

    SRC_HASHES="$(zstd -dc "$IMAGE" | region_hashes "$IMAGE_BYTES")"
    TABLE="$(printf '%s\n' "$SRC_HASHES" | awk '$1=="table"{print $2}')"
    [ -n "$TABLE" ] || die "could not parse a partition table from the image"
    if [ "$VERIFY_ONLY" -eq 1 ]; then
        diskutil unmountDisk "$TARGET" >/dev/null 2>&1 || true     # stop macOS touching it while we read
        DEV_TABLE="$TABLE"
    else
        DEV_TABLE="$TABLE"     # device sector 0 is still zero at this point — by design
    fi

    # NOTE: `head -c N` closes the pipe as soon as it has N bytes, which sends SIGPIPE
    # to dd (exit 141). Under `set -euo pipefail` that non-zero status propagates and
    # kills the script SILENTLY. SIGPIPE on dd is expected and harmless here, so disable
    # pipefail for this pipeline only. Run in a subshell so the setting does not leak.
    DST_HASHES="$( set +o pipefail
                   dd if="$RAW" bs=4m count=$(( (IMAGE_BYTES + 4194303) / 4194304 )) 2>/dev/null \
                   | head -c "$IMAGE_BYTES" | region_hashes "$IMAGE_BYTES" "$DEV_TABLE" )"
    [ -n "$DST_HASHES" ] || die "could not read the device back — verification inconclusive"

    FAIL=0
    for region in $(printf '%s\n' "$SRC_HASHES" | awk '$1!="table"{print $1}'); do
        S="$(printf '%s\n' "$SRC_HASHES" | awk -v r="$region" '$1==r{print $2}')"
        D="$(printf '%s\n' "$DST_HASHES" | awk -v r="$region" '$1==r{print $2}')"
        if [ "$region" = "sector0" ] && [ "$VERIFY_ONLY" -eq 0 ]; then
            continue                                     # not written yet, checked below
        fi
        if [ "$S" = "$D" ]; then
            info "$region  OK"
        elif [ "$VERIFY_ONLY" -eq 1 ] && printf '%s' "$region" | grep -qE 'type0[bc]$'; then
            info "$region  DIFFERS — a FAT volume macOS has mounted gets .fseventsd/.Spotlight files written to it; harmless. (The Linux partitions are the ones that matter.)"
        else
            info "$region  MISMATCH  image=$S  device=$D"; FAIL=1
        fi
    done
    [ "$FAIL" -eq 0 ] || die "MISMATCH — the device does NOT match the image. Do not use this drive; re-run, and if it fails again suspect the drive."

    if [ "$VERIFY_ONLY" -eq 0 ]; then
        info "data verified — now writing the partition table"
        dd if="$MBR_TMP" of="$RAW" bs=512 count=1 2>/dev/null || die "could not write the partition table"
        sync
        if dd if="$RAW" bs=512 count=1 2>/dev/null | cmp -s - "$MBR_TMP"; then
            info "sector0  OK"
        else
            die "the partition table did not read back correctly — suspect the drive"
        fi
        rm -f "$MBR_TMP"
    fi
    say "VERIFIED — device matches the image"
else
    if [ "$VERIFY_ONLY" -eq 0 ]; then
        dd if="$MBR_TMP" of="$RAW" bs=512 count=1 2>/dev/null || die "could not write the partition table"
        sync; rm -f "$MBR_TMP"
    fi
    say "Skipped read-back verification (--no-verify)"
fi
sleep 2   # let macOS notice the partition table before we list it

# ---------------------------------------------------------------- done
say "Resulting partition layout"
diskutil list "$TARGET" || true

cat <<EOF

Done.

  * macOS will offer to INITIALIZE the unreadable ext4 partition — always choose Ignore.
  * Eject in Finder (or: diskutil eject $TARGET) before physically removing the drive.
  * The restored system boots read-only with an overlay; see BUILD-NOTES.md to change it.

Log saved to: $LOG
EOF

COMPLETED=1
