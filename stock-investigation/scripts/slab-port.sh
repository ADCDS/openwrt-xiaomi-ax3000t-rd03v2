#!/bin/sh
# Port-side SLUB detail, to name the caches behind the +10 MB SUnreclaim gap.
# STRICTLY READ ONLY.  Run: ./psh 'sh -s' < slab-port.sh > ../raw/slab-port.txt
echo "===== slub sysfs capability ====="
d=$(ls -d /sys/kernel/slab/* 2>/dev/null | head -1)
echo "sample=$d"
ls "$d" 2>/dev/null | tr '\n' ' '; echo

echo
echo "===== per-cache totals (name total_objects objects object_size slabs order slab_size) ====="
for d in /sys/kernel/slab/*; do
  [ -L "$d" ] && continue
  [ -d "$d" ] || continue
  printf '%s %s %s %s %s %s %s\n' "${d##*/}" \
    "$(cat $d/total_objects 2>/dev/null)" \
    "$(cat $d/objects 2>/dev/null)" \
    "$(cat $d/object_size 2>/dev/null)" \
    "$(cat $d/slabs 2>/dev/null)" \
    "$(cat $d/order 2>/dev/null)" \
    "$(cat $d/slab_size 2>/dev/null)"
done

echo
echo "===== aliases ====="
for d in /sys/kernel/slab/*; do
  [ -L "$d" ] && echo "${d##*/} -> $(readlink $d)"
done

echo
echo "===== nss n2h config (port) ====="
find /proc/sys/dev/nss -type f 2>/dev/null | sort | while read f; do
  case "$f" in *dscp_map) continue;; esac
  echo "$f = $(cat $f 2>/dev/null)"
done

echo
echo "===== skb recycler (port) ====="
ls /proc/net/skb_recycler/ 2>/dev/null
for f in /proc/net/skb_recycler/*; do [ -f "$f" ] && echo "$f = $(cat $f 2>/dev/null)"; done

echo
echo "===== nss stats dir (port) ====="
ls /sys/kernel/debug/qca-nss-drv/stats/ 2>/dev/null
echo "-- n2h --"
head -45 /sys/kernel/debug/qca-nss-drv/stats/n2h 2>/dev/null
echo "-- meminfo core0 --"
cat /sys/kernel/debug/qca-nss-drv/meminfo/core0 2>/dev/null | head -40

echo
echo "===== ath11k module params (port) ====="
for m in ath11k ath11k_ahb ath11k_pci qca_nss_drv; do
  echo "== $m"
  for p in /sys/module/$m/parameters/*; do [ -e "$p" ] && echo "   ${p##*/} = $(cat $p 2>/dev/null)"; done
done

echo
echo "===== conntrack (port) ====="
sysctl net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_count 2>/dev/null
