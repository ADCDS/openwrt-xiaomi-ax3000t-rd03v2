#!/bin/sh
# Phase 6 - boot flags and the boot_wait reset (Q6).  READ ONLY.
# nvram/bdata are only ever *read* here; no set, no commit.
# Run: ./rsh < phase6.sh > ../raw/phase6-nvram.txt
sec() { echo; echo "===== $* ====="; }

sec nvram-show
nvram show 2>/dev/null

sec bdata-usage
bdata 2>&1 | head -20

sec bdata-show
bdata show 2>/dev/null
bdata list 2>/dev/null

sec bdata-individual
for f in uart_en ssh_en telnet_en boot_wait restore_defaults SN CountryCode; do
  echo "bdata $f = $(bdata get $f 2>&1)"
done

sec key-nvram
for f in restore_defaults boot_wait uart_en ssh_en telnet_en flag_boot_success \
         flag_boot_rootfs flag_last_success flag_ota_reboot flag_boot_recovery \
         flag_try_sys1_failed flag_try_sys2_failed; do
  echo "$f = $(nvram get $f 2>/dev/null)"
done

sec proc-xiaoqiang
ls -la /proc/xiaoqiang/ 2>/dev/null
for f in /proc/xiaoqiang/*; do [ -f "$f" ] && echo "## $f = $(cat $f 2>/dev/null)"; done

sec restore-defaults-references
grep -rl -E "restore_defaults|flag_boot_success|flag_try_sys" \
  /etc/init.d /etc/config /lib/preinit /lib/upgrade /sbin /usr/sbin 2>/dev/null

sec preinit-31_restore_nvram
cat /lib/preinit/31_restore_nvram 2>/dev/null

sec xiaoqiang-defaults
cat /usr/share/xiaoqiang/xiaoqiang-defaults.txt 2>/dev/null

sec boot_check-init
cat /etc/init.d/boot_check 2>/dev/null

sec logread
logread 2>/dev/null | tail -200 || /sbin/logread 2>/dev/null | tail -200 || cat /var/log/messages 2>/dev/null | tail -200

sec auto_upgrade-config
cat /etc/config/vas 2>/dev/null | head -60
