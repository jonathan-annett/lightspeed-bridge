#!/usr/bin/env bash
# test-card.sh — is this SD card / USB stick real and healthy?   sudo ./test-card.sh /dev/diskN
#
# DESTROYS the card's contents. Writes 8 MiB of random data at several offsets across the
# card's claimed capacity, reads everything back and compares. Catches:
#   * fake-capacity cards (claim 32 GB, really 4–8 GB): far writes vanish or wrap around
#     and overwrite the start of the card
#   * dying cards: data does not read back the same
# Only external, removable, whole disks are accepted.
set -euo pipefail
T="${1:-}"; [ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -n "$T" ] || { echo "usage: sudo $0 /dev/diskN"; exit 2; }
T="${T/\/dev\/rdisk//dev/disk}"; RAW="${T/\/dev\/disk//dev/rdisk}"
INFO="$(diskutil info "$T")" || exit 1
f() { printf '%s\n' "$INFO" | grep -E "^ *$1:" | head -1 | sed -E 's/^[^:]*: *//'; }
[ "$(f 'Whole')" = "Yes" ] || { echo "not a whole disk"; exit 1; }
[ "$(f 'Device Location')" = "External" ] || { echo "not external — refusing"; exit 1; }
[ "$(f 'Removable Media')" = "Removable" ] || { echo "not removable — refusing"; exit 1; }
BYTES="$(f 'Disk Size' | grep -oE '\(([0-9]+) Bytes' | tr -dc 0-9)"
GIB=$(( BYTES / 1073741824 ))
echo "$T: claims $BYTES bytes (${GIB} GiB) — $(f 'Device / Media Name')"
read -r -p "This ERASES $T. Type the device name to proceed: " ok; [ "$ok" = "$(basename "$T")" ] || exit 1
diskutil unmountDisk "$T" >/dev/null
# offsets in MiB: start, 1 GiB, then every ~1/4 of the card, and near the very end
OFFS="0 1024"; for q in 1 2 3; do OFFS="$OFFS $(( GIB * 1024 * q / 4 ))"; done; OFFS="$OFFS $(( GIB * 1024 - 16 ))"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "== writing 8 MiB of random data at MiB offsets: $OFFS"
for o in $OFFS; do dd if=/dev/urandom of="$TMP/w$o" bs=1m count=8 2>/dev/null; dd if="$TMP/w$o" of="$RAW" bs=1m seek="$o" 2>/dev/null; done; sync
echo "== reading back"; FAIL=0
for o in $OFFS; do
    dd if="$RAW" of="$TMP/r$o" bs=1m skip="$o" count=8 2>/dev/null
    if cmp -s "$TMP/w$o" "$TMP/r$o"; then echo "  ${o} MiB  OK"; else echo "  ${o} MiB  WRONG DATA"; FAIL=1; fi
done
if [ "$FAIL" -eq 1 ]; then
    if cmp -s "$TMP/w0" "$TMP/r0"; then echo "RESULT: the card is BAD — data written to it does not read back."; else echo "RESULT: the card is BAD, and likely FAKE-CAPACITY — writes far into the card corrupted its start."; fi
    exit 1
fi
echo "RESULT: all regions read back correctly — the card's claimed capacity is real and it holds data."
