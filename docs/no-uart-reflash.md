# In-place updates, and the RAM installer without UART

Updates between v2 releases are a plain `sysupgrade` from the installed system. The RAM
installer is for what isn't supported in place: coming from v1.x or another OpenWrt build,
and going back to v1.x. It needs no serial access either: `ubi_kernel` is a
separate MTD partition that the running system never attaches, so you can `ubiformat` the
`initramfs-factory.ubi` into it from the installed system, reboot into the RAM installer, and
run `sysupgrade` from there.

From stock firmware,
[xiaomi-openwrt-install](https://github.com/ADCDS/xiaomi-openwrt-install) does all of
this for you.

## In-place updates

```sh
sysupgrade -v /tmp/new.bin    # settings kept; -n starts from a clean configuration
```

Use this board's `...-squashfs-sysupgrade.bin`. The image, about 17 MB, sits in RAM during the
upgrade (`sysupgrade` copies one stored anywhere else into `/tmp` first), next to the running
system: a plain access point had 24-27 MB `MemAvailable` left with it in `/tmp`. On a box
running memory-hungry services (sing-box for Podkop, #46), stop them first. As with any flash,
don't cut the power or kill `sysupgrade` while it writes: an interrupted write can leave nothing
bootable, and the box then needs the stock TFTP recovery or UART.

**v2.0.0 to v2.1.2 refuse it** with `Boot the initramfs image and run sysupgrade from there.`
On those, add `-F` for that one update. `-F` turns the refusal into a warning (`Image check
failed but --force given - will update anyway!`), but it also overrides every other image
check, including the one that the image is meant for this board. So check first:

```sh
sha256sum /tmp/new.bin        # compare with the release's sha256sums.txt
sysupgrade -T /tmp/new.bin    # the refusal must be the only error
sysupgrade -F -v /tmp/new.bin
```

The releases after v2.1.2 take a plain `sysupgrade`.

### Why those releases refused it

In July 2026 a unit stopped booting after a script ran an in-place sysupgrade on it, with
`UBI init error 22` on every boot. We concluded that the stock U-Boot attaches only a kernel UBI
freshly made by `ubiformat`, and made `platform.sh` refuse any sysupgrade not started from the
RAM installer. That was never reproduced, and it was wrong:

- An RD03v2 with the stock loader upgraded in place 10 times out of 10, settings kept. Seven
  used the v2.1.2 and v2.1.1 images: three with the refusal removed, once on the unmodified
  v2.1.2 with `-F` overriding it, and three with `ubi_kernel` reformatted first. Three used a
  build with the fix: onto it with `-F`, onto itself, and back to v2.1.2
  ([VALIDATION.md](../VALIDATION.md#in-place-updates)). In every run without the reformat,
  `nand_do_upgrade` rewrote the kernel volume in place, which is what the refusal was meant to
  prevent.
- OpenWrt upgrades the AX6000 and the Redmi AX5400 in place, with the same NAND layout and the
  same upgrade code, and has no such check for them.
- The stock loader prints `UBI init error 22` whenever it tries slot 1. With
  `flag_last_success=0` and `flag_try_sys1_failed=8` (what v1.x and the AX6000 set) it starts
  `rootfs_1` first. On this layout that is the first 36 MiB of OpenWrt's 81 MiB rootfs UBI,
  which cannot attach there (its volumes reserve all 652 eraseblocks; the window holds 288), so
  it then falls back to slot 0. So on its own the message doesn't show that the kernel UBI was
  the problem. v2 sets the flags so that it starts slot 0.

Why the July unit stopped booting is not known: its logs were not kept. An interrupted write
would explain it.

## When you still need the RAM installer

- Coming from v1.x ([upgrading from v1.x](upgrading-from-v1.md)) or from another OpenWrt build
  for this board. v1.1 to v1.14 refuse an in-place sysupgrade too (v1.0 does not), other builds
  may have another board name, and an in-place update from them has not been tested.
- Going back to v1.x. An in-place flash of a v1.x image is no longer refused, but it has not
  been tested and would keep the v2 settings ([back to v1.x](upgrading-from-v1.md#back-to-v1x)).

From the RAM installer, `sysupgrade` runs `xiaomi_initramfs_prepare`, which reformats both UBI
partitions before writing. The kernel partition can be written from the installed system: it
is unattached at runtime, and `initramfs-factory.ubi` (built by `ubinize-kernel`) is a complete
UBI image for it, a single volume named `kernel`, the same layout the working system boots from.

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

   Set the boot flags that `sysupgrade` sets: `boot_wait on`, `uart_en 1`,
   `flag_boot_rootfs 0`, `flag_last_success 1`, `flag_boot_success 1`,
   `flag_try_sys1_failed 8`, `flag_try_sys2_failed 8`.
3. **Reboot.** The box comes up in the RAM installer with **default config**:
   static `192.168.1.1` and dnsmasq serving DHCP. NSS is off in the RAM installer.
   If a real gateway lives at that address, race it: pin
   `192.168.1.1 → <box MAC>` as a static ARP/neigh entry (in a network namespace
   if the driving host's own gateway is `.1.1`), SSH in (root, no password) the
   moment dropbear answers, stop dnsmasq and move the IP off `.1.1`.
4. **Flash from the RAM installer** (`rootfs_type` is now `tmpfs`): check
   memory first (below), upload the sysupgrade image and the config backup, `sysupgrade -T`, then
   `sysupgrade -f /tmp/config-backup.tar.gz /tmp/new.bin`. It reformats both
   UBIs, writes kernel and rootfs, restores the config, and reboots into the
   final system. A v1.x configuration is migrated on the first boot of v2
   ([upgrading from v1.x](upgrading-from-v1.md)).

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
