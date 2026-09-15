#!/bin/sh
# Phase 4 - NSS core and ECM (Q3).  READ ONLY.
# Run: ./rsh < phase4.sh > ../raw/phase4-nss.txt
sec() { echo; echo "===== $* ====="; }

sec nss-sysctl-tree
find /proc/sys/dev/nss -type f 2>/dev/null | sort | while read f; do
  echo "$f = $(cat $f 2>/dev/null)"
done

sec nss-n2hcfg
for f in /proc/sys/dev/nss/n2hcfg/*; do [ -f "$f" ] && echo "${f##*/} = $(cat $f 2>/dev/null)"; done

sec nss-stats-idle
for f in /sys/kernel/debug/qca-nss-drv/stats/*; do
  [ -f "$f" ] || continue
  echo "== $f"; cat "$f" 2>/dev/null
done

sec nss-meminfo
cat /sys/kernel/debug/qca-nss-drv/meminfo 2>/dev/null
ls -la /sys/kernel/debug/qca-nss-drv/ 2>/dev/null

sec nss-other-debugfs
find /sys/kernel/debug/qca-nss-drv -maxdepth 2 2>/dev/null | head -60

sec dmesg-nss
dmesg | grep -i -E "nss.*(version|profile|mem|pbuf|pool|firmware|core)|NSS core|n2h|h2n"

sec uci-nss-ecm
uci show nss 2>/dev/null
echo "---- ecm"
uci show ecm 2>/dev/null

sec sysctl-nss-ecm-conf
cat /etc/sysctl.d/qca-nss-ecm.conf 2>/dev/null
echo "---- qca-nss-drv.conf"
cat /etc/sysctl.d/qca-nss-drv.conf 2>/dev/null

sec ecm-debugfs
ls /sys/kernel/debug/ecm/ 2>/dev/null
for f in /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count \
         /sys/kernel/debug/ecm/ecm_nss_ipv6/accelerated_count \
         /sys/kernel/debug/ecm/ecm_db/connection_count \
         /sys/kernel/debug/ecm/ecm_nss_ipv4/stop \
         /sys/kernel/debug/ecm/ecm_nss_ipv6/stop; do
  [ -e "$f" ] && echo "$f = $(cat $f 2>/dev/null)"
done
find /sys/kernel/debug/ecm -maxdepth 2 -type f 2>/dev/null | head -60

sec nss-firmware
ls -la /lib/firmware/qca-nss*.bin 2>/dev/null
ls -la /lib/firmware/ 2>/dev/null | grep -i nss

sec nss-dp-interfaces
ls /sys/class/net/ 2>/dev/null
for i in eth0 eth1; do echo "-- $i"; cat /sys/class/net/$i/statistics/rx_packets 2>/dev/null; done

sec skb-recycler-again
ls -la /proc/net/skb_recycler* 2>/dev/null
find /proc/net -name '*skb*' 2>/dev/null
