#!/bin/sh
# Phase 7a - crash/restart policy, READ ONLY.  No crash is triggered here.
# The disruptive parts of phase 7 (7b logging, 7c set_fw_hang) are NOT in this
# script on purpose.
# Run: ./rrun phase7a.sh > ../raw/phase7a-restart-policy.txt
sec() { echo; echo "===== $* ====="; }

sec subsystem_restart-params
for p in /sys/module/subsystem_restart/parameters/*; do
  [ -e "$p" ] && echo "${p##*/} = $(cat $p 2>/dev/null)"
done
ls /sys/module/ | grep -i -E "subsys|restart|remoteproc|q6" 

sec msm_subsys-devices
ls /sys/bus/msm_subsys/devices/ 2>/dev/null
for d in /sys/bus/msm_subsys/devices/*; do
  [ -d "$d" ] || continue
  echo "$d name=$(cat $d/name 2>/dev/null) restart_level=$(cat $d/restart_level 2>/dev/null) crash_count=$(cat $d/crash_count 2>/dev/null) firmware_name=$(cat $d/firmware_name 2>/dev/null)"
done

sec remoteproc-state
for d in /sys/class/remoteproc/*; do
  echo "-- ${d##*/}"
  for f in name state firmware coredump recovery; do
    [ -e "$d/$f" ] && echo "   $f = $(cat $d/$f 2>/dev/null)"
  done
done
ls /sys/kernel/debug/remoteproc/ 2>/dev/null

sec dt-auto-restart
find /sys/firmware/devicetree/base -name 'qca,auto-restart' 2>/dev/null | sed 's#/qca,auto-restart##'

sec dt-cd00000-nodes
for n in $(find /sys/firmware/devicetree/base -iname '*cd00000*' 2>/dev/null); do
  echo "-- $n"
  echo "   compatible=$(tr '\0' ' ' < $n/compatible 2>/dev/null)"
  echo "   status=$(tr -d '\0' < $n/status 2>/dev/null)"
done

sec dt-q6-wcss
for n in $(find /sys/firmware/devicetree/base -maxdepth 3 -iname '*q6*' -o -maxdepth 3 -iname '*wcss*' 2>/dev/null); do
  echo "-- $n compatible=$(tr '\0' ' ' < $n/compatible 2>/dev/null) status=$(tr -d '\0' < $n/status 2>/dev/null)"
done

sec fw_recovery
for r in wifi0 wifi1; do
  echo "$r get_fw_recovery -> $(cfg80211tool $r get_fw_recovery 2>&1 | head -2)"
  echo "$r get_fw_dump -> $(cfg80211tool $r get_fw_dump 2>&1 | head -2)"
done

sec qca_ol-params
for p in /sys/module/qca_ol/parameters/*; do [ -e "$p" ] && echo "${p##*/} = $(cat $p 2>/dev/null)"; done

sec panic-settings
echo "kernel.panic = $(cat /proc/sys/kernel/panic 2>/dev/null)"
echo "kernel.panic_on_oops = $(cat /proc/sys/kernel/panic_on_oops 2>/dev/null)"
echo "vm.panic_on_oom = $(cat /proc/sys/vm/panic_on_oom 2>/dev/null)"

sec interrupts-q6
grep -i -E 'q6v5|smp2p|wcss|fatal|ready|handover|stop-ack|spawn' /proc/interrupts

sec interrupts-all
cat /proc/interrupts

sec crash-partitions
grep -iE "crash" /proc/mtd
ls -la /sys/kernel/debug/qcom_debug_logs/ 2>/dev/null
for f in /sys/kernel/debug/qcom_debug_logs/*; do [ -f "$f" ] && echo "## $f"; done

sec dynamic_debug-current
grep -cE '' /sys/kernel/debug/dynamic_debug/control 2>/dev/null
grep -E 'q6v5_wcss|subsystem_restart' /sys/kernel/debug/dynamic_debug/control 2>/dev/null | head -20

sec ramoops-pstore
ls /sys/fs/pstore/ 2>/dev/null; echo "(pstore listing above, if any)"
