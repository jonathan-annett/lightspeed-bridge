#!/usr/bin/env python3
"""gain-control — adjust the bridge's INPUT gain live from a USB keyboard / presenter clicker.

Install:  ~/.local/bin/gain-control.py   (+ gain-control.service as a user unit; works for any user)

- Reads /dev/input/event* directly (24-byte input_event, 'llHHi' on aarch64). No packages.
- Opens EVERY event node and rescans every 2 s: composite keyboards put media keys on a
  separate node, and a clicker may be plugged in mid-session.
- Only opens devices that report at least one MAPPED key in their EV_KEY capabilities
  (EVIOCGBIT). This leaves the Pi 5 POWER BUTTON alone (it is an input device sending
  KEY_POWER, handled by systemd-logind — grabbing it disabled the button, observed), and
  likewise mice, the clicker's pointer interface, etc.
- GRABS clicker-like devices exclusively (EVIOCGRAB) so the kernel console / tty1 login
  prompt does not also receive their keystrokes. A FULL keyboard (one with letter keys) is
  read but NOT grabbed: its Page/arrow/volume keys still steer the gain, and it can still be
  used to log in on the console. (Grabbing everything locked out local login entirely —
  found while testing the public release image.)
- Acts on key PRESS only (value 1). Autorepeat (2) and release (0) are ignored, so a held
  button cannot run the gain away.
- Gain is applied to @DEFAULT_AUDIO_SOURCE@ via wpctl, so the C-Media fallback is covered.
  wpctl's scale is CUBIC: cubic = 10 ** (dB / 60). Verified 2026-09-12 against the Realtek
  adapter's hardware dB readout (-9 dB requested -> -9.4 dB, its nearest 0.375 dB step).
  Below the hardware floor PipeWire continues in software; above unity it is digital gain.
- State is an OFFSET (dB) from the boot-default of the current source, re-applied
  absolutely each time, so hardware quantisation never accumulates. The boot default is
  read from WirePlumber's OWN state (~/.local/state/wireplumber/default-routes, else its
  device.routes.default-source-volume setting) the FIRST time a source is seen — i.e.
  before anything has changed it — and cached, with the current offset, in
  $XDG_RUNTIME_DIR/gain-control.json. That is tmpfs, cleared at boot, so nothing survives
  a power cycle; but a crash-restart mid-set keeps the reference AND the current level.
  (WirePlumber rewrites default-routes on every volume change, so it cannot be re-read
  later — that was tried and reset drifted to the last adjustment.)
- PERSISTED across power cycles (user decision 2026-09-12, reversing the earlier "not
  persisted" design): the offset is written to PERSIST_FILE on a small journaled data
  partition mounted at /var/lib/gain-control (the root is a read-only overlay; the FAT
  boot partition is not power-pull safe). The partition is mounted by a native systemd
  mount unit, NOT fstab: overlayroot recurses into every ext4 fstab entry and would put a
  throwaway overlay on top of it (observed). If the mount is absent (e.g. a restore from
  the pre-2026-09-12 image), the daemon logs it once and simply runs without persistence.
  RESET (period) sets the offset to 0 and persists 0 — so the box boots at the true
  default again until the next adjustment.
- CONTROL LOOP: every SOURCE_POLL_S the daemon compares the source's current volume with
  base * 10**(offset/60) and re-applies on mismatch. This is what makes the persisted
  offset take effect at boot (WirePlumber restores its own route volume ~1 s after start,
  which would otherwise overwrite an early set) and after a cable replug. An external
  wpctl change during maintenance is therefore undone within 5 s — stop the service first.

Key mapping ("think of it as a knob" — clicker FORWARD = clockwise = louder):
  Gain UP    : Page Down (109) +3 dB   | Volume Up (115), Right (106), Up (103)    +1 dB
  Gain DOWN  : Page Up   (104) -3 dB   | Volume Down (114), Left (105), Down (108) -1 dB
  RESET      : period / KEY_DOT (52) — the clicker's "blank screen" button -> offset 0
"""
import fcntl, glob, json, math, os, select, struct, subprocess, sys, time

STEP_COARSE = 3.0
STEP_FINE = 1.0
CLAMP_MIN, CLAMP_MAX = -30.0, 10.0          # dB relative to boot default
RESCAN_S = 2.0
KEYMAP = {109: +STEP_COARSE, 104: -STEP_COARSE,
          115: +STEP_FINE, 114: -STEP_FINE,
          106: +STEP_FINE, 105: -STEP_FINE,
          103: +STEP_FINE, 108: -STEP_FINE}
KEY_RESET = 52
KEYNAMES = {109: 'PageDown', 104: 'PageUp', 115: 'VolumeUp', 114: 'VolumeDown', 106: 'Right',
            105: 'Left', 103: 'Up', 108: 'Down', 52: 'period'}
SOURCE_POLL_S = 5.0
SOURCE_POLL_FAST_S = 1.0    # until the first source has been seen (boot: apply the persisted offset promptly)
EV_KEY = 1
EVIOCGRAB = 0x40044590      # exclusive grab: the kernel console / a login prompt never sees the keys
KEY_MAX = 0x2ff
EVIOCGBIT_KEY = 0x80000000 | ((KEY_MAX // 8 + 1) << 16) | (ord('E') << 8) | (0x20 + EV_KEY)
FMT = 'llHHi'
SZ = struct.calcsize(FMT)

def log(msg):
    print(msg, flush=True)

def key_caps(fd):
    bits = bytearray(KEY_MAX // 8 + 1)
    try:
        fcntl.ioctl(fd, EVIOCGBIT_KEY, bits)
    except OSError:
        return None
    return bits

def has_key(bits, c):
    return bool(bits[c // 8] >> (c % 8) & 1)

def has_mapped_key(bits):
    """True if the device advertises any key we act on (so power buttons, mice etc. are skipped)."""
    return bits is not None and any(has_key(bits, c) for c in list(KEYMAP) + [KEY_RESET])

def is_full_keyboard(bits):
    """Letter keys present => someone could type a login on it => read it but do not grab it."""
    return bits is not None and all(has_key(bits, c) for c in (30, 31, 32, 33))   # KEY_A..KEY_F

ROUTES_FILE = os.path.expanduser('~/.local/state/wireplumber/default-routes')
CACHE_FILE = os.path.join(os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}'), 'gain-control.json')
PERSIST_FILE = '/var/lib/gain-control/offset.json'
TOLERANCE_DB = 0.2

def default_source():
    """-> (node_id, node_name, device_name, current_cubic) of the default audio source, or None."""
    try:
        objs = json.loads(subprocess.run(['pw-dump'], capture_output=True, text=True, timeout=5).stdout)
    except Exception as e:
        log(f'pw-dump failed: {e}'); return None
    name = None
    for o in objs:
        if o.get('type') == 'PipeWire:Interface:Metadata' and o.get('props', {}).get('metadata.name') == 'default':
            for m in o.get('metadata', []):
                if m.get('key') == 'default.audio.source':
                    name = m.get('value', {}).get('name')
    if not name:
        return None
    nodes = {o['info']['props'].get('node.name'): o for o in objs
             if o.get('type') == 'PipeWire:Interface:Node' and 'props' in o.get('info', {})}
    devs = {o['id']: o['info']['props'].get('device.name') for o in objs
            if o.get('type') == 'PipeWire:Interface:Device' and 'props' in o.get('info', {})}
    node = nodes.get(name)
    if not node:
        return None
    cubic = None
    for p in node['info'].get('params', {}).get('Props', []):
        if 'channelVolumes' in p:
            cubic = max(p['channelVolumes']) ** (1.0 / 3.0)
    return node['id'], name, devs.get(node['info']['props'].get('device.id')), cubic

def boot_default_cubic(device_name):
    """What WirePlumber restores for this device's input route at boot (cubic scale)."""
    try:
        with open(ROUTES_FILE) as f:
            for line in f:
                key, _, val = line.partition('=')
                if device_name and key.startswith(f'{device_name}:input:') and 'channelVolumes' in val:
                    lin = max(json.loads(val)['channelVolumes'])
                    return lin ** (1.0 / 3.0), 'saved route'
    except (OSError, ValueError, KeyError):
        pass
    try:
        out = subprocess.run(['wpctl', 'settings', 'device.routes.default-source-volume'],
                             capture_output=True, text=True, timeout=5).stdout
        lin = float(out.strip().split()[-1])
        return lin ** (1.0 / 3.0), 'wireplumber default'
    except Exception:
        return 1.0, 'fallback 1.0'

class Gain:
    def __init__(self):
        self.offset = 0.0
        self.base = {}          # node_name -> boot-default cubic volume
        self.current = None     # node_name of the default source last seen
        if not self.persist_ok():
            log(f'{os.path.dirname(PERSIST_FILE)} not writable — running WITHOUT persistence across reboots')
        try:                                    # per-boot cache (survives a daemon restart)
            with open(CACHE_FILE) as f:
                d = json.load(f)
            self.offset, self.base = float(d['offset']), dict(d['base'])
            log(f'restored from {CACHE_FILE}: offset {self.offset:+.0f} dB, {len(self.base)} baseline(s)')
        except (OSError, ValueError, KeyError):
            try:                                # first start this boot: persisted offset
                with open(PERSIST_FILE) as f:
                    self.offset = float(json.load(f)['offset'])
                log(f'restored persisted offset {self.offset:+.0f} dB from {PERSIST_FILE}')
            except (OSError, ValueError, KeyError):
                pass

    @staticmethod
    def persist_ok():
        d = os.path.dirname(PERSIST_FILE)
        return os.path.ismount(d) and os.access(d, os.W_OK)

    @staticmethod
    def _write(path, obj):
        tmp = path + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(obj, f)
            f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
        dfd = os.open(os.path.dirname(path), os.O_RDONLY)
        try: os.fsync(dfd)
        finally: os.close(dfd)

    def save(self):
        try:
            self._write(CACHE_FILE, {'offset': self.offset, 'base': self.base})
        except OSError as e:
            log(f'cannot write {CACHE_FILE}: {e}')
        if self.persist_ok():
            try:
                self._write(PERSIST_FILE, {'offset': self.offset})
            except OSError as e:
                log(f'cannot persist to {PERSIST_FILE}: {e}')

    def learn_base(self, name, dev):
        if name not in self.base:
            self.base[name], origin = boot_default_cubic(dev)
            log(f'baseline for {name}: cubic {self.base[name]:.4f} ({origin})')
            self.save()

    def poll_source(self):
        """Log source changes; keep the source at base * offset (control loop)."""
        src = default_source()
        name = src[1] if src else None
        if name != self.current:
            log(f'default source: {name or "NONE"}')
            self.current = name
            if name:
                self.learn_base(name, src[2])
        if name and src[3] is not None and name in self.base:
            target = self.base[name] * 10 ** (self.offset / 60.0)
            if abs(60 * math.log10(max(src[3], 1e-6) / target)) > TOLERANCE_DB:
                self.apply(f'volume was cubic {src[3]:.4f}, expected {target:.4f} — re-apply')

    def apply(self, why):
        src = default_source()
        if not src:
            log(f'{why}: no default source — nothing to do'); return
        nid, name, dev, _ = src
        self.current = name
        self.learn_base(name, dev)
        target = self.base[name] * 10 ** (self.offset / 60.0)
        r = subprocess.run(['wpctl', 'set-volume', '--limit', '1.5', str(nid), f'{target:.4f}'],
                           capture_output=True, text=True)
        if r.returncode:
            log(f'wpctl failed: {r.stderr.strip()}'); return
        log(f'{why}: offset {self.offset:+.0f} dB -> cubic {target:.4f} on {name}')

    def step(self, delta):
        new = max(CLAMP_MIN, min(CLAMP_MAX, self.offset + delta))
        if new == self.offset:
            log(f'at limit ({self.offset:+.0f} dB), ignoring {delta:+.0f}'); return
        self.offset = new
        self.save()
        self.apply(f'step {delta:+.0f}')

    def reset(self):
        self.offset = 0.0
        self.save()
        self.apply('reset')

def main():
    gain = Gain()
    fds = {}                    # fd -> path
    skipped = set()             # paths examined and rejected (re-examined if they disappear and come back)
    last_scan = last_poll = 0.0
    log('gain-control started')
    while True:
        now = time.time()
        if now - last_poll >= (SOURCE_POLL_S if gain.current else SOURCE_POLL_FAST_S):
            last_poll = now
            gain.poll_source()
        if now - last_scan >= RESCAN_S:
            last_scan = now
            present = set(glob.glob('/dev/input/event*'))
            skipped &= present          # a rejected node that vanishes gets re-examined if it returns
            for p in sorted(present - set(fds.values()) - skipped):
                try:
                    fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK)
                except OSError as e:
                    log(f'cannot open {p}: {e}'); continue
                bits = key_caps(fd)
                if not has_mapped_key(bits):
                    os.close(fd); skipped.add(p); log(f'skipping {p}: no mapped keys (power button / mouse / ...)'); continue
                fds[fd] = p
                if is_full_keyboard(bits):
                    log(f'opened {p} (full keyboard: not grabbed, console login stays possible)')
                    continue
                try:
                    fcntl.ioctl(fd, EVIOCGRAB, 1)
                    log(f'opened {p} (grabbed)')
                except OSError as e:
                    log(f'opened {p} (grab failed: {e})')
        if not fds:
            time.sleep(RESCAN_S); continue
        readable, _, _ = select.select(list(fds), [], [], RESCAN_S)
        for fd in readable:
            try:
                data = os.read(fd, SZ * 64)
            except BlockingIOError:
                continue
            except OSError as e:               # device unplugged
                log(f'closed {fds[fd]}: {e}')
                os.close(fd); del fds[fd]; continue
            for i in range(0, len(data) - SZ + 1, SZ):
                _, _, etype, code, value = struct.unpack(FMT, data[i:i + SZ])
                if etype != EV_KEY or value != 1:
                    continue
                if code in KEYMAP or code == KEY_RESET:
                    log(f'key {KEYNAMES.get(code, code)} from {fds[fd]}')
                if code in KEYMAP:
                    gain.step(KEYMAP[code])
                elif code == KEY_RESET:
                    gain.reset()

if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass
