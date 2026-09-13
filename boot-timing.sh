#!/usr/bin/env bash
#
# boot-timing.sh — measure Pi boot time from power-on, and split it into
# firmware/bootloader time vs kernel+userspace time.
#
#   ./boot-timing.sh <pi-ip> sd    # label the run (sd / usb)
#
# WHY NOT JUST USE systemd-analyze?
# It starts counting at kernel handoff, so it cannot see the Pi 5 firmware, EEPROM
# init, BOOT_ORDER probing, or USB enumeration — which is exactly where a USB-vs-SD
# difference lives. Measured here: 24 s wall clock vs 10.3 s from systemd-analyze.
# The ~14 s gap IS the firmware stage.
#
# Method: you power the Pi on when prompted; this polls TCP/22 until it answers,
# then reads systemd-analyze over SSH and subtracts.
#
# Results append to boot-timing.csv so you can compare runs.

set -uo pipefail

HOST="${1:?usage: $0 <pi-ip> [label]}"
LABEL="${2:-unlabelled}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV="$SCRIPT_DIR/boot-timing.csv"
TIMEOUT=180

echo "Boot timing — host $HOST, label '$LABEL'"
echo

# Make sure it is actually off before we start, or we'll time nothing.
if nc -z -G 2 "$HOST" 22 2>/dev/null; then
    echo "WARNING: $HOST is already reachable — the Pi appears to be running."
    echo "Power it down first, then re-run. (Pulling power is safe: read-only rootfs.)"
    exit 1
fi

echo "Pi is not reachable — good."
echo
read -r -p "Power on the Pi, then press ENTER at the *instant* you apply power: "
START=$(date +%s)
echo "timing started; polling TCP/22..."

ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    if nc -z -G 2 "$HOST" 22 2>/dev/null; then
        ELAPSED=$(( $(date +%s) - START ))
        echo "SSH answered after ${ELAPSED}s"
        break
    fi
    sleep 1
    ELAPSED=$(( $(date +%s) - START ))
done

if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "TIMED OUT after ${TIMEOUT}s — Pi never became reachable."
    exit 1
fi

# sshd answering is slightly before the audio bridge is necessarily up, but it is
# consistent between runs, which is what matters for an A/B.
echo
echo "Collecting boot breakdown over SSH..."
sleep 3

ANALYZE="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
           "jonathan@$HOST" 'systemd-analyze' 2>/dev/null | head -1)"
BLAME="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
         "jonathan@$HOST" 'systemd-analyze blame 2>/dev/null | head -5' 2>/dev/null)"
LINKS="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
         "jonathan@$HOST" 'pw-link -l 2>/dev/null | grep -c audio_bridge' 2>/dev/null)"
BOOTDEV="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
           "jonathan@$HOST" 'findmnt -n -o SOURCE /media/root-ro 2>/dev/null || findmnt -n -o SOURCE /' 2>/dev/null)"

KERNEL=$(echo "$ANALYZE"   | grep -oE '[0-9.]+s \(kernel\)'    | grep -oE '[0-9.]+')
USERSP=$(echo "$ANALYZE"   | grep -oE '[0-9.]+s \(userspace\)' | grep -oE '[0-9.]+')
KERNEL=${KERNEL:-0}; USERSP=${USERSP:-0}
OSTIME=$(echo "$KERNEL + $USERSP" | bc -l 2>/dev/null || echo 0)
FIRMWARE=$(echo "$ELAPSED - $OSTIME" | bc -l 2>/dev/null || echo 0)

printf '\n================ RESULT (%s) ================\n' "$LABEL"
printf '  boot device        : %s\n' "${BOOTDEV:-unknown}"
printf '  wall clock (power->ssh) : %6ss\n' "$ELAPSED"
printf '  kernel                  : %6ss\n' "$KERNEL"
printf '  userspace               : %6ss\n' "$USERSP"
printf '  --------------------------------\n'
printf '  OS total (systemd-analyze): %6.2fs\n' "$OSTIME"
printf '  FIRMWARE/BOOTLOADER       : %6.2fs   <-- where USB vs SD differs\n' "$FIRMWARE"
printf '  audio_bridge links        : %s (expect 8)\n' "${LINKS:-?}"
echo
echo "slowest units:"
echo "$BLAME"

[ -f "$CSV" ] || echo "timestamp,label,boot_device,wall_s,kernel_s,userspace_s,os_total_s,firmware_s,links" > "$CSV"
printf '%s,%s,%s,%s,%s,%s,%.2f,%.2f,%s\n' \
    "$(date +%Y-%m-%dT%H:%M:%S)" "$LABEL" "${BOOTDEV:-unknown}" \
    "$ELAPSED" "$KERNEL" "$USERSP" "$OSTIME" "$FIRMWARE" "${LINKS:-?}" >> "$CSV"

echo
echo "appended to $CSV"
