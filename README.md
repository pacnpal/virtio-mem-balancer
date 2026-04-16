# virtio-mem-balancer

Auto-grow and auto-shrink a KVM guest's memory by driving `virtio-mem` based on
guest-reported memory pressure (via `virtio-balloon` stats).

Plain libvirt has no built-in daemon for this. `virtio-mem`'s `requested-size`
is host-set manually. This is a ~80-line bash loop that polls
`virsh dommemstat`, computes `unused / available`, and calls
`virsh update-memory-device --requested-size` when the guest crosses a
hysteresis band.

Works with any libvirt/KVM host. Tested on Unraid (via the User Scripts plugin)
and on systemd-based distros (via a timer or a forever unit).

## Why

`virtio-balloon` alone has no guest→host "I need more RAM" signal. The host can
reclaim free pages (Free Page Reporting) but never auto-grows. `virtio-mem`
supports real memory hotplug, but you still need something on the host to flip
the `requested-size` knob in response to guest load.

This script is that something. Single host, single or few guests.
Not intended as a replacement for MOM or Proxmox's `pvestatd` in large fleets.

## Requirements

- KVM/libvirt host (any distro). Tested with libvirt 9.x and 11.x.
- Guest kernel >= 5.8 with `virtio-mem` support (Debian 12+, Ubuntu 22.04+,
  Fedora 33+, etc.).
- Guest kernel cmdline: `memhp_default_state=online_kernel` so hotplugged
  memory is onlined automatically.
- `virtio-balloon` device in the guest for stats (most libvirt setups include
  this by default).
- `bash`, `awk`, `flock`, `virsh`.

## VM XML

Three changes, via `virsh edit <domain>` (or Unraid UI → VM → XML View):

```xml
<maxMemory slots='16' unit='KiB'>8388608</maxMemory>     <!-- 8 GiB ceiling -->
<memory unit='KiB'>2097152</memory>                       <!-- 2 GiB floor -->
<currentMemory unit='KiB'>2097152</currentMemory>
```

Inside `<cpu ...>`, add a NUMA cell matching the floor (required by virtio-mem):

```xml
<cpu mode='host-passthrough' check='none' migratable='on'>
  <numa>
    <cell id='0' cpus='0-3' memory='2097152' unit='KiB'/>
  </numa>
</cpu>
```

Inside `<devices>`, add the virtio-mem device:

```xml
<memory model='virtio-mem'>
  <target>
    <size unit='KiB'>6291456</size>    <!-- pluggable region: ceiling - floor -->
    <node>0</node>
    <block unit='KiB'>2048</block>     <!-- 2 MiB blocks (x86_64) -->
    <requested unit='KiB'>0</requested>
  </target>
</memory>
```

Reboot the guest for the new layout to take effect.

## Guest cmdline

Edit `/etc/default/grub` in the guest and append
`memhp_default_state=online_kernel` to `GRUB_CMDLINE_LINUX_DEFAULT`, then
`update-grub` and reboot.

## Install (generic libvirt host)

```bash
sudo install -m 0755 balancer.sh /usr/local/sbin/virtio-mem-balancer
sudo mkdir -p /etc/virtio-mem-balancer
sudo cp balancer.conf.example /etc/virtio-mem-balancer/my-guest.conf
sudo $EDITOR /etc/virtio-mem-balancer/my-guest.conf   # set DOMAIN + tunables
```

Minimal systemd unit (`/etc/systemd/system/virtio-mem-balancer@.service`):

```ini
[Unit]
Description=virtio-mem balancer for %i
After=libvirtd.service

[Service]
Type=simple
Environment=DOMAIN=%i
ExecStart=/usr/local/sbin/virtio-mem-balancer
Restart=on-failure
RestartSec=5s
TimeoutStopSec=20s
KillMode=mixed

[Install]
WantedBy=multi-user.target
```

Then:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now virtio-mem-balancer@my-guest.service
journalctl -fu virtio-mem-balancer@my-guest.service
```

## Install (Unraid)

Prerequisite: the [User Scripts](https://forums.unraid.net/topic/48286-plugin-ca-user-scripts/) plugin (install from Community Applications).

On the Unraid host:

```bash
cd /boot && git clone https://github.com/pacnpal/virtio-mem-balancer.git
cd virtio-mem-balancer
# /boot is FAT32 — can't store +x, so invoke via bash explicitly:
bash ./unraid/install.sh my-guest    # replace with your VM's libvirt domain name
```

The installer creates a dedicated User Scripts entry at
`/boot/config/plugins/user.scripts/scripts/virtio-mem-balancer-my-guest/`
containing:
- `balancer.sh` — copy of the upstream script
- `balancer.conf` — per-domain tunables (edit here, not in the script)
- `script` — the User Scripts entry point, which points at the two above
- `name`, `description` — shown in the User Scripts UI

The installer also:
- Registers the script in `schedule.json` with frequency `boot` (UI label:
  **"At First Array Start Only"**), so no clicking through the UI.
- Launches the daemon immediately via Unraid's native
  `/usr/local/emhttp/plugins/user.scripts/backgroundScript.sh`, the same
  path the web UI's **"Run Script"** button takes. Skip with
  `START_NOW=0 bash ./unraid/install.sh my-guest`.

Log tails to `/tmp/user.scripts/tmpScripts/virtio-mem-balancer-my-guest/log.txt`
(tmpfs — wiped on Unraid reboot).

For multiple guests, run the installer once per domain; each gets its own
User Scripts entry and lockfile.

**Updating later:** `cd /boot/virtio-mem-balancer && git pull && bash ./unraid/install.sh my-guest`
refreshes `balancer.sh` without touching your `balancer.conf`.

## Config

| Var | Default | Meaning |
|---|---|---|
| `DOMAIN` | *required* | libvirt domain name |
| `MAX_KIB` | 6291456 | Pluggable ceiling (KiB). Must be ≤ the virtio-mem `<size>`. |
| `STEP_KIB` | 524288 | Grow/shrink chunk per tick (KiB). |
| `LOW_PCT` | 15 | Grow when guest `unused/available` < this percent. |
| `HIGH_PCT` | 40 | Shrink when guest `unused/available` > this percent. |
| `INTERVAL` | 15 | Seconds between ticks. |
| `NODE` | 0 | NUMA node of the virtio-mem device. |

Precedence: env var > `/etc/virtio-mem-balancer/<domain>.conf` >
`$CONFIG` file > defaults.

### Tuning

- **Slow reaction, big spikes** → lower `INTERVAL` (5s), raise `STEP_KIB` (1 GiB+).
- **Flapping near the threshold** → widen the hysteresis band (lower `LOW_PCT`,
  raise `HIGH_PCT`).
- **Grows but never shrinks** → the guest is keeping pages dirty; this is
  correct behavior, not a bug. Free Page Reporting on the `virtio-balloon`
  device helps here.

## Operation

Manual smoke test (on the host):

```bash
virsh update-memory-device <domain> --node 0 --requested-size 1048576KiB --live
# in the guest: free -h  should show +1 GiB
virsh update-memory-device <domain> --node 0 --requested-size 0KiB --live
```

Stress test (in the guest, with `stress-ng` installed):

```bash
stress-ng --vm 2 --vm-bytes 2G --vm-keep --timeout 45s
```

### Example log output

```
13:23:41 my-guest: starting (req=0KiB step=524288KiB max=6291456KiB interval=15s low=15% high=40%)
13:23:56 my-guest no stats (avail= unused=)
13:24:26 my-guest unused=7% req 0KiB -> 524288KiB
13:24:41 my-guest unused=4% req 524288KiB -> 1048576KiB
13:25:26 my-guest unused=48% req 1048576KiB -> 524288KiB
13:25:41 my-guest unused=61% req 524288KiB -> 0KiB
```

(In-band ticks don't log. Only grows, shrinks, and errors appear.)

## Troubleshooting

**`error: Options --node and --alias are mutually exclusive`** — older libvirt
parsers; the script uses `--node` only. If you see this anyway, confirm the
running copy has no leftover `--alias` flags (pkill stale copies).

**Log shows `no stats`** — `virsh dommemstat` isn't returning `available` /
`unused`. Fix: ensure the VM XML has `<memballoon model='virtio'/>` and run
`virsh dommemstat <domain> --period 2 --live` once.

**Grew but guest didn't actually get the memory** — `memhp_default_state`
isn't set in the guest cmdline, or the guest kernel is too old. Verify with
`cat /proc/cmdline` and `dmesg | grep virtio_mem`.

**Crosses max but demand still exceeds ceiling** — raise `<maxMemory>` and
virtio-mem `<size>` in the VM XML, bump `MAX_KIB`, reboot the guest.

## License

MIT. See `LICENSE`.

## See also

- [libvirt virtio-mem user guide](https://virtio-mem.gitlab.io/user-guide/user-guide-libvirt.html)
- [virtio-mem Linux guest guide](https://virtio-mem.gitlab.io/user-guide/user-guide-linux.html)
- [oVirt MOM](https://github.com/oVirt/mom) — larger-scale alternative
- [SapphicCode/balloond](https://github.com/SapphicCode/balloond),
  [nefelim4ag/libvirt-autoballoon](https://github.com/nefelim4ag/libvirt-autoballoon)
  — prior art using virtio-balloon instead of virtio-mem
