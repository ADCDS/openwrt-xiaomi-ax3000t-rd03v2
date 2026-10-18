# Reflashing without UART (remote initramfs pivot)

> TL;DR: the "flash only from a RAM-booted initramfs" rule does **not** require
> serial access. `ubi_kernel` is a separate MTD partition that the running
> system never attaches, so you can `ubiformat` the `initramfs-factory.ubi` into
> it from the installed system, reboot into the RAM installer, and run the
> sanctioned `sysupgrade` from there. Serial stays the recovery net, not the
> entry ticket.

From stock firmware,
[xiaomi-openwrt-install](https://github.com/ADCDS/xiaomi-openwrt-install) does all of
this for you. This page is the manual route from an installed OpenWrt (v2, v1.x or
another build).

## Why in-place sysupgrade is refused

The stock locked U-Boot only attaches a kernel/rootfs UBI produced by a clean
`ubiformat`, and `xiaomi_initramfs_prepare` can only reformat the rootfs UBI
when not running from it, so `platform_check_image` refuses a sysupgrade unless
the root filesystem is the RAM installer's (`tmpfs`). That constraint is about the
**rootfs** partition. The **kernel** partition has no such problem: it is
unattached at runtime, and `initramfs-factory.ubi` (built by `ubinize-kernel`) is
a complete pre-built UBI image for it, a single volume named `kernel`, the same
layout the working system boots from.

## Procedure (all over SSH)

1. **Back up** on the running system: `sysupgrade -b /tmp/config-backup.tar.gz`
   (copy it off-box: /tmp does not survive the reboot). Optionally dump the
   current kernel volume as a rollback artifact:
   `ubiattach -m <ubi_kernel mtdnum>; dd if=/dev/ubiX_0 of=old-kernel.bin; ubidetach`.
2. **Write the RAM installer**:
   `ubiformat /dev/mtd<ubi_kernel> -f initramfs-factory.ubi -y`, then
   ubiattach and **verify by read-back** before detaching, comparing the
   right bytes. The artifact's single volume is **dynamic**, so it records no
   used length and reads back whole LEBs: the FIT image followed by `0xff`
   erase padding. An md5 of the *entire* volume against the
   `initramfs-uImage.itb` the artifact wraps can therefore never match,
   however perfect the write was. The `.itb` is a byte-exact **prefix** of the
   volume; check that:

   ```sh
   # kernel volume attached as /dev/ubiX_0
   head -c "$(stat -c %s initramfs-uImage.itb)" /dev/ubiX_0 | md5sum
   tail -c +"$(( $(stat -c %s initramfs-uImage.itb) + 1 ))" /dev/ubiX_0 \
     | tr -d '\377' | wc -c
   ```

   The first must equal `md5sum initramfs-uImage.itb`; the second must print
   `0`: nothing but erase padding past the image. Use `head -c`, not
   `dd bs=1`, which crawls through 16 MB a byte at a time. The volume is always
   a little longer than the `.itb` (a whole number of 126,976-byte LEBs); that
   difference is expected, not a bad flash.

   Set the boot flags the sanctioned path sets: `boot_wait on`, `uart_en 1`,
   `flag_boot_rootfs 0`, `flag_last_success 1`, `flag_boot_success 1`,
   `flag_try_sys1_failed 8`, `flag_try_sys2_failed 8`.
3. **Reboot.** The box comes up in the RAM installer with **default config**:
   static `192.168.1.1` and dnsmasq serving DHCP. NSS is off in the RAM installer.
   If a real gateway lives at that address, race it: pin
   `192.168.1.1 → <box MAC>` as a static ARP/neigh entry (in a network namespace
   if the driving host's own gateway is `.1.1`), SSH in (root, no password) the
   moment dropbear answers, stop dnsmasq and move the IP off `.1.1`.
4. **Flash from the RAM installer** (the sanctioned path: `rootfs_type` is now
   `tmpfs`): check memory first (below), upload the sysupgrade image and the
   config backup, `sysupgrade -T`, then
   `sysupgrade -f /tmp/config-backup.tar.gz /tmp/new.bin`. It reformats both
   UBIs, writes kernel and rootfs, restores the config, and reboots into the
   final system. A v1.x configuration is migrated on the first boot of v2
   ([upgrading from v1.x](../README.md#upgrading-from-v1x)).

## Gotchas

- **A plain `cmd &` over dropbear does not reliably survive the session**:
  the child can die with the session before it gets going, and the image's
  BusyBox has no `nohup` to fall back on. `setsid` is the replacement: detach
  anything that must outlive the SSH connection (the ubiformat script, the
  reboot, sysupgrade itself) into its own session with every stdio stream
  closed:

  ```sh
  setsid sh -c '/tmp/do-flash.sh' >/dev/null 2>&1 </dev/null &
  ```

  `start-stop-daemon -S -b -x <script>` usually works too, with the caveat
  below, but it has been seen to return without the script ever running. Use
  `setsid`, and confirm the effect (uptime, a log file) rather than trusting the
  exit status.
- **Pass `start-stop-daemon -x` a script path, never the interpreter.** This
  BusyBox (without the "fancy" option) treats a process as already running when
  `readlink /proc/PID/exe` or its argv[0] equals the `-x` path. Every running
  `#!/bin/sh` script, such as `rd03v2-watchdog`, has argv[0] `/bin/sh`, so
  `start-stop-daemon -S -b -x /bin/sh -- -c "sleep 2; reboot"` prints
  `/bin/sh is already running` and starts nothing; the reboot you are waiting
  for never comes. Your SSH shell is not the culprit (dropbear starts it as
  `ash`/`-ash`, which never matches), so the same command may work on a box
  where no such script happens to be running and fail on the next one. Always
  put the command in a uniquely named script such as `/tmp/do-reboot.sh`,
  `chmod +x` it, and pass that path to `-x`.
- **Check memory before uploading.** The RAM installer's root filesystem lives
  in RAM, and the sysupgrade image (about 17 MB) has to fit next to it. Check
  `grep MemAvailable /proc/meminfo`; if it is under about 30 MB, free some first:

  ```sh
  for s in rd03v2-watchdog odhcpd sysntpd uhttpd; do /etc/init.d/$s stop; done
  sync; echo 3 > /proc/sys/vm/drop_caches
  ```

  Stream the upload and compare checksums before `sysupgrade -T`:
  `cat new.bin | ssh root@192.168.1.1 "cat > /tmp/new.bin"`, then
  `sha256sum` on both ends.
- **BusyBox `ip addr add` can fail silently**: always `&&`-chain and print
  `ip addr show` in the same session to confirm. If the box ends up with no
  IPv4 at all, it is still reachable over its IPv6 link-local
  (`ssh root@fe80::…%<iface>`): dropbear listens on `::`.
- The kernel banner shows the **reproducible-build timestamp**
  (SOURCE_DATE_EPOCH), not the actual build time: do not use `uname -v` to
  judge which build is running; verify the kernel volume md5 before reboot
  instead.
- Only the flash writes themselves are risk windows (a torn `ubiformat` of
  `ubi_kernel`, or power loss during step 4 after the prepare wipes both
  UBIs). Both leave the box recoverable over UART, as with any flash (the
  [UART guide](https://github.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2/blob/v1.14/docs/installation-and-usage.md#uart-installation-guide)
  is in the v1.x documentation), so run the writes detached and leave the power alone.
- **Every switch port dead after a pivot, while Wi-Fi works?** Unplug the box
  for about 10 s before assuming a bad flash. A cold boot re-runs the switch's
  hardware reset; a chain of warm reboots does not always.

## Over the air (the `-wifi` installer)

The whole procedure also works with no cable at all: write the `-wifi` installer
(`…-initramfs-factory-wifi.ubi`) in step 2 and do step 4 over its
`OpenWrt-RD03v2-Installer` network (WPA2, key `rd03v2install`; fixed and public,
and the network exists only while the RAM installer runs). Extra rules for that:

- **Do not take `lan` down on a box you reach only over its Wi-Fi.** The AP
  interfaces are members of `br-lan`: `ifdown lan` takes them down with the
  bridge, nothing brings them back, and the box stays unreachable until a power
  cycle. Treat `/etc/init.d/network restart`, and anything else that drops
  `br-lan`, as the same risk. If you must, arm a detached, timed rollback first,
  so the interface comes back even after your session dies:

  ```sh
  setsid sh -c 'sleep 60; ifup lan' >/dev/null 2>&1 </dev/null &
  ```
- **Several boxes on `192.168.1.1`.** Every installer has the same SSID and
  address. Pin the client to the right box's BSSID (NetworkManager:
  `nmcli con modify <con> 802-11-wireless.bssid <box AP MAC>`). If the Linux
  client has another NIC in `192.168.1.0/24`, bind the socket to the Wi-Fi
  device; `ssh -o BindInterface=` alone does not override routing:

  ```sh
  ssh -o 'ProxyCommand=socat - TCP:192.168.1.1:22,so-bindtodevice=<wlan-if>' root@192.168.1.1
  ```
