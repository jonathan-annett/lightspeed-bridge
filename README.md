# Lightspeed USB Audio Bridge

A headless Raspberry Pi appliance that feeds a mixing console's PFL (pre-fade
listen) or any line feed into a Logitech A50 Lightspeed wireless headset, so an
audio engineer can solo channels on the desk without taking off their comms
headset. There is no PC, no screen, no login and no network involved.

## The use case

At an event the sound operator usually wears two things: a headset for the
intercom, and a pair of headphones for PFL. Swapping between them, or wearing
both, gets old quickly. The A50 base station accepts a Bluetooth headset
connection alongside its own wireless link and mixes the two, so one headset can
carry the intercom from a phone or Bluetooth-capable comms unit and the desk's
PFL at the same time.

This box is the missing piece: it takes the desk's PFL output on a USB capture
device and delivers it to the A50's wireless link. The operator solos a channel,
hears it in the same headset they are talking on, and never breaks comms.
Performers could use it for the same reason, but it is designed around the
operator's chair.

Because it lives at the desk during a show it has to behave like a piece of
gear, not a computer. It boots to audio in about 20 seconds, holds a 1.3 ms
processing period on a realtime thread with zero dropouts, recovers from any
cable being unplugged and replugged, and survives having its power pulled at the
end of the night because the root filesystem is a read-only overlay. Input gain
can be trimmed live from an ordinary USB presenter clicker, and the last setting
survives a power cycle.

Everything here is plain Raspberry Pi OS plus PipeWire and WirePlumber. There is
no custom audio code, only configuration, one small Python daemon and a handful
of systemd units.

## Hardware

| Role | Device | Notes |
|---|---|---|
| Computer | Raspberry Pi 5 | Also boots and runs on a Pi 3 B+, untested under load |
| Boot media | 32 GB SD card | Image is 6.6 GiB, so any 8 GB card works |
| Output | Logitech A50 Lightspeed base station | USB, `046d:0b1c`, powered from the Pi. Mixes in a Bluetooth headset connection natively, which is how comms are overlaid |
| Input (primary) | Realtek USB-C stereo adapter | `0bda:49dd`, genuinely stereo. A USB-C dongle plugs into one of the Pi's USB-A ports with a C-to-A cable or adapter; it is an ordinary USB audio class device either way |
| Input (fallback) | C-Media XLR to USB cable | `08bb:2902`, mono, PCM2902 codec |
| Gain control | Any USB keyboard or presenter clicker | Tested with a JBQ90PRSNT |

One 5 A supply runs everything. The whole system draws under 0.7 A in use, and
a measured maximum of 1.52 A, under 8 W, while the base station is charging
the headset. That charging load exceeds the USB budget the Pi 5 allows itself
when it cannot identify a 5 A supply, so use the official supply or one that
advertises 5 A.

## How it connects

![Basic setup: mixing desk PFL into a USB audio card, into the Raspberry Pi, USB audio and power out to the A50 base station, Lightspeed radio to the headset; a phone or comms unit joins over Bluetooth at the base station; one 5 A USB-C supply powers everything](docs/connections.svg)

That is the whole basic setup. Power on, wait about 20 seconds, listen.
Everything else on this page is either how it works inside or optional.

## How it works

- **PipeWire** runs as the user at boot (linger enabled) with a quantum of 64
  samples at 48 kHz. Both USB devices are native 48 kHz, so nothing is resampled.
- A single **loopback module** captures from the named input device and plays to
  the named output. If the named input is missing it falls back to whatever
  capture device is present, so the mono XLR cable works with no config change.
  If nothing is present it stays silent rather than feeding back.
- **WirePlumber** policy files disable the base station's own microphone, remove
  monitor ports (the only route by which a feedback loop could form) and pin the
  output volume at unity on every boot.
- The audio thread runs at **SCHED_FIFO priority 88**, granted by systemd rather
  than rtkit, which is masked because it claims to grant realtime and does not.
- The root filesystem is an **overlay with a tmpfs upper**, so nothing written at
  runtime survives a reboot. The one exception is a tiny journaled data partition
  holding the clicker's last gain setting.
- A **gain daemon** reads raw input events from every keyboard-like device,
  applies steps through wpctl, and clamps the range. A **status screen** on
  virtual console 2 shows its log if a monitor is ever plugged in.

`BUILD-NOTES.md` is the full record: measurements, the reasoning behind each
decision, and several dead ends that look like reasonable fixes but are not.
Read it before changing anything that it marks as hard-won.

## Repository contents

| File | Installs to | Purpose |
|---|---|---|
| `loopback.conf` | `~/.config/pipewire/pipewire.conf.d/` | The bridge itself. Names the input and output devices |
| `latency.conf` | `~/.config/pipewire/pipewire.conf.d/` | Quantum 64, 48 kHz only |
| `rt-priority.conf` | `~/.config/pipewire/pipewire.conf.d/` | Disables PipeWire's own rt module so systemd's priority sticks |
| `pipewire-service-rt.conf` | `~/.config/systemd/user/pipewire.service.d/rt.conf` | Starts PipeWire under SCHED_FIFO 88 |
| `50-disable-a50-mic.conf` | `~/.config/wireplumber/wireplumber.conf.d/` | Hides the base station's headset mic from source election |
| `52-no-monitor-ports.conf` | `~/.config/wireplumber/wireplumber.conf.d/` | Removes monitor ports, which prevents the feedback loop |
| `53-sink-unity-volume.conf` | `~/.config/wireplumber/wireplumber.conf.d/` | Deterministic unity output volume on every boot |
| `audio.conf` | `/etc/security/limits.d/` | rtprio and memlock limits for the audio group |
| `50-audio-limits.conf` | `/etc/systemd/system/user@.service.d/` | Same limits for the user manager, with a finite RTTIME |
| `gain-control.py` | `~/.local/bin/` | Clicker and keyboard gain daemon |
| `gain-control.service` | `~/.config/systemd/user/` | Runs the daemon after PipeWire |
| `gain-status-screen.service` | `/etc/systemd/system/` | Follows the journal onto tty2 |
| `var-lib-gain-control.mount` | `/etc/systemd/system/var-lib-gain\x2dcontrol.mount` | Mounts the small data partition for the saved gain |
| `gain-inject-test.py` | `~/.local/bin/` | Injects key codes through uinput to test the daemon without a clicker |
| `restore-image.sh` | run on a Mac | Guarded, logged image writer with read-back verification |
| `shrink-sd.sh` | run on the Pi | Compacts the card so the image fits 8 GB media. Already applied |
| `build-release-image.sh` | run on the Pi | Builds the sanitised, publishable image from the running appliance. Reads personal identifiers to refuse from a gitignored `scrub-patterns.txt` |
| `lightspeed-firstboot.service` | inside the release image only | First boot: generates SSH host keys, saves that boot's journal, enables the overlay, reboots |
| `test-card.sh` | run on a Mac | Destructive write-and-read test that catches fake-capacity and dying cards. Run it on any new card first |
| `boot-timing.sh` | run on a Mac | Measures power-on to SSH by wall clock |
| `loopback-auto.conf` | do not install | Superseded design kept for reference. It is the one that fed back |
| `BUILD-NOTES.md` | | Authoritative build record |
| `TODO-next-session.md` | | Working handoff notes, including things assessed and deferred |

The disk images are not in the repository. The sanitised one is published as
a release asset; see "Using the release image".

## Using the release image

The release is a compressed image of the whole card, about 640 MB, expanding
to 6.6 GiB, so any nominal 8 GB card or USB stick will take it. Write it with
`restore-image.sh` on a Mac or with any raw imaging tool, then boot the Pi
with the A50 base station and a USB capture device attached.

The first boot takes about a minute and needs no login. The image ships with
the read-only overlay switched off so that this one boot can persist changes:
it generates its own SSH host keys, switches the overlay on and reboots
itself. From the second boot on it is the finished appliance: about 20 seconds
from power to audio, and safe to unplug without a shutdown.

You do not have to log in at all. If you want to, the credentials are:

| | |
|---|---|
| User | `lightspeedpi` |
| Password | `lightspeedpi` |
| Hostname | `lightspeed-bridge` |

The user has passwordless sudo, so anything is possible from there. Ethernet
gets an address by DHCP when a cable is present, and SSH is enabled. To change
the password, or anything else, disable the overlay first or the change will
vanish at the next reboot:

```bash
sudo raspi-config nonint disable_overlayfs && sudo reboot
# make changes, test them
sudo raspi-config nonint enable_overlayfs && sudo reboot
```

Any USB capture device should work as the input without configuration: the
bridge prefers the device named in `loopback.conf` and otherwise takes
whatever capture device is present. The output is bound to the A50 by name.
With a different headset base station, edit the output name as described
under customising, and check whether the base station exposes a microphone
of its own, which would need the same treatment as the A50's.

## Building one from scratch

Building from scratch rather than from the release image is roughly:

1. Raspberry Pi OS Lite, 64-bit, Debian 13. The image was built with PipeWire
   1.4.2 and WirePlumber 0.5.8.
2. Install `pipewire`, `pipewire-pulse` and `wireplumber`. Run
   `loginctl enable-linger <user>` so the user session starts at boot.
3. Copy the files in the table above to their destinations. The user units use
   `%h` for the home directory, so any username works; the sudoers entry and
   the linger setting name the user explicitly.
4. Apply the system changes listed under "System changes outside home" in
   `BUILD-NOTES.md`: mask rtkit, disable `NetworkManager-wait-online` and
   cloud-init, add the sudoers entry, mount `/boot/firmware` read-only.
5. Set any device-specific mixer controls with `amixer`, then
   `alsactl store` so they are restored at boot. For the C-Media cable that
   means turning its automatic gain control off.
6. Verify (see below), then enable the overlay:
   `sudo raspi-config nonint enable_overlayfs && sudo reboot`.
7. For the persisted gain setting, create a small ext4 partition labelled
   `gaindata` and install the mount unit. It must be a mount unit, not an
   fstab entry, because overlayroot overlays every ext4 entry it finds in fstab.

## Customising for different devices

Almost everything device-specific is a node name. Plug the device in and list
what PipeWire calls it:

```bash
pw-cli ls Node | grep -E "alsa_(input|output)"
```

Card numbers are not stable across boots or replugs, so always target by
node name, never by `hw:N`.

### A different input device

Put its `alsa_input...` node name into `target.object` in the `capture.props`
block of `loopback.conf`. That is the preferred device. Any other capture
device that is present when the preferred one is absent is picked up
automatically, so a second cable needs no configuration at all. Do not add a
second loopback module per cable: two modules grab the same source when only
one cable is present and sum into the output at about +6 dB.

For a mono device, leave `audio.position` as `[ FL FR ]` and PipeWire upmixes
it to both ears with no level loss.

Check the device's own mixer controls with `amixer -c <N> contents`. Some
cables ship with automatic gain control on or with a high default gain, which
PipeWire does not manage. Set them once and `alsactl store`.

### A different output device

Put its `alsa_output...` node name into `target.object` in the
`playback.props` block of `loopback.conf`. If the output device is a headset
base station that also exposes a microphone, adjust the match pattern in
`50-disable-a50-mic.conf` so its mic cannot be elected as the default source.
If the output device has a real hardware volume control, WirePlumber will use
it and `53-sink-unity-volume.conf` sets that to maximum, so choose a level
that suits.

### A different sample rate

Both devices here are native 48 kHz. If yours are 44.1 kHz, change
`default.clock.rate` and `default.clock.allowed-rates` in `latency.conf`.
Mixed rates work but force resampling.

### A different keyboard or clicker

The daemon maps Linux key codes to gain steps in `KEYMAP` near the top of
`gain-control.py`. To see what your device sends, read its event node while
pressing buttons. The daemon logs every mapped key it sees by name, so the
simplest way is to start it and watch the journal:

```bash
sudo journalctl -D /run/log/journal -f _SYSTEMD_USER_UNIT=gain-control.service
```

For unmapped keys, `evtest` is the usual tool if you can install it. Media
keys on a composite keyboard usually arrive on a second event node, which is
why the daemon opens every node rather than the first keyboard it finds.

The current mapping follows a knob metaphor: a clicker's forward button (Page
Down) turns the gain up and its back button (Page Up) turns it down. Page keys
step 3 dB, volume keys and arrows step 1 dB, and the period key, which a
clicker sends for "blank screen", resets to the boot default. The range is
clamped to −30 to +10 dB around that default. All of these are constants at
the top of the script.

The daemon only opens devices that advertise at least one mapped key, which
leaves the Pi 5's power button and any mouse alone. Clicker-like devices are
grabbed exclusively so their keystrokes do not also land on the console's
login prompt. A full keyboard, one with letter keys, is read but not grabbed:
its Page, arrow and volume keys still steer the gain, and it can still be used
to log in on the console.

### Which Raspberry Pi

The image carries both 64-bit kernels Raspberry Pi OS ships, and the firmware
picks the right one for the board, so one image serves several models.

| Board | Status | Notes |
|---|---|---|
| Raspberry Pi 5 | Tested, the reference | With the official 27 W supply it can power the base station too |
| Raspberry Pi 3 B+ | Tested | Same image, same 64-sample quantum, no xruns with Ethernet on the shared USB 2.0 controller. Boots in 25 s from an SD card, but 57 s from a USB stick, because this board's bootloader probes USB slowly: use an SD card on it. About half the price of a Pi 5, so the sensible choice for a dedicated box |
| Raspberry Pi 4 | Expected to work, untested | Same kernel as the 3 B+, faster, better USB layout |
| Raspberry Pi Zero 2 W | Boots the same kernel, untested, not recommended | One USB port, so it needs a powered hub, which costs about the difference to a 3 B+ |
| Pi Zero, Pi 1, Pi 2 | Will not work | 32-bit boards; the image is 64-bit only |
| Other boards (Orange Pi and similar on Armbian) | Image will not boot | The configuration above the OS is portable, the image is not: it carries Raspberry Pi firmware, kernels and first-boot tooling |

**Power the base station from its own supply on anything but a Pi 5.** The
3 B+ and 4 allow 1.2 A across all their USB ports, and the base station
draws about 1.1 A while charging the headset. The supply it needs comes in
the box with it. The base station does run from a 3 B+ port while it is only
passing audio, at about 0.27 A, so it will appear to work; what fails is the
Pi, browning out the moment the headset docks to charge. On a Pi 5 with the
official supply the base station can share the Pi's power, which is a
convenience, not a saving.

If xruns ever appear on a slower board, raise `default.clock.quantum` in
`latency.conf` to 128, then 256.

## Advanced and development

None of this is needed for normal use. It is what the box offers when you
plug more into it.

- **Presenter clicker or USB keyboard.** Plug one into any USB port, at boot or
  later, and it adjusts the input gain live: Page Down and Page Up step 3 dB,
  the volume keys and arrow keys step 1 dB, and the period key, which
  clickers send for "blank screen", resets to the boot default. The last
  setting survives a power cycle. Details under customising.
- **Ethernet.** Plug in a cable and the box takes a DHCP address and accepts
  SSH as `lightspeedpi`. Nothing on the box needs the network, and it never
  waits for one at boot.
- **HDMI monitor.** A screen shows a live status console on virtual terminal
  2: the gain daemon, PipeWire and WirePlumber, the SSH server and the
  network, so you can see the address it took and whether SSH is up. Alt+F1
  gets the ordinary login prompt.
- **Second wired output.** The capture adapter's own headphone jack could
  carry the same audio for a second listener. It is assessed but not built;
  the notes in `TODO-next-session.md` describe how, and the one trap to
  avoid.
- **Development.** Keep a second boot medium with your own SSH key on it and
  do experiments there. The appliance itself only ever runs a release image,
  built from the running system by `build-release-image.sh`.

## Operating and verifying

Everything here is read-only and safe to run on a live box:

```bash
ps -eLo cls,rtprio,comm | grep data-loop      # want: FF 88
pw-link -l | grep -c monitor_                 # want: 0, also with no input attached
pw-link -l | grep -c audio_bridge             # want: 8 with both devices present
wpctl status                                  # devices, sinks, sources, volumes
timeout 60 pw-top -b -n 20 | grep '^R'        # ERR column should stay 0
vcgencmd get_throttled                        # want: 0x0
```

Logs are volatile by design and must be read from the runtime journal:

```bash
sudo journalctl -D /run/log/journal -b
```

The status screen on tty2 shows the gain daemon, PipeWire and WirePlumber
logs. Alt+F1 gets the login prompt. Without a monitor, `sudo cat /dev/vcs2`
shows what the screen would show.

To make a persistent change, disable the overlay, reboot, change and test,
then re-enable it:

```bash
sudo raspi-config nonint disable_overlayfs && sudo reboot
# ...
sudo raspi-config nonint enable_overlayfs && sudo reboot
```

Do not leave the overlay disabled. The appliance is expected to lose power
without a shutdown.

## Things that look like fixes but are not

Each of these was tried and is documented with evidence in `BUILD-NOTES.md`:

- Enabling rtkit. It does not grant the priority it claims to.
- Removing `rt-priority.conf`. PipeWire's rt module then demotes the audio
  thread while the main thread keeps the realtime priority.
- Setting `node.dont-reconnect` on the loopback. It blocks the wrong fallback
  and also the correct connection, so the bridge goes permanently silent.
- One loopback module per cable. They sum.
- Aggressive ALSA buffer tuning. It bought about a millisecond nobody can hear
  and added crackle risk under load.
- Re-enabling `NetworkManager-wait-online`. It costs up to 90 seconds of boot
  with no cable attached.
- Diagnosing "input level changed" as input gain. On this hardware it was the
  output sink's software volume racing WirePlumber's default.

## Status

Working and in use. Assessed but deferred: a pass-through to the input
adapter's own headphone jack for a second wired listener, and a downgrade to a
Pi 3 B+. Both are written up in `TODO-next-session.md`.

## License

MIT. See `LICENSE`.
