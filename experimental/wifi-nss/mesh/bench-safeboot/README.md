# Bench safe-boot profile (issue #21 mesh experiment)

A `PROFILE=` overlay for **bench images only**. It keeps the new mesh code
from autoloading, so an image that crashes in it can't reboot-loop a board
that has no UART. On this board `panic_on_oops=1` and `kernel.panic=3` turn any
fault into a reboot. The Xiaomi bootloader counts failed boots, and only
`rc.local` (late in boot) resets that count. A crash during module autoload
would therefore loop before `rc.local` ever ran, until U-Boot stopped with
"Boot failure detected on both systems".

Build with it:

```sh
NSS=1 WIFI_NSS_DONOR="$(realpath ../wifi-nss-donor)" KMODS=0 \
  PROFILE="$PWD/experimental/wifi-nss/mesh/bench-safeboot" bash build.sh
```

## What boots

- `/etc/modules.conf` blacklists `ath11k_ahb`, `ath11k` and
  `qca-nss-wifi-meshmgr`. The NSS core, ECM and PPPoE load exactly as in
  v1.10, so safe mode is the proven wired NSS path with no Wi-Fi. The only new
  code on that path is the NSS driver's mesh support, whose init just creates
  two debugfs directories.
- `/etc/rd03v2-watchdog.disable` keeps the watchdog from acting on experiments.

**Blacklist every module with its own autoload entry, not just the bottom of
the chain.** ubox kmodloader honours a blacklist only for a module's own
top-level entry. When it autoloads a module, `load_moddeps()` marks every
dependency that isn't LOADED as PROBE, overwriting BLACKLISTED. The first
image of this kit blacklisted only the mesh manager, and on the bench (2026-09-26)
ath11k loaded and pulled it straight in. For the same reason, blacklisting
`qca-nss-drv` would not stop NSS: ECM and ath11k would load it.

Why not blacklist the NSS driver itself: safe mode would then be wired `nss-dp`
without `qca-nss-drv`, which has never been run on this board. OpenWrt failsafe
depends on that same state, and it wasn't drilled. For a future 11.4 image,
where the NSS core itself is the risk, revisit this.

## Loading the Wi-Fi half

- **By hand, after boot:** `wifi-load --deadman 300`, then `touch /tmp/wifi-load.ok`
  once the box is healthy. Otherwise the dead-man reboots it back into safe
  mode. It runs `wifi up` itself. The value must be a positive number of
  seconds, or it refuses to load anything. A second run replaces the first
  run's dead-man instead of leaving it to fire on its old deadline.
- **For one boot:** `fw_setenv rd03v2_wifi_arm 1`, then reboot.
  `/etc/init.d/wifi-oneshot` (S11, where autoload would run) disarms and then
  loads, with a 300 s dead-man. A crash lands the next boot in safe mode. If the
  flag does not read back as cleared, it loads nothing.

Steps are logged to `/tmp/wifi-load.log` and syslog (`wifi-load`,
`wifi-oneshot`).

## Leaving safe mode

Delete the `blacklist` line from `/etc/modules.conf` on the NAND overlay and
reboot. Or flash an image built without this profile.

## Trap: the blacklist name

It must be the `.ko` file name exactly: `qca-nss-wifi-meshmgr` with dashes,
`ath11k_ahb` with an underscore. ubox kmodloader keeps blacklist entries in a
plain `strcmp` list, keyed by the `.ko` basename. Any other spelling never
matches, and the module quietly autoloads anyway.

## Status

The first image built with this kit shipped the meshmgr-only blacklist and did
**not** hold anything back (see above). The files here are the fix. Two later
builds booted with them on the bench (2026-09-27): ath11k, ath11k_ahb and the
mesh manager stayed out, NSS, ECM and PPPoE loaded, and `wifi-load --deadman
300` loaded the Wi-Fi half and brought both radios up. The one-boot path
(`rd03v2_wifi_arm` + `wifi-oneshot`) has not been exercised.
