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
   ubiattach and **verify by read-back** (`dd` the `kernel` volume, compare
   md5 against the `initramfs-uImage.itb` the artifact wraps) before
   detaching. Set the boot flags the sanctioned path sets (`boot_wait on`,
   `uart_en 1`, `flag_boot_rootfs 0`, `flag_last_success 0`,
   `flag_boot_success 1`, `flag_try_sys{1,2}_failed 8`).
3. **Reboot.** The box comes up in the RAM initramfs with **default config**:
   static `192.168.1.1` + dnsmasq serving DHCP. If a real gateway lives at
   that address, race it: pin `192.168.1.1 → <box MAC>` as a static ARP/neigh
   entry (in a network namespace if the driving host's own gateway is
   `.1.1`), SSH in (root, no password) the moment dropbear answers, stop
   dnsmasq and move the IP off `.1.1`.
4. **Flash from the initramfs** (the sanctioned path — `rootfs_type` is now
   `tmpfs`): re-upload the sysupgrade image + config backup, `sysupgrade -T`,
   then `sysupgrade -f /tmp/config-backup.tar.gz /tmp/new.bin`. It reformats
   both UBIs, writes kernel+rootfs, restores the config, and reboots into the
   final system.

## Gotchas that bit (learn from them)

- **`nohup … &` over dropbear does not survive the session** — the child is
  killed before it execs. Use `start-stop-daemon -S -b -x <script>` for
  anything that must outlive the SSH connection (the ubiformat script, the
  reboot, sysupgrade itself).
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
