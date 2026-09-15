# Reflashing without UART (remote initramfs pivot)

> TL;DR — the "flash only from a RAM-booted initramfs" rule does **not**
> require serial access. `ubi_kernel` is a separate MTD partition that the
> running system never attaches, so you can `ubiformat` the
> `initramfs-factory.ubi` into it from the installed system, reboot into the
> RAM initramfs, and run the sanctioned `sysupgrade` from there. Serial stays
> the recovery net, not the entry ticket.

## Why in-place sysupgrade is still forbidden

The stock locked U-Boot only attaches a kernel/rootfs UBI produced by a clean
`ubiformat`, and `xiaomi_initramfs_prepare` can only reformat the rootfs UBI
when not running from it (see `platform_check_image`). That constraint is
about the **rootfs** partition. The **kernel** partition has no such problem:
it is unattached at runtime, and `initramfs-factory.ubi` (built by
`ubinize-kernel`) is a complete pre-built UBI image for it — single volume
named `kernel`, same layout the working system boots from.

## Procedure (all over SSH)

1. **Back up** on the running system: `sysupgrade -b /tmp/config-backup.tar.gz`
   (copy it off-box — /tmp does not survive the reboot). Optionally dump the
   current kernel volume as a rollback artifact:
   `ubiattach -m <ubi_kernel mtdnum>; dd if=/dev/ubiX_0 of=old-kernel.bin; ubidetach`.
2. **Write the initramfs**:
   `ubiformat /dev/mtd<ubi_kernel> -f initramfs-factory.ubi -y`, then
   ubiattach and **verify by read-back** before detaching — comparing the
   right bytes. The artifact's single volume is **dynamic**, so it records no
   used length and reads back whole LEBs: the FIT image followed by `0xff`
   erase padding. An md5 of the *entire* volume against the
   `initramfs-uImage.itb` the artifact wraps can therefore never match,
   however perfect the write was. The `.itb` is a byte-exact **prefix** of the
   volume — check that:

   ```sh
   # kernel volume attached as /dev/ubiX_0
   head -c "$(stat -c %s initramfs-uImage.itb)" /dev/ubiX_0 | md5sum
   tail -c +"$(( $(stat -c %s initramfs-uImage.itb) + 1 ))" /dev/ubiX_0 \
     | tr -d '\377' | wc -c
   ```

   The first must equal `md5sum initramfs-uImage.itb`; the second must print
   `0` — nothing but erase padding past the image. Use `head -c`, not
   `dd bs=1`, which crawls through 14 MB a byte at a time. On v1.6 the `.itb`
   is 13,904,532 bytes and the volume reads back 13,967,360 = 110 LEBs ×
   126,976, so the trailing 62,828 bytes are `0xff`: that size difference is
   expected, not a bad flash.

   Set the boot flags the sanctioned path sets (`boot_wait on`, `uart_en 1`,
   `flag_boot_rootfs 0`, `flag_last_success 0`, `flag_boot_success 1`,
   `flag_try_sys{1,2}_failed 8`).
3. **Reboot.** The box comes up in the RAM initramfs with **default config**:
   static `192.168.1.1` + dnsmasq serving DHCP. If a real gateway lives at
   that address, race it: pin `192.168.1.1 → <box MAC>` as a static ARP/neigh
   entry (in a network namespace if the driving host's own gateway is
   `.1.1`), SSH in (root, no password) the moment dropbear answers, stop
   dnsmasq and move the IP off `.1.1`.
4. **Flash from the initramfs** (the sanctioned path — `rootfs_type` is now
   `tmpfs`): free memory first (see the RAM gotcha below), re-upload the
   sysupgrade image + config backup, `sysupgrade -T`,
   then `sysupgrade -f /tmp/config-backup.tar.gz /tmp/new.bin`. It reformats
   both UBIs, writes kernel+rootfs, restores the config, and reboots into the
   final system.

## Gotchas that bit (learn from them)

- **A plain `cmd &` over dropbear does not reliably survive the session** —
  the child can die with the session before it gets going, and the image's
  BusyBox has no `nohup` to fall back on. `setsid` is the replacement: detach
  anything that must outlive the SSH connection (the ubiformat script, the
  reboot, sysupgrade itself) into its own session with every stdio stream
  closed:

  ```sh
  setsid sh -c '/tmp/do-flash.sh' >/dev/null 2>&1 </dev/null &
  ```

  `start-stop-daemon -S -b -x <script>` usually works too, with the caveat
  below. But on 2026-09-14 it returned with a freshly written, uniquely named
  reboot script and the box never rebooted, while `setsid` worked every time
  that day. Use `setsid`, and confirm the effect (uptime, `/tmp/pivot.log`)
  rather than trusting the exit status.
- **Pass `start-stop-daemon -x` a script path, never the interpreter.** This
  BusyBox (1.38, without the "fancy" option) treats a process as already
  running when `readlink /proc/PID/exe` or its argv[0] equals the `-x` path.
  Every running `#!/bin/sh` script — `rd03v2-watchdog`, `nsswifi-guard` on a
  bench box, any other long-running shell script — has argv[0] `/bin/sh`, so
  `start-stop-daemon -S -b -x /bin/sh -- -c "sleep 2; reboot"` prints
  `/bin/sh is already running` and starts nothing; the reboot you are waiting
  for never comes. Your SSH shell is not the culprit (dropbear starts it as
  `ash`/`-ash`, which never matches), so the same command may work on a box
  where no such script happens to be running and fail on the next one. Always
  put the command in a uniquely named script such as `/tmp/do-reboot.sh`,
  `chmod +x` it, and pass that path to `-x`.
- **The RAM installer is short on memory.** The NSS initramfs came up with only
  ~10 MB `MemAvailable` (its rootfs is ~32 MB of shmem, `min_free_kbytes` is
  16 MB) — not enough to receive a ~15 MB sysupgrade image. Before uploading:

  ```sh
  for s in rd03v2-watchdog odhcpd sysntpd uhttpd; do /etc/init.d/$s stop; done
  sync; echo 3 > /proc/sys/vm/drop_caches
  echo 4096 > /proc/sys/vm/min_free_kbytes   # installer only, it reboots anyway
  grep MemAvailable /proc/meminfo            # ~30 MB; do not upload below that
  ```

  Stream the upload and compare checksums before `sysupgrade -T`:
  `cat new.bin | ssh root@192.168.1.1 "cat > /tmp/new.bin"`, then
  `sha256sum` on both ends.
- **BusyBox `ip addr add` can fail silently** — always `&&`-chain and print
  `ip addr show` in the same session to confirm. If the box ends up with no
  IPv4 at all, it is still reachable over its IPv6 link-local
  (`ssh root@fe80::…%<iface>`) — dropbear listens on `::`.
- The initramfs kernel banner shows the **reproducible-build timestamp**
  (SOURCE_DATE_EPOCH), not the actual build time — do not use `uname -v` to
  judge which build is running; verify the kernel volume md5 before reboot
  instead.
- Only the flash writes themselves are risk windows (a torn `ubiformat` of
  `ubi_kernel`, or power loss during step 4 after the prepare wipes both
  UBIs). Both leave the box UART-recoverable per `docs/`/README — same worst
  case as any flash, so run the writes detached and leave the power alone.

## Over the air (the `-wifi` installer)

The whole procedure also works with no cable at all: pivot into the `-wifi`
initramfs and do step 4 over its `OpenWrt-RD03v2-Installer` network. Extra
rules for that:

- **Do not take `lan` down on a box you reach only over its Wi-Fi.** The AP
  VAPs are members of `br-lan`. On the cable-less bench box, `ifdown lan` took
  them down with the bridge, nothing brought them back, and the box stayed
  unreachable until a power cycle. (`/etc/init.d/network restart` was not
  tested that way; treat it, and anything else that drops `br-lan`, as the
  same risk.) If you must, arm a detached, timed rollback first, so the
  interface comes back even after your session dies:

  ```sh
  setsid sh -c 'sleep 60; ifup lan' >/dev/null 2>&1 </dev/null &
  ```
- **Default → NSS: pivot through the NSS installer.** When the running system
  is the default (non-NSS) build and the target is an `-nss` build, write
  `…-initramfs-factory-nss-wifi.ubi`, not the default `-wifi` one. Otherwise
  the last warm handover before the final boot is non-NSS → NSS, the chain
  that can wedge the NSS core and the switch (next section). Check the
  installer's NSS core before `sysupgrade`:

  ```sh
  grep rx_buffers_status_sync /sys/kernel/debug/qca-nss-drv/stats/drv  # run twice, must keep increasing
  dmesg | grep -i timeout                                             # no nss_* timeout errors
  ```

  If the counter does not rise or `nss_*` timeouts show up, do **not** run
  `sysupgrade` from that installer. Cold power-cycle the box (unplug it for
  ~10 s): `ubi_kernel` still holds the installer, so it boots straight back
  into it, this time from a hardware reset. `/tmp` is gone, so free memory and
  re-upload the image (see the RAM gotcha above), then repeat the check before
  flashing.
- **Several boxes on `192.168.1.1`.** Every installer has the same SSID and
  address. Pin the client to the right box's BSSID (NetworkManager:
  `nmcli con modify <con> 802-11-wireless.bssid <box AP MAC>`). If the Linux
  client has another NIC in `192.168.1.0/24`, bind the socket to the Wi-Fi
  device — `ssh -o BindInterface=` alone does not override routing:

  ```sh
  ssh -o 'ProxyCommand=socat - TCP:192.168.1.1:22,so-bindtodevice=<wlan-if>' root@192.168.1.1
  ```

## Dead switch after the pivot? Cold power-cycle before assuming a bad flash

This whole procedure is a chain of **warm** reboots, and the AN8855 switch and
the UBI32 NSS core do not always come out of one cleanly. The symptom is
alarming and looks exactly like a bricked flash:

- the box **boots fine** — it mounts the real NAND rootfs and comes up with its
  installed config,
- **WiFi works** and beacons at full signal (so you can see it is alive),
- but **every switch port is dead**: no ping over any LAN port, ARP stays
  `INCOMPLETE`, and the upstream router's bridge FDB shows **no** entry for the
  box at all — it is silent at L2. PHY carrier may still read `1`, which makes
  it look like a link-layer problem that it is not.

That is the same failure mode `build.sh` warns about for a mismatched NSS
firmware ("the NSS core boots successfully yet never answers phys_if messages …
ALL switch ports (LAN and WAN) come up dead"), and it is reachable purely from
the warm-reboot chain — no firmware mismatch required. Pivoting
NSS kernel → non-NSS RAM initramfs → back to the NSS kernel is enough to
trigger it, because the non-NSS kernel leaves those cores in a state the next
kernel's soft reset does not recover.

**Unplug the box for ~10 s and plug it back in.** A cold boot re-runs the
hardware reset and everything comes back. Confirm with
`dmesg | grep -o 'HWTRAP [0-9a-f]*'` — a real value (e.g. `00101070`) means the
switch reset cleanly; `ffffffff` means it did not.

Do **not** reach for UART on this symptom until you have power-cycled: the flash
is fine, the rootfs is fine, and a reflash would fix nothing. If you have just
restored a kernel volume and verified its md5 read-back, a dead switch is far
more likely to be this than a bad write.
