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
PartOf=libvirtd.service

[Service]
Type=simple
Environment=DOMAIN=%i
ExecStart=/usr/local/sbin/virtio-mem-balancer
Restart=on-failure
RestartSec=5s

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

Unraid's root filesystem is tmpfs, so the script must live on `/boot` and be
launched at array start via the User Scripts plugin.

```bash
# On the Unraid host:
mkdir -p /boot/config/plugins/user.scripts/scripts/virtio-mem-balancer
cp balancer.sh /boot/config/plugins/user.scripts/scripts/virtio-mem-balancer/script
chmod +x /boot/config/plugins/user.scripts/scripts/virtio-mem-balancer/script
echo "virtio-mem balancer" > /boot/config/plugins/user.scripts/scripts/virtio-mem-balancer/name
```

Edit the script to set `DOMAIN` at the top (since `/etc` isn't persistent,
sourcing a config file on boot is harder — easiest to bake values in). Then
in Unraid UI: **Settings → User Scripts → virtio-mem balancer → "At First
Array Start Only"**.

Log tails to `/tmp/user.scripts/tmpScripts/virtio-mem-balancer/log.txt`.

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
virsh update-memory-device <domain> --node 0 --requested-size 1G --live
# in the guest: free -h  should show +1 GiB
virsh update-memory-device <domain> --node 0 --requested-size 0  --live
```

Stress test (in the guest, with `stress-ng` installed):

```bash
stress-ng --vm 2 --vm-bytes 2G --vm-keep --timeout 45s
```

Watch the balancer log — you should see `unused=N% req XKiB -> YKiB` grow
lines within 1–2 ticks, then shrink lines ~20s after stress ends.

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
