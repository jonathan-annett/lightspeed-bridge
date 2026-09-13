# Lightspeed USB Audio Bridge — Build Notes

Portable Raspberry Pi 5 appliance: USB audio capture → Logitech Lightspeed wireless
headphone base station. Boots headless in ~10 s, no login, no console, no network.
Read-only filesystem, so power can be pulled without shutting down.

**Status: COMPLETE.** Audio confirmed by ear. Survives reboot, unplug/replug, and
power loss. Realtime scheduling active.

Host: `lightspeedpi@<pi-ip>` (hostname `lightspeed-bridge`; since 2026-09-13 the box
runs the public release image — user `lightspeedpi`, password `lightspeedpi`)
**⚠ The filesystem is READ-ONLY — see "Making changes" before editing anything.**

---

## Platform

| Item | Value |
|---|---|
| Board | Raspberry Pi 5 Model B Rev 1.1, 8 GB |
| OS | **Raspberry Pi OS Lite**, Debian 13 trixie |
| Kernel | 6.18.34+rpt-rpi-2712 |
| Boot device | USB drive `/dev/sda`, `sda1`=/boot/firmware (vfat), `sda2`=/ (ext4) |
| PipeWire / WirePlumber | 1.4.2 / 0.5.8 |
| PulseAudio | not installed (correct) |
| Boot time | **~24 s wall clock** power-on to audio (measured standalone) |

**Boot time baseline: ~27 s from power button to working audio** (original USB stick,
measured twice; an earlier single reading of 24 s was a slow stopwatch start — one
sample is not enough).

Note `systemd-analyze` reports only ~10.3 s. It measures from *kernel start* and
excludes Pi 5 firmware/EEPROM init, `BOOT_ORDER` probing and USB enumeration — which is
exactly where a boot-device difference lives. So the split is roughly **~13 s firmware
+ ~10 s OS + audio start**. The overlayroot install also added a 12 MB initramfs for the
bootloader to load.

### Boot device A/B (power-on → first audio, stopwatch)

| Device | Boot | Form factor | Write speed | Notes |
|---|---|---|---|---|
| **32 GB SD card** ← **CHOSEN** | **20 s** | flush, transit-safe | 17 MB/s (~17 min) | **−7 s / −26% vs baseline** |
| Original USB stick (16 GB) | 27 s | protrudes — can stress board in transit | 23.5 MB/s read | baseline, 2 runs |
| Pi 3 B+ from a 64 GB USB stick (2026-09-13) | 57 s | | 48 MB/s read | the 3 B+ bootloader probes USB slowly; SD on that board was 25 s |
| "VendorCo" USB (16 GB) | 31 s | flush, transit-safe | 7.86 MB/s (~33 min) | slow flash |

**The SD card wins on both criteria — fastest AND flush-fitting.** No trade-off.

Interpreting the numbers: the 27 s baseline splits roughly **13 s firmware + 10 s OS**.
The OS half is identical across all three (same image), so essentially the **entire 7 s
saving came out of the firmware stage** — ~13 s down to ~6 s. That is USB enumeration
being skipped entirely, plus faster flash reads.

The +4 s on the "VendorCo" stick tracks its slow flash — cheap drives are slow to read
as well as write, and **read** speed is what boot time depends on. Worth measuring
rather than assuming any replacement drive is equivalent: the two USB sticks are
nominally identical 16 GB devices and differ by 4 s.

Measuring this needs a **wall-clock** method (stopwatch power-on → audio, or
`boot-timing.sh` which polls SSH). `systemd-analyze` alone cannot see the difference.
The A50 base station establishes its wireless link **concurrently and independently** of
the Pi, so it does not inflate these numbers.

**If boot ever climbs to 60 s+, something is waiting on a device or network that isn't
present** — that is what `NetworkManager-wait-online` used to cause (30–90 s with no
cable). Untuned candidates: EEPROM `BOOT_ORDER`, `USB_MSD_STARTUP_DELAY`, `boot_delay`.
All need /boot writable, so overlay off first.

### Networking — dual-homed; use Ethernet for maintenance
`eth0` **<pi-ip>** (4.96 ms avg) vs `wlan0` <pi-wlan-ip> (54.8 ms avg,
80 ms jitter — Wi-Fi power saving). Irrelevant to audio, painful for remote work.

---

## Power — single supply is sufficient

The A50 base station is **powered from a spare USB port on the Pi**, so the rig needs
only ONE external PSU.

| Measured | |
|---|---|
| Base station alone (headset not charging) | **0.27 A** |
| Whole system, headset not charging | **≤ 0.7 A** (~3.5 W at 5 V) |
| **Whole system, headset CHARGING on the base** | **1.52 A max** (under 8 W) — measured 2026-09-12 |
| Capture adapter (typical USB audio dongle) | ~0.05–0.1 A |
| USB total, not charging | ~0.32–0.37 A |
| USB total, charging | **~1.2 A** (base station ≈ 1.1 A) |

The Pi 5 negotiates its USB budget from the supply — **1.6 A** across USB ports with a
5 A-capable PSU, but it clamps to **600 mA total** if it does not detect one. Without
charging we sit ~40% under even the clamped limit. **With the headset charging on the
base, the ~1.2 A USB draw exceeds the 600 mA clamp** — so a detected 5 A PSU (or
`usb_max_current_enable=1`) is a requirement, not just headroom, whenever the headset
is docked. It fits the 1.6 A budget with ~25% to spare. **The rig uses the official
Raspberry Pi 5 27 W (5 A) supply, and the Pi negotiates it** (confirmed 2026-09-12:
`max_current = 5000`, `usb_max_current_enable = 1`, no over-current, `throttled=0x0`). To
re-check (no `xxd` on the box):
`od -An -tu4 --endian=big /proc/device-tree/chosen/power/max_current` → want `5000`.

Worth knowing because the failure mode is not a clean error — it is brownouts under
transient load, showing up as audio dropouts or spontaneous reboots. Confirm with:

```bash
vcgencmd get_throttled     # 0x0 = no under-voltage has EVER occurred this boot
```
Non-zero has bits for "under-voltage now" and "under-voltage has occurred" — the latter
catches brief dips you would otherwise never see. If it ever trips: use a 5 A PSU, or
set `usb_max_current_enable=1` in config.txt (needs /boot writable → overlay off first).

## Audio devices

- **Output** — Logitech Lightspeed base station, enumerates as `A50` (`046d:0b1c`).
  Node: `alsa_output.usb-Logitech_A50-00.analog-stereo`, 2ch FL/FR @ 48000.
- **Input, primary** — Realtek USB-C stereo adapter (`0bda:49dd`).
  Node: `alsa_input.usb-Generic_USB_HP_MIC_Adapter-00.analog-stereo`, 2ch @ 48000.
  Genuinely stereo (verified by descriptor, by independent per-channel noise, and by
  the user). Measured clean: no clipping, no glitches.
- **Input, fallback** — C-Media XLR-to-USB-A, **mono** (`08bb:2902`, PCM2902 codec).
  Node: `alsa_input.usb-C-Media_Electronics_Inc._USB_PnP_Sound_Device-00.analog-mono`

Both natively 48 kHz → graph pinned to 48000, no resampling.
⚠ **Card numbers are NOT stable** across boots/replugs. Always target by `node.name`.

---

## Measured performance

| Metric | Value |
|---|---|
| `clock.quantum` | **64** @ 48000 (1.33 ms period) |
| Peak node BUSY | ~7 µs vs 1333 µs budget (**~0.5%**) |
| Ongoing xruns | **zero** |
| data-loop scheduling | **SCHED_FIFO priority 88** |
| Disk writes per boot | **~32 KiB** (was ~2 MiB before overlay) |

### Latency — a false alarm worth recording
A perceived delay turned out to be the **media player's slow pause/unpause**.
Disconnecting the connector caused *immediate* silence, proving the pipeline holds
almost no audio. Software-side budget is under 10 ms.

`buffer_size: 32768` in `/proc/asound/*/hw_params` looks alarming (683 ms) but is a
**red herring** — PipeWire allocates a large ALSA ring and uses timer-based scheduling
to write just ahead of the hardware pointer. Latency is quantum + headroom.
An aggressive ALSA tuning file added while chasing this was **deliberately reverted**:
it bought ~1 ms nobody can hear while adding crackle risk under venue load.

---

## ⚠ Four hard-won fixes — do not undo these

### 1. Realtime priority needs TWO files working together
Out of the box the data-loop runs SCHED_OTHER with no realtime priority — silently.

Dead ends, all verified:
- `/etc/security/limits.d/audio.conf` alone: `pam_limits` applies only to *login*
  sessions, and Lite has **no `/etc/pam.d/systemd-user`**, so the lingering user
  manager never sees it. `ulimit -r` reads 95 in SSH while the service has `LimitRTPRIO=0`.
- **RTKit**: clamps the requested 88 → 20, and the grant doesn't stick (rtkit-daemon
  reports "Supervising 0 threads"). Masked, module-rt logs "RTKit does not give us
  MaxRealtimePriority, using 1" and **never falls back to rlimits**.
- `module.rt.args`: silently ignored, both in `context.properties` and top level.
- Private module-rt from `conf.d`: loads too **late**, after data-loop threads exist.

What works: systemd starts PipeWire under FIFO (`pipewire-service-rt.conf`) **and**
module-rt is disabled (`rt-priority.conf`) so it can't demote the thread back.
Without the second file you get the main thread at FF 88 and data-loop at TS —
realtime on the wrong thread.

### 2. The feedback loop needs monitor ports gone
With no capture device present, the loopback's capture stream attaches to the A50
sink's **monitor**: `A50 out -> monitor -> capture -> playback -> A50 out`.
Observed live during a cable swap.

Nothing else stops it:
- `stream.capture.sink = false` — lands on the node; WirePlumber's fallback linking
  overrides it anyway (verified).
- `target.object` — an absent target just makes the module grab whatever else exists.
- `node.dont-reconnect = true` — blocks the fallback, **but also stops the stream ever
  connecting to its correct target**. Zero links even with the device present. Unusable.
- `wpctl settings ... false` at runtime — lost when the node is recreated on device
  removal; the monitor ports and the feedback come straight back. Must be in config.

Fix: `52-no-monitor-ports.conf` disables monitor ports entirely. Nothing to fall back
to, so the stream stays unlinked and you get silence, which is correct.
**Cost:** can no longer record what the A50 is playing. Fine for an appliance.

### 3. Boot must not wait for a network that isn't there
`NetworkManager-wait-online.service` was **enabled** and cost 4.3 s even *with* a
network — with the cable out it blocks until timeout (30–90 s). Disabled, along with
cloud-init. NetworkManager and ssh remain enabled, so plugging back in still works.

---

### 4. Output volume must be pinned at unity (`53-sink-unity-volume.conf`)

The A50 has **no hardware volume control**, so its sink volume is software inside
PipeWire. With no saved route, WirePlumber applies `device.routes.default-sink-volume`
(stock **0.064 ≈ −24 dB**). Route → node propagation races with device creation: when the
A50 enumerates after WirePlumber is up (it boots its own firmware off Pi USB power, so
timing varies), the route says 0.064 but the node is sometimes left at **1.0** — a ~24 dB
jump between boots with nothing touched. Reproduced by hot-plugging the A50 (1.0 once,
0.064 once). Fix: set the default to **1.0** so both sides of the race agree. Unity is the
chosen operating level (headroom; the headset wheel attenuates).
Verify: `pw-cli enum-params <A50 sink id> Props | grep -A3 softVolumes` → `1.000000`.

---

## Verified behaviour

| Scenario | Result |
|---|---|
| Cold boot, no login/console/network | ✅ 8 links up in ~10 s |
| Stereo adapter connected | ✅ audio flows, 0 monitor links |
| **No capture device at all** | ✅ stays unlinked — **silence, not feedback** |
| Other cable substituted | ✅ falls back to it, no config change |
| Unplug / replug (either device) | ✅ recovers (output faster than input, by design) |
| Mono cable | ✅ upmixed to both ears, L==R 100.0%, no level loss |
| Power pulled without shutdown | ✅ read-only root + /boot, ~32 KiB written per boot |
| A50 hot-plugged / enumerates late | ✅ sink at unity every time (3 boots × 2 hot-plugs) |
| Clicker gain control | ✅ ±3/±1 dB steps, clamps, reset; keys never reach the console (grabbed) |
| Pi 5 power button | ✅ left to logind — the daemon only grabs devices that offer a mapped key |
| Pi 3 B+ with the same image (2026-09-13) | ✅ quantum 64 held, 0 xruns / 60 s with Ethernet on the shared USB 2.0 controller; busiest node ~4% of period; 44.5 °C; no under-voltage. Fresh first boot on the 3 B+ also ✅ (own host key, overlay enabled, v8 kernel) |
| Overnight soak (2026-09-12→13, looped track, USB-stick boot) | ✅ still playing in the morning after the headset had powered itself off and back on; `throttled=0x0`, 51.6 °C, **0 xruns over 90 s idle**. (The session's cumulative 79 xruns all accrued while four release-image builds ran on the same box — not representative of venue use.) |

**Output recovers faster than input** because the A50 is bound by exact `target.object`
(one step), while input recovery goes device probe → node creation → policy →
default-source election → stream follows.

⚠ `pw-link -l` is **not** a reliable liveness check during a disconnect — it reported
8 links while the card was gone. Use `wpctl status` or `/proc/asound/cards`.

---

## Deployed files

| Source file | Destination |
|---|---|
| `loopback.conf` | `~/.config/pipewire/pipewire.conf.d/loopback.conf` |
| `latency.conf` | `~/.config/pipewire/pipewire.conf.d/latency.conf` |
| `rt-priority.conf` | `~/.config/pipewire/pipewire.conf.d/rt-priority.conf` |
| `pipewire-service-rt.conf` | `~/.config/systemd/user/pipewire.service.d/rt.conf` |
| `50-disable-a50-mic.conf` | `~/.config/wireplumber/wireplumber.conf.d/` |
| `52-no-monitor-ports.conf` | `~/.config/wireplumber/wireplumber.conf.d/` |
| `53-sink-unity-volume.conf` | `~/.config/wireplumber/wireplumber.conf.d/` |
| `gain-control.py` | `~/.local/bin/` (clicker/keyboard input-gain daemon) |
| `gain-control.service` | `~/.config/systemd/user/` (enabled) |
| `gain-inject-test.py` | `~/.local/bin/` (test tool) |
| `gain-status-screen.service` | `/etc/systemd/system/` (enabled; journal → tty2) |
| `var-lib-gain-control.mount` | `/etc/systemd/system/var-lib-gain\x2dcontrol.mount` (enabled; `gaindata` partition) |
| `audio.conf` | `/etc/security/limits.d/audio.conf` |
| `50-audio-limits.conf` | `/etc/systemd/system/user@.service.d/` |

`loopback-auto.conf` is a superseded design (untargeted capture). Kept for reference —
**do not deploy**, it is the version that produced the feedback loop.

### System changes outside home
- `loginctl enable-linger jonathan` — PipeWire runs headless at boot
- `/etc/security/limits.d/audio.conf` — rtprio 95 / memlock unlimited for `@audio`
- `/etc/systemd/system/user@.service.d/50-audio-limits.conf` — LimitRTPRIO 95,
  LimitMEMLOCK infinity, **LimitRTTIME 200000** (finite, deliberately: a runaway
  realtime thread gets SIGXCPU rather than wedging the Pi)
- `systemctl mask --now rtkit-daemon.service`
- `systemctl disable NetworkManager-wait-online cloud-init*`
- `/etc/sudoers.d/010_jonathan-nopasswd`
- `/etc/fstab` — `,ro` on /boot/firmware
- `/boot/firmware/cmdline.txt` — `overlayroot=tmpfs` prepended
- ALSA state stored to `/var/lib/alsa/asound.state` (C-Media AGC off)
- `gain-status-screen.service` — switches the console to tty2 at boot and follows the
  gain-control / pipewire / wireplumber journal there (tty1 login untouched, Alt+F1)
- **`/dev/mmcblk0p3`** — 64 MiB ext4 `gaindata`, mounted at `/var/lib/gain-control` by a
  systemd **mount unit** (not fstab — overlayroot would overlay it). The only thing on the
  box that persists across power cycles besides the image itself: the clicker's last offset.

---

## Disk image / restore

`lightspeed-bridge-8gb.img.zst` — **current** (2026-09-12). Raw image of the first
13,778,944 sectors (7,054,819,328 bytes) of the compacted SD card: boot 512 MiB +
rootfs 6 GiB + gaindata 64 MiB. Fits any nominal 8 GB card. Captured from the Pi booted
off the USB stick with the SD card unmounted, so every filesystem was clean.

The compaction (`shrink-sd.sh`): `e2fsck -f` → `resize2fs` to 6 GiB → `sfdisk` with the
same disklabel id (PARTUUIDs `c0098f72-0N` preserved, so `cmdline.txt` and fstab are
untouched) → gaindata recreated behind rootfs. Shrinking ext4 is offline-only, so this
must run from another boot device; the EEPROM BOOT_ORDER is SD first, so the card was
hot-inserted after booting the USB stick (works — card detect + MMC rescan).

`lightspeed-bridge-16gb.img.zst` — superseded. Predates the 2026-09-12 work and needs a
16 GB+ device.

| | |
|---|---|
| Source device | 15,682,240,512 bytes (16 GB stick, 14.6 GiB) |
| Compressed | **2.00 GiB** (13.7% — free space was mostly zeros) |
| SHA-256 | see `image.sha256` |
| **Actual data used** | **4.19 GiB** (9.91 GiB free of 14.10 GiB root) |

Verified after capture: zstd checksum OK, decompresses to the exact byte count, MBR
signature `0x55AA` present, FAT32 `bootfs` and ext4 `rootfs` superblocks both intact,
filesystem state CLEAN.

**Minimum replacement media: 8 GB** (4.19 GiB used + 0.5 GiB boot + slack). 16 GB is
comfortable. Below 8 GB will not fit.

### Capture (from the Pi, over the network — preferred)
Boot the Pi from the USB stick, hot-insert the SD card (leave it unmounted), then on the Mac:
```bash
ssh jonathan@<pi-ip> 'sudo dd if=/dev/mmcblk0 bs=524288 count=13456 | tee >(sha256sum > /tmp/raw.sha256)' \
  | zstd -T0 -12 -o lightspeed-bridge-8gb.img.zst
ssh jonathan@<pi-ip> cat /tmp/raw.sha256      # compare with: zstd -dc image | shasum -a 256
```
`count=13456` × 512 KiB = exactly the three partitions; the rest of the card is unused.

### Capture (macOS card reader — older method)
`/dev/rdiskN` is `root:operator` mode 640, so this needs sudo:
```bash
diskutil unmountDisk /dev/diskN          # unmount, do NOT eject
sudo dd if=/dev/rdiskN bs=512k count=13456 | zstd -T0 -12 -o lightspeed-bridge-8gb.img.zst
```
Ctrl-T during the run prints progress (macOS dd has no `status=progress`).

### Restore to a new stick/card (macOS)
⚠ `of=` is destructive — confirm the device number with `diskutil list` FIRST, and
note it changes between plug-ins.
```bash
diskutil unmountDisk /dev/diskN
zstd -dc lightspeed-bridge-16gb.img.zst | sudo dd of=/dev/rdiskN bs=4m
sync
```
If restoring to media LARGER than 16 GB the extra space is simply unused; the root
partition can be grown later with `raspi-config`/`parted` + `resize2fs`, but the
overlay must be disabled first.

⚠ macOS will offer to **Initialize** the unreadable ext4 partition whenever this media
is inserted. Always choose **Ignore**.

### Public release image
`build-release-image.sh` builds a sanitised image on the Pi from the running appliance
(see the script header for exactly what is stripped and renamed). Two things it had to
learn the hard way: `/etc/{passwd,shadow,group,gshadow}-` backups keep the OLD password
hash, and `/var/lib/cloud/` keeps cloud-init's cached copy of the imager config (name,
email, SSH public key) even with cloud-init disabled. The build fails on a scrub grep for
those identifiers. The release boots once with the overlay off, regenerates host keys
(empty machine-id ⇒ systemd first boot), enables the overlay itself
(`lightspeed-firstboot.service`) and reboots. Boot-tested end to end on 2026-09-13
(release #2, sha256 `f69f4092…`): first boot self-configures and reboots, second boot is
the appliance with password SSH login working.

## Making changes (filesystem is READ-ONLY)

Anything you edit now is discarded at reboot. To make a persistent change:

```bash
sudo raspi-config nonint disable_overlayfs
sudo reboot
# ... make changes, test them ...
sudo raspi-config nonint enable_overlayfs
sudo reboot
```

To also make /boot writable: `sudo raspi-config nonint disable_bootro` (overlay must
be off first — raspi-config refuses otherwise).

**Registering another capture cable:** with overlay off, plug it in, run
`pw-cli ls Node | grep alsa_input`, and put the `node.name` into `target.object` in
`loopback.conf`. Note the single-module fallback already picks up *any* capture device
when the named target is absent, so this is only needed to change which cable is
*preferred*.

**⚠ Do not add a second loopback module per cable.** Two modules both grab the same
source when only one cable is present, and their playback streams sum into the A50
(~+6 dB).

---

## The mono cable's noise

Its factory defaults are the problem, not (necessarily) the hardware: mic gain at
**+23.81 dB** with **Auto Gain Control ON**. Corrected and persisted:
- AGC off → `/var/lib/alsa/asound.state`
- gain **+4.46 dB** → `~/.local/state/wireplumber/default-routes` (`channelVolumes:[0.125]`;
  WirePlumber uses a cubic curve, so 0.5 → 0.125)

Adjust with `wpctl set-volume <source-id> 0.5`.

Measurements never reproduced the reported noise: capture peaked at −6.0 dBFS with
**zero** clipped samples and a healthy 20.2 dB crest factor; the A50 output showed zero
discontinuities, zero dropouts, and L==R at 100.0%. **The digital path is clean.**
A spectral pass found no 50/60 Hz hum and no 1 kHz USB-frame signature, but was
inconclusive because signal was present in every window — a true noise-floor
measurement needs the XLR source disconnected. Also worth checking: a PCM2902 mic
input expects **mic level**; driving it from a line-level source needs attenuation at
the source.

## Notes
- **ESD:** unexplained reboots correlated with walking across carpet and touching the
  case (2026-09-12). Fixed, as far as can be told, by tying the cables down and fitting a
  USB lead with an RF choke to the input sound card. Not reproducible afterwards.
- Offline in normal use → `systemd-timesyncd` can't reach NTP, clock drifts. Harmless.
- journald is **volatile**; `/var/log/journal` stays empty. Read logs with
  `sudo journalctl -D /run/log/journal`. `journalctl --user` reporting "No journal
  files were found" is expected, not a fault.
- `rpi-eeprom` upgrade (28.27→28.31) was **held** — bootloader reflash, the only item
  with real brick risk.
