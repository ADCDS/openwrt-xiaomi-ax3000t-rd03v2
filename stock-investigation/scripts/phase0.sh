#!/bin/sh
# Phase 0 - identity and boot flags.  READ ONLY.
# Run: ./rsh < phase0.sh > ../raw/phase0-identity.txt
sec() { echo; echo "===== $* ====="; }

sec date
date; echo "uptime: $(cat /proc/uptime)"

sec xiaoqiang_version
cat /usr/share/xiaoqiang/xiaoqiang_version 2>/dev/null

sec uname
uname -a; echo "machine=$(uname -m)"

sec /proc/version
cat /proc/version

sec /proc/cmdline
cat /proc/cmdline

sec /proc/cpuinfo
cat /proc/cpuinfo

sec uptime-loadavg
uptime; cat /proc/loadavg

sec /proc/mtd
cat /proc/mtd

sec ubinfo-a
ubinfo -a 2>/dev/null

sec nvram-flash_type
nvram get flash_type 2>/dev/null

sec lsmod
lsmod

sec devicetree-root
ls /sys/firmware/devicetree/base/

sec dt-model-compatible
echo "model: $(tr -d '\0' < /sys/firmware/devicetree/base/model 2>/dev/null)"
echo "compatible: $(tr '\0' ' ' < /sys/firmware/devicetree/base/compatible 2>/dev/null)"

sec bootinfo
bootinfo 2>/dev/null

sec boot-flags
for f in flag_boot_rootfs flag_last_success flag_try_sys1_failed flag_try_sys2_failed \
         flag_boot_success flag_ota_reboot flag_boot_recovery uart_en boot_wait \
         restore_defaults ssh_en telnet_en; do
  echo "$f=$(nvram get $f 2>/dev/null)"
done

sec bdata-flags
for f in uart_en ssh_en telnet_en boot_wait; do
  echo "bdata $f=$(bdata get $f 2>/dev/null)"
done

sec proc-xiaoqiang
ls /proc/xiaoqiang/ 2>/dev/null
for f in /proc/xiaoqiang/*; do [ -f "$f" ] && echo "-- $f: $(cat $f 2>/dev/null)"; done

sec partitions
cat /proc/partitions 2>/dev/null

sec mounts
mount

sec df
df -h

sec os-release-etc
cat /etc/openwrt_release 2>/dev/null; cat /etc/os-release 2>/dev/null
