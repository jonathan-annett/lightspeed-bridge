# Handoff — Lightspeed USB Audio Bridge

**Read `BUILD-NOTES.md` first.** It is the authoritative record of what this appliance
is, how it was built, what was measured, and — importantly — four dead ends that look
like reasonable fixes but are not. This file covers only what is *outstanding*.

---

## 0. Orientation (for a session starting cold)

**What it is:** a Raspberry Pi 5 appliance that bridges a USB audio capture device to a
Logitech Lightspeed wireless headphone base station. Boots headless with no login, no
console, no network. Used at live venues, so it must be power-fail safe and predictable.

**Status: working and complete**, currently running from the original 16 GB USB stick
(restored 2026-09-13 from `lightspeed-bridge-8gb.img.zst` after the 32 GB SD card died —
see item 7). Items 2, 3 and 3b are done. A brand-name SD card ≥ 8 GB is wanted.

### Connecting

```bash
ssh lightspeedpi@<pi-ip>      # eth0 — USE THIS. Password: lightspeedpi (default)
```

- **Since 2026-09-13 the appliance RUNS THE PUBLIC RELEASE IMAGE ("dogfooding")** on the
  new 32 GB SD card: user `lightspeedpi`, password `lightspeedpi`, NOPASSWD sudo. The old
  `jonathan` box no longer exists (its images are superseded, see §6). Key-based
  `BatchMode=yes` SSH only works if a key has been added under the overlay-off procedure
  (check `~/.ssh/authorized_keys` on the box). Any change to the appliance goes through
  `build-release-image.sh` → new release → boot test, never by hand-editing the box.
  The author's Mac SSH key WAS added to the appliance (overlay-off cycle, 2026-09-13) so
  `BatchMode=yes` works; the Mac's `known_hosts` entry for it was replaced with the
  release box's host key.
- **Dev box = the original 16 GB USB stick** (user `jonathan`, private image, the author's
  key). Used for changes/experiments; the appliance itself only ever runs a release. ⚠ Its
  `gain-control.py` and `gain-control.service` LAG the repo (pre keyboard-policy daemon,
  absolute-path unit) — deploy the repo copies before testing the daemon there. The release
  build never copies those two from the source, so this does not affect releases. The build
  script now also works when the SOURCE is a release box (no rename needed).
- Hostname is `lightspeed-bridge`; eth0 MAC `<pi-mac>` (router client list).
- ⚠ **Do NOT use `<wlan-hostname>` / `<pi-wlan-ip>`** — that resolves to **wlan0**,
  which has 54 ms average latency and 80 ms jitter from Wi-Fi power saving. eth0 is
  4.96 ms. The Pi is dual-homed on the same LAN.
- The box is **normally offline in use**. It only has internet when deliberately
  connected — so do any `apt install` while you have it.
- **Pi → Mac throughput is only ~1.6 MiB/s** (measured 2026-09-12; SSH works fine, bulk
  does not). Move anything large by USB stick: the user's `OKTOWIPE` stick (FAT32) is
  the one used for image captures. See BUILD-NOTES "Capture".
- **EEPROM BOOT_ORDER is SD first, then USB.** To boot the original USB stick (e.g. to work
  on the SD card offline), remove the card, power on, then hot-insert the card — this
  works (card detect + MMC rescan). The old USB image boots ~24 dB quieter, which is an
  easy way to tell which device booted.

### ⚠ The filesystem is READ-ONLY

Root is an overlay (tmpfs upper), `/boot/firmware` is mounted `ro`. **Every change is
discarded at reboot.** To make anything persist:

```bash
sudo raspi-config nonint disable_overlayfs && sudo reboot
# ... make changes, TEST them ...
sudo raspi-config nonint enable_overlayfs && sudo reboot
```

This is deliberate — the user pulls power at the end of a set without shutting down.
Only ~32 KiB is written per boot. Do not leave the overlay disabled.

### ⚠ Do not undo these — each was hard-won

1. **Realtime priority needs TWO files together.** `pipewire-service-rt.conf`
   (systemd starts PipeWire under SCHED_FIFO 88) **and** `rt-priority.conf`
   (`module.rt = false`). Remove the second and module-rt demotes the audio thread back
   to SCHED_OTHER, leaving realtime on the main thread and not the one doing the work.
   Verify: `ps -eLo cls,rtprio,comm | grep data-loop` → want `FF 88`.
2. **`52-no-monitor-ports.conf` prevents a feedback loop.** Without it, when no capture
   device is present the loopback attaches to the A50 sink's monitor:
   `A50 out → monitor → capture → playback → A50 out`. Verify:
   `pw-link -l | grep -c monitor_` → want `0`, including with no input attached.
3. **`NetworkManager-wait-online` and cloud-init are disabled.** Re-enabling costs
   30–90 s of boot time with no network cable attached.
4. **`rtkit-daemon` is masked.** It claims to grant realtime priority and does not.
5. **`53-sink-unity-volume.conf` pins the output at unity.** Without it, WirePlumber's
   stock sink default (0.064) races with node creation and some boots come up ~24 dB
   louder than others. See item 2.

`BUILD-NOTES.md` explains why each alternative fix fails, with evidence. Please read it
before "improving" any of the above.

---

## 1. ~~SD card write + boot A/B~~ — **DONE, SD card chosen**

**Result: the 32 GB SD card boots in 20 s vs 27 s for the original USB — 26% faster,
and it sits flush so nothing levers on the board in transit. It is the chosen boot
device.** Details and interpretation in `BUILD-NOTES.md`.

Remaining tidy-up (optional): run `--verify-only` on the SD card for a byte-for-byte
checksum. The write completed correctly and it boots and plays audio, but a read-back
comparison has never run — see the warning below.

<details>
<summary>Original in-flight notes (kept for context)</summary>

An SD card (32 GB, was labelled `OKTOWIPE`) is being written with the appliance image
via `restore-image.sh`, as `/dev/disk2` on the user's Mac. **Check it completed and
verified before anything else:**

```bash
cd ~/Projects/lightspeed-bt
tail -30 "$(ls -t restore-*.log | head -1)"      # want: "VERIFIED — device matches"
```

Then the user boots the Pi from it and times power-on → first audio by stopwatch, music
playing throughout.

### Boot A/B results so far

| Device | Boot | Form factor | Notes |
|---|---|---|---|
| Original USB stick (16 GB) | **27 s** | protrudes, can stress board in transit | baseline, 2 runs |
| "VendorCo" USB (16 GB) | **31 s** | flush, transit-safe | slow flash: wrote at 7.86 MB/s (~33 min) |
| 32 GB SD card | **pending** | flush, transit-safe | wrote at ~17 MB/s (~17 min), 1.9× faster |

⚠ **Neither device has been checksum-verified.** `restore-image.sh` had a bug where the
verify step killed the script silently: `head -c` closes the pipe, dd gets SIGPIPE
(exit 141), and under `set -euo pipefail` that propagated and exited with no message.
**Fixed** (pipefail disabled for that one pipeline, plus an early-exit guard that now
shouts). Both *writes* completed correctly — full byte counts, correct partition tables,
and the USB stick boots and plays audio — but a read-back comparison has never run.

To verify without rewriting:
```bash
sudo ./restore-image.sh /dev/diskN --verify-only    # writes NOTHING
```

</details>

**If you ever need to re-measure boot time:** `systemd-analyze` **cannot** do it — it
starts counting at kernel handoff and cannot see firmware, EEPROM init, `BOOT_ORDER`
probing or USB enumeration, which is where boot-device differences live. Use wall clock
(stopwatch power-on → first audio, or `boot-timing.sh` which polls SSH). The A50 base
station brings up its wireless link concurrently and independently, so it does not
inflate these numbers.

---

## 2. ~~BUG — input level inconsistent at boot~~ — **FIXED 2026-09-12 (it was the OUTPUT)**

**Root cause: not input gain at all.** The A50 base station has **no hardware volume
control**, so PipeWire applies a *software* volume to its sink. With no saved route,
WirePlumber applied its stock `device.routes.default-sink-volume` of **0.064 (≈ −24 dB)**
on every boot. There is a race in route → node propagation: when the A50 enumerates
*after* WirePlumber is up (it is USB-powered from the Pi and boots its own firmware, so
timing varies; guaranteed if plugged in late), the route reports 0.064 but the sink
**node** is sometimes left at **1.0** — ~24 dB louder with nothing touched. Reproduced by
hot-plugging the A50: 1.0 once, 0.064 once. The user confirmed by ear that this is the
level they had observed.

**Fix (persisted, overlay re-enabled):** `53-sink-unity-volume.conf` sets
`device.routes.default-sink-volume = 1.0`. Both sides of the race now agree, so the
output level is identical every boot. **Unity is the chosen operating level** — it gives
headroom; the headset's own wheel does the attenuation. Verified: 3 reboots × (boot + 2
hot-plugs) all at 1.0, with `FF 88`, 0 monitor links and 8 bridge links intact.

**What was ruled out (do not re-derive):**
- The Realtek adapter's capture gain is at its **0 dB ceiling** from *three* independent
  sources — power-on default (read with udev paused), stored ALSA state (47/47) and
  WirePlumber's default-source-volume (1.0). 5 consecutive reboots identical. It cannot
  come out louder.
- WirePlumber **always** writes an explicit capture volume on every boot (saved value or
  default — see `apply-routes.lua`) and always runs after `alsa-restore.service`
  (~4.4 s vs ~5.9 s). The "two owners race" for *gain* does not actually occur.
- Only the C-Media's **AGC** and the Realtek's **Extension Unit Switch** depend on alsactl
  alone. The udev-triggered per-card `alsactl restore` was verified to work from the
  read-only root (the "GOTO has no matching label" udev warnings are harmless — the RUN
  line is still reached).

## 3. ~~FEATURE — runtime gain control via USB keyboard / presenter clicker~~ — **BUILT 2026-09-12**

**Deployed and verified on two fresh boots** (overlay re-enabled). Files: `gain-control.py`
(→ `~/.local/bin/`), `gain-control.service` (user unit, enabled), `gain-status-screen.service`
(system unit, enabled), `gain-inject-test.py` (test tool, → `~/.local/bin/`).

**Decisions taken (user):** Page keys ±3 dB, Volume keys and arrows ±1 dB, one step per press
(autorepeat ignored), **period (KEY_DOT 52, the clicker's "blank screen" button) = reset to
default**, clamp −30..+10 dB around the boot default, silent clamp (logged). Mute unmapped.
Knob metaphor kept: Page Down / Right = louder, Page Up / Left = quieter.

**The user's clicker (JBQ90PRSNT, 0c45:6900)** sends, all on its keyboard interface:
Back = Page Up, Forward = Page Down, Vol± = Volume Up/Down, start/stop = alternating
Shift+F5 / Esc, blank = period. Mouse interface silent. Autorepeat ~4/s after ~0.5 s.

**Design changes vs the original plan — read `gain-control.py`'s docstring:**
- **`pactl` is NOT installed.** Uses `wpctl` with the cube conversion `cubic = 10**(dB/60)`,
  verified against the Realtek's hardware dB readout. Below the hardware floor PipeWire
  continues in software; above unity it is digital gain.
- **The Realtek adapter boots at its MAXIMUM analog gain (0 dB)** — "up" on that cable is
  digital gain only. The C-Media boots at +4.5 dB of +23.8 dB, so it has analog room.
- **Only devices advertising a MAPPED key are opened** (EVIOCGBIT on EV_KEY). First version
  opened and grabbed *every* `/dev/input/event*` — which silently **disabled the Pi 5 power
  button** (it is an input device `pwr_button` sending KEY_POWER to systemd-logind; user
  noticed). Fixed 2026-09-12. Mice and the clicker's pointer interface are skipped too.
- **Opened devices are GRABBED (EVIOCGRAB).** The kernel console/tty1 login otherwise also
  receives every keystroke (observed: the login prompt "typing" clicker keys). A local
  keyboard login needs the service stopped first.
- **Baseline = what WirePlumber restores at boot**, read from its `default-routes` state the
  FIRST time a source is seen, then cached per boot in `$XDG_RUNTIME_DIR/gain-control.json`.
  Do NOT re-read `default-routes` later: WirePlumber rewrites it on every volume change (tried;
  reset drifted to the last adjustment).
- Targets `@DEFAULT_AUDIO_SOURCE@`, so the C-Media fallback is covered without config.
- Logs every key, step, baseline, limit and source change → journal
  (`sudo journalctl -D /run/log/journal _SYSTEMD_USER_UNIT=gain-control.service`;
  note `--user-unit=` does NOT match here) and to **tty2** via `gain-status-screen.service`
  (`chvt 2` at boot; Alt+F1 for the tty1 login). Verify without a screen: `sudo cat /dev/vcs2`.
- Test without a clicker: `sudo ~/.local/bin/gain-inject-test.py 109 104 52` (uinput).

### 3b. ~~persist the last level across power cycles~~ — **DONE 2026-09-12**

Reverses the original "deliberately NOT persisted" design at the user's request: the box
restarts at whatever level was last set, so the clicker is not needed once configured.
**Period still resets to the true default (and persists 0).**

- Offset lives in `/var/lib/gain-control/offset.json` on **`/dev/mmcblk0p3`** — a 64 MiB ext4
  partition (label `gaindata`) created in the free space after rootfs, mounted
  `noatime,sync,data=journal` by **`var-lib-gain-control.mount`** (a systemd mount unit,
  installed as `/etc/systemd/system/var-lib-gain\x2dcontrol.mount`, enabled).
- ⚠ **It must be a mount unit, NOT an fstab entry.** overlayroot recurses into every ext4
  fstab entry: it mounted the partition read-only under `/media/root-ro/...` and put a
  throwaway overlay on top, so writes vanished at reboot (observed, then fixed).
- The daemon has a 5 s **control loop** (1 s until the first source is seen): whenever the
  source's volume disagrees with `base × offset` it re-applies. This is what makes the
  persisted offset win over WirePlumber's own route restore at boot, and covers replugs.
  Consequence: a manual `wpctl set-volume` during maintenance is undone within 5 s —
  `systemctl --user stop gain-control` first.
- Verified: −6 dB set → **hard reset via sysrq (no sync)** → restored at 7 s, re-applied at
  13 s after WirePlumber's restore → period → 0 persisted → clean reboot → default, nothing
  to correct. `FF 88`, 0 monitor links, 8 bridge links on every boot.
- Without the partition (a restore from the old image) the daemon logs
  "running WITHOUT persistence" once and otherwise works normally.

**Pending deploy:** `gain-control.py` here has the 1 s fast-poll tweak (not yet on the box —
deploy during the next maintenance window; the on-box version polls at 5 s throughout).

## 4. FUTURE — possible downgrade to a Raspberry Pi 3 B+

**Do items 2 and 3 on the Pi 5 first.** That is the known-good platform and the one with
a proper case. This is a later evaluation, not a blocker.

**Finding:** the SD card image boots and runs correctly on a **Raspberry Pi 3 B+** in
**25 s** (vs 20 s on the Pi 5). One card serves both boards.

**Why it works:** Raspberry Pi OS ships *both* kernels — `linux-image-rpi-2712`
(Pi 5, BCM2712) and `linux-image-rpi-v8` (Pi 3/4, ARMv8) — and the overlayroot install
generated **both** `initramfs_2712` and `initramfs8`. The firmware selects the matching
pair per board. Nothing special was done to achieve this; do not break it by pruning
"unused" kernels or initramfs images.

**Blocking question before adopting it — NOT YET TESTED under load:**

The Pi 3 B+ runs **all four USB ports AND Ethernet through a single USB 2.0 controller**
(LAN7515). The Pi 5 has separate, faster controllers. Bandwidth is not the issue
(48 kHz stereo ≈ 1.5 Mbit/s, trivial) — the risk is **interrupt latency and scheduling
jitter on that shared controller**, which is what bites at low quantum.

Current config runs **quantum 64 = 1.33 ms period**, measured clean on the Pi 5 at ~0.5%
CPU with SCHED_FIFO 88. The Pi 3 B+ has a much slower CPU *and* the shared bus, so it may
not hold 64. **"It booted and played audio" does not settle this** — xruns typically
appear under sustained load, not in a short check.

```bash
# with audio running for a few minutes, watch the ERR column
timeout 60 pw-top -b -n 20 | grep '^R'

ps -eLo cls,rtprio,comm | grep data-loop   # confirm FF 88 still applies
vcgencmd get_throttled                     # Pi 3 B+ caps USB at 1.2 A total, fussier PSU
```

If xruns appear, raise `default.clock.quantum` in `latency.conf` to **128** (already
measured clean on the Pi 5), then 256 if needed. This matches the user's original
instruction: raise the quantum rather than adding complexity.

**Non-technical blocker:** the Pi 5 has a professional-looking case; there is currently
no proper case for the 3 B+. Presentation matters for venue use, so the downgrade only
makes sense if a case is sorted *and* the xrun testing passes.

## 4b. FUTURE (deferred, no use case yet) — pass-through to the adapter's headphone jack

**Assessed 2026-09-12, feasible, negligible cost.** The Realtek adapter's own output could
carry the same audio for a second, wired listener. The graph driver is the adapter's
*input* node, so its output shares that clock — no new clock domain, no drift
resampling, one extra node at a few µs per 1.33 ms period.

If built: a **second loopback module** capturing the same source, playing to
`alsa_output.usb-Generic_USB_HP_MIC_Adapter-00.analog-stereo`, with
**`node.dont-fallback = true` on its playback** (WirePlumber 0.5.8 honours it —
`find-defined-target.lua`). Without that, an absent adapter sink makes the second stream
fall back onto the A50 and sum +6 dB into the headphones. Also: pin that jack's real
hardware volume (−65..0 dB, now at 0 dB after item 2) with a saved route; check for
analog bleed from the jack back into the capture on the same chip; retest the C-Media
fallback (no output exists there — stream must stay unlinked). The wired jack will lead
the wireless A50 by the radio latency. Alternative: `module-combine-stream` (a virtual
sink feeding both) — more moving parts, not preferred.

## 7. IN PROGRESS — public release image (session ended here, 2026-09-12 ~16:00)

**Goal:** a sanitised image to publish as a GitHub release asset (user `lightspeedpi`,
password `lightspeedpi`, NOPASSWD sudo, no host keys / history / caches / cloud-init
files, no 1.9 GB `/var/swap`, first boot auto-generates host keys then enables the
overlay and reboots — **no login needed**). Design is written up in README "Using the
release image". Build tool: `build-release-image.sh` + `lightspeed-firstboot.service`
(both in this directory, **updated after the failed run, not yet re-run**).

**What happened:** the first build run (older script version) was started on the Pi
while booted normally from the SD. It creates a temporary 8 GiB work partition
**`/dev/mmcblk0p4`** in the free space, a sparse image file on it, loop-mounts that and
rsyncs the running root into it. Part-way through, **SSH began resetting during key
exchange on every attempt** and the box did not recover after a reboot either. Cause not
established; suspects: memory/IO starvation from rsync + loop-over-sparse-file on the
same card + `zstd -T0 -12`, and a 5 MB+ progress log on tmpfs. **Two of my `pkill -f`
patterns also matched my own SSH command line and killed the session** — avoid that.

**Update 2026-09-13 00:00–02:30:** the Pi did not recover. The user restored
`lightspeed-bridge-8gb.img.zst` to the SD card TWICE; both writes completed with the exact
byte count, both verifications failed **with a different device hash each time**, and
`diskutil list` showed **no partitions at all** on the card afterwards. That is not the
script and not the image — the card is not holding what is written to it. It is a no-name
32 GB card (model string "SD SDABC", was labelled OKTOWIPE); the release build was the first
thing ever to write into its upper region, which is exactly where fake-capacity cards fail —
and that likely killed the running system too. **Confirmed 2026-09-13 ~02:45: `test-card.sh` fails on that card in TWO different SD
adapters — the card is dead. Do not reuse it.** The appliance moved to the original 16 GB
USB stick (restored from the same image) until a brand-name card is bought.
Tools added: `test-card.sh` (destructive fake/dying-card test, run on the Mac).
`restore-image.sh` also got a real fix: it now writes the partition table LAST so macOS
cannot auto-mount the FAT boot partition and scribble index files on it before the read-back
check (which would have failed verification on a GOOD card), and verifies partition by
partition.

**2026-09-13 morning:** `build-release-image.sh` (generalised to the boot device, low
priority, 2 zstd threads, memory logged) ran cleanly from the USB-stick boot: rsync total
1.6 GB → release archive **~640 MB** (7,054,819,328 bytes raw). Memory never below 7 GB
available. Two audit rounds (loop-mounting the archive on the Pi) caught: (1) `/etc/*-`
backup files carrying the old password hash, (2) **`/var/lib/cloud/`** — cloud-init's
cached imager config with name, email and SSH public key. Both now excluded, and the build
FAILS on a scrub grep for the exact email / home path / SSH key / account line outside
/usr (a broader name+gmail grep was tried and only matched Debian maintainers — kept as a
non-fatal warning list). **Fourth build is the release candidate:**
`lightspeed-bridge-8gb-release.img.zst`, 636,992,465 bytes, sha256 `ec5343f7…` (in the
`.sha256` file next to it), copied to the Mac and verified. Final audit (loop-mounted from
the archive): no cloud-init cache, no swap file, no host keys, empty machine-id, no shadow
backups, clean home, zero personal identifiers anywhere including /usr, firstboot unit
enabled with its marker absent, dphys-swapfile disabled, cmdline without overlayroot or
ds=nocloud, gaindata offset 0. Work partition removed from the stick; appliance unaffected.

**Boot test #1 of the release (2026-09-13, on the 32 GB "OKTOWIPE" USB stick, written
in ~30 min at 4.5 MB/s):** first boot ran, switched the overlay on and rebooted itself;
second boot passed audio. Good. **But the box could not be reached over SSH at all.**
The usual address answered ping with port 22 closed; `lightspeed-bridge.local` resolved
only to an IPv6 address, also port 22 closed; a "Permission denied (publickey)" from
another address turned out to be a DIFFERENT Pi on the LAN (false alarm). Most likely cause: SSH host
keys were not generated on the first boot (the release relied on the OS's
`regenerate_ssh_host_keys.service` with `ConditionFirstBoot=yes`), so sshd had no keys
and did not start — consistent with the router confirming the usual address as the box while port 22
stayed closed; no way in (the old daemon also grabbed any keyboard, so
no console login either). Note: after a rebuild the box may get a NEW DHCP address
(fresh machine-id ⇒ new NetworkManager client id); the Pi 5's eth0 MAC is
**`<pi-mac>`** (hostname `lightspeed-bridge` in the router's client list).
**Fixed in the repo, NOT yet rebuilt/retested:**
- `lightspeed-firstboot.service` now runs `ssh-keygen -A` + restarts sshd itself before
  enabling the overlay — no dependency on first-boot conditions.
- build removes any imager/cloud-init sshd drop-ins and adds
  `00-lightspeed-password-login.conf` (PasswordAuthentication yes) — the imager disables
  password login when it installs a key; whether that drop-in exists on the source is to be
  confirmed on the private boot (`ls /etc/ssh/sshd_config.d/`).
- daemon no longer grabs full keyboards (letter keys ⇒ read but not grabbed), so console
  login stays possible; build installs the repo's `gain-control.py` and
  `gain-status-screen.service` from `/tmp` rather than the source box's copies.
- status screen (tty2) now also follows `ssh.service`, `NetworkManager.service` and the
  first-boot unit, so a monitor shows the IP address and whether sshd is listening.
**Rebuilt 2026-09-13 09:30 with all of the above** (the source DID have
`sshd_config.d/50-cloud-init.conf` = `PasswordAuthentication no`): release candidate #2
`lightspeed-bridge-8gb-release.img.zst`, 636,161,781 bytes, sha256 `f69f4092…`, copied to
the Mac and verified; audit clean (only the 00- password drop-in, no host keys, empty
machine-id, first-boot unit with ssh-keygen -A + journal dump, new daemon + status screen).

**Boot test #2 (release #2, 2026-09-13 ~10:30) — PASS, release #2 is publishable.**
First boot: audio played, unit generated host keys, saved its journal, enabled the overlay,
rebooted. Second boot, inspected live over SSH as `lightspeedpi` with the password:
overlay on, /boot ro, unique host key, fresh machine-id, gaindata mounted rw with offset 0,
daemon + status screen active, `FF 88`, 0 monitor links, 8 bridge links, A50 at unity
(softVolumes 1.0), throttled 0x0, source signal present (−22.6 dBFS peak), A50 USB stream
consuming at 48 kHz; injected PageUp×2 / VolumeUp / period gave −6 / −5 / 0 dB with the
offset file following each step. The "no audio" scare on boot 2 was Spotify having
switched output device on the user's side — not the box. Session SSH key removed.
Cosmetic: the saved boot-1 log shows `ssh.service` failing 7× before the keys existed
(expected) and our `systemctl restart ssh` at 11.6 s refused because ssh had hit its
start-rate limit — harmless, sshd is fine from boot 2. If the unit is ever rebuilt, add
`systemctl reset-failed ssh` before the restart; NOT changed now so the repo unit matches
the tested image. Also: `sda` order can change (Adapter was card 3 this boot) — irrelevant.

**Boot test #3 (release #2 on the NEW 32 GB SD card, 2026-09-13 ~12:00) — PASS.** Card
passed `test-card.sh` (33 MB/s). Same checks as #2, all good: booted from `mmcblk0p2`,
overlay on, marker present, first-boot log saved (1060 lines, keygen 1, pipewire
started), unique host key (differs from the USB test box), fresh machine-id, gaindata rw
offset 0, daemon active, `FF 88`, 0/8 links, A50 unity, throttled 0x0, A50 consuming
48,144 frames/s, injected PageUp → −3 dB persisted, period → 0. Session key removed.
**The release image is verified on both SD and USB media.**

**User's observations from boot test #1 (release #1), NOT reproduced in tests #2/#3:**
(a) *no audio at all on the first boot*, audio only from the second boot; (b) the output
level was NOT at the unity default on the second boot, only on a third boot the user did
by hand. Neither is explained yet. Theory for (b): WirePlumber persisted something to
`~/.local/state/wireplumber/` during boot 1 (filesystem writable then) that boot 2
restored. **Retest procedure:** write release #2 to the test stick, boot, let it self-reboot
ONCE, then DO NOT reboot again — log in on that second boot (`lightspeedpi`, password;
find the address via the router: MAC `<pi-mac>`) and inspect live: A50
`softVolumes`, `~/.local/state/wireplumber/default-routes`, gain-control journal, and
read `/var/lib/lightspeed-firstboot.log` for boot 1 (why no audio?). A helper that logs in
with the password via `expect` is at
`scratchpad/release-check.sh <ip>` (session-local; trivial to recreate).

**PUBLISHED 2026-09-13:** https://github.com/jonathan-annett/lightspeed-bridge (public, MIT),
release `v1.0.0` with `lightspeed-bridge-8gb-release.img.zst` + `.sha256` as assets.
LAN addresses/MAC/hostnames were scrubbed to `<pi-ip>`, `<pi-mac>`, `<wlan-hostname>`
before the first commit; the real values live only in the router and in this session.
Personal scrub patterns are in the gitignored `scrub-patterns.txt` (copy to `/tmp` on the
Pi before a release build). The "private-image cleanup" (old step 2) is OBSOLETE: the
appliance runs the release, which has no swap file or caches.

**Future release procedure:** change files in the repo → deploy to the dev stick and test →
boot the appliance-or-dev box, `scp build-release-image.sh lightspeed-firstboot.service
gain-control.py gain-status-screen.service scrub-patterns.txt <box>:/tmp/` → run the build
→ copy the archive off (USB stick; network is slow) → `test-card.sh` a card, write, boot-test
twice → `gh release create vX.Y.Z <zst> <sha256>` → commit.

**Next steps when resuming:**
0. `sudo ./test-card.sh /dev/diskN` on the suspect card. Expect it to fail. Then restore the
   image to the original 16 GB USB stick (or a brand-name ≥ 8 GB card) with the fixed
   `restore-image.sh` and boot the Pi from that — the appliance is back at that point.
1. Power-cycle the Pi. If it boots and SSH works: nothing on the card's root was
   touched (overlay), only `p4` was added — `sudo parted -s /dev/mmcblk0 rm 4` after
   `umount /mnt/relwork`, and carry on. If it does NOT recover: restore
   `lightspeed-bridge-8gb.img.zst` with `sudo ./restore-image.sh /dev/diskN` on the Mac
   (it is a verified exact image of the card from before this attempt; the user's last
   clicker offset was 0 anyway). Then boot, run the standard checks (item 3b list).
2. **Do the live-box cleanup first** (overlay off): `apt clean`, `rm -rf /var/lib/apt/lists/*`,
   `systemctl disable dphys-swapfile`, `rm /var/swap` (1.9 GB, unusable under the overlay,
   zram is in use — confirm `swapon --show` is empty). Optionally deploy the `%h` version of
   `gain-control.service` (repo copy already uses it; the box has the absolute path — both
   work). Overlay on. Then **re-capture the private image** (USB-stick boot method, BUILD-NOTES
   "Capture") — it should drop well under 1 GB compressed.
3. Re-run `build-release-image.sh` **from the USB-stick boot** rather than from the SD
   (so the source card is idle and the loop device is not stacked on the running root),
   with `nice -n 19 ionice -c3`, and consider `zstd -T2 -9` to leave headroom. Watch
   `free -m` while it runs. Then copy the result off by USB stick (network is 1.6 MiB/s).
4. **Boot-test the release image** before publishing: write it to the old 16 GB USB stick,
   boot with the SD removed, confirm: first boot enables the overlay and reboots itself;
   second boot has audio, unique host keys (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`
   differs from the private box), `lightspeedpi` login works, `FF 88`, 0 monitor links.
   The user also wants to try a few different USB sound cards against it.
5. Publish: repo (README, .gitignore ready; scrub the LAN IPs/hostname mentions in the
   two notes files first) + the release image as a release asset with its sha256.

## 5. Hardware facts worth not re-deriving

- **Spontaneous reboots/power-offs (2026-09-12) — most likely ESD.** Happened often when
  the user shuffled across carpet and touched the metal case; two occurred during this
  session (one looked like a power-off, one a reset; logs are volatile so nothing was
  captured). Mitigated by cable-tying every cable down and replacing the USB lead to the
  input sound card with one that has an RF choke. Not reproducible since. Unconfirmed
  but plausible; if it recurs, an earthed supply / grounding the case is the next step.

- **Power: one PSU is sufficient.** Base station is USB-powered from the Pi. Measured:
  base station **0.27 A**, whole system **≤ 0.7 A** — **but 1.52 A max with the headset
  charging on the base** (measured 2026-09-12; base station then ≈ 1.1 A, which exceeds
  the Pi's 600 mA clamp, so a detected 5 A PSU is required for charging — **the official
  27 W 5 A supply is in use and the Pi negotiates 5000 mA** — confirmed 2026-09-12, see
  BUILD-NOTES "Power"). Pi 5 clamps USB to 600 mA total if
  it does not detect a 5 A PSU — at ~0.35 A total USB draw there is ~40% headroom even
  then. Confirm with `vcgencmd get_throttled` → want `0x0` (no under-voltage ever this
  boot). **This check has not yet been run** — worth doing after a real session.
- **Card numbers are NOT stable** across boots or replugs (the A50 has been card 0 and
  card 2). Always target by `node.name`.
- **`pw-link -l` is not a liveness check** — it reported 8 links while the card was
  absent from `/proc/asound/cards`. Use `wpctl status` or `/proc/asound/cards`.
- **The image was compacted on 2026-09-12** (`shrink-sd.sh`, run from the USB stick with
  the SD hot-inserted): rootfs shrunk 14.1 → **6 GiB** (4.0 GiB used), `gaindata` moved to
  sit right behind it. **`lightspeed-bridge-8gb.img.zst` is 7,054,819,328 bytes raw
  (6.57 GiB) and fits any nominal 8 GB card.** PARTUUIDs unchanged. The old
  `lightspeed-bridge-16gb.img.zst` needed ≥ 15,682,240,512 bytes and predates all of
  today's work — superseded, safe to delete.
- **The mono C-Media XLR cable is noisy at factory defaults** (+23.81 dB mic gain with
  AGC on). Corrected and persisted. Its measured digital path was clean — zero clipping,
  zero glitches, L==R 100% on upmix. A true noise-floor measurement was never taken
  because signal was present in every sample window; that needs the XLR source
  disconnected. Also: a PCM2902 expects **mic level** — a line-level source needs
  padding at the source, not on the Pi.

---

## 6. Files in this directory

| File | Purpose |
|---|---|
| `BUILD-NOTES.md` | **Authoritative.** Full build record, measurements, dead ends |
| `lightspeed-bridge-8gb.img.zst` | ⚠ **SUPERSEDED 2026-09-13** by the release image (the appliance now runs the release). Last private image (user `jonathan`, author's SSH key, 1.9 GB swap file); keep only as a historical fallback |
| `lightspeed-bridge-8gb.img.raw.sha256` | sha256 of that superseded image, decompressed (`13844052…`) |
| `lightspeed-bridge-16gb.img.zst` | ⚠ **SUPERSEDED** — predates all 2026-09-12 work and needs a 16 GB+ card. Safe to delete |
| `shrink-sd.sh` | The compaction script (run on the Pi booted from another device). Kept for reference; already applied |
| `image.sha256` | sha256 of the superseded private `8gb` archive (`b9b8fe14…`) |
| `restore-image.sh` | Guarded, logged restore tool. `sudo ./restore-image.sh /dev/diskN --image lightspeed-bridge-8gb-release.img.zst` (the default image name is the superseded private one — pass `--image`) |
| `boot-timing.sh` | Automated boot timing (polls SSH; needs network) |
| `restore-*.log` | Logs from restore runs |
| `loopback.conf` | → `~/.config/pipewire/pipewire.conf.d/` |
| `latency.conf` | → `~/.config/pipewire/pipewire.conf.d/` |
| `rt-priority.conf` | → `~/.config/pipewire/pipewire.conf.d/` |
| `pipewire-service-rt.conf` | → `~/.config/systemd/user/pipewire.service.d/rt.conf` |
| `50-disable-a50-mic.conf` | → `~/.config/wireplumber/wireplumber.conf.d/` |
| `52-no-monitor-ports.conf` | → `~/.config/wireplumber/wireplumber.conf.d/` |
| `53-sink-unity-volume.conf` | → `~/.config/wireplumber/wireplumber.conf.d/` (fixes item 2) |
| `gain-control.py` | → `~/.local/bin/` — clicker gain daemon (items 3, 3b). ⚠ local copy has the 1 s fast-poll tweak not yet deployed |
| `var-lib-gain-control.mount` | → `/etc/systemd/system/var-lib-gain\x2dcontrol.mount` (enabled) — mounts the `gaindata` partition |
| `gain-control.service` | → `~/.config/systemd/user/` (enabled) |
| `gain-status-screen.service` | → `/etc/systemd/system/` (enabled) — journal follower on tty2 |
| `gain-inject-test.py` | → `~/.local/bin/` — uinput key injector for testing without a clicker (root) |
| `lightspeed-bridge-8gb-release.img.zst` (+ `.sha256`) | **THE image.** Sanitised public release #2 (user `lightspeedpi`), 636 MB, sha256 `f69f4092…`. Boot-tested on USB and SD 2026-09-13; the appliance runs it |
| `build-release-image.sh` + `lightspeed-firstboot.service` | Builds the release image on the Pi from the running appliance; the unit ships inside the release only |
| `test-card.sh` | Destructive fake/dying media test (Mac, sudo). Run on any new card BEFORE restoring to it |
| `audio.conf` | → `/etc/security/limits.d/` |
| `50-audio-limits.conf` | → `/etc/systemd/system/user@.service.d/` |
| `loopback-auto.conf` | **SUPERSEDED — do not deploy.** The untargeted design that caused the feedback loop. Kept for reference only. |

### Gotchas when working in this directory
- **Do not edit `restore-image.sh` while it is running.** Bash reads scripts
  incrementally from disk; editing mid-run can make it jump to the wrong offset.
- `restore-image.sh` logs via `tee` with an EXIT trap that waits for the flush. An
  earlier version lost the tail of the log (the VERIFIED line) — fixed, but if you see a
  log that ends mid-run, suspect that rather than assuming the run failed.
