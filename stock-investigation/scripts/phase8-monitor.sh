#!/bin/sh
# Phase 8 monitor - runs ON the bench unit, writes a small CSV to /tmp.
#
# The control ssh session shares the congested 2.4 GHz link with the load, so
# the sampler must not depend on it.  Output is a few KB of text, fetched and
# deleted at the end of the run, which is within the "don't pile up in /tmp"
# rule.
# Usage (on the box):  sh /tmp/phase8-monitor.sh <seconds> > /tmp/phase8.csv
secs=${1:-240}
echo "t,memfree_kB,memavail_kB,slab_kB,sunreclaim_kB,sreclaim_kB,cached_kB,n2h_pool,pbuf_def_free,pbuf_def_total,payload_fails,loadavg"
i=0
while [ "$i" -lt "$secs" ]; do
  mf=$(sed -n 's/^MemFree:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo)
  ma=$(sed -n 's/^MemAvailable:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo)
  sl=$(sed -n 's/^Slab:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo)
  su=$(sed -n 's/^SUnreclaim:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo)
  sr=$(sed -n 's/^SReclaimable:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo)
  ca=$(sed -n 's/^Cached:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo)
  np=$(cat /proc/sys/dev/nss/n2hcfg/n2h_empty_pool_buf_core0 2>/dev/null)
  pf=$(sed -n 's/.*n2h_pbuf_def_free_count *= *\([0-9]*\).*/\1/p' /sys/kernel/debug/qca-nss-drv/stats/n2h 2>/dev/null)
  pt=$(sed -n 's/.*n2h_pbuf_def_total_count *= *\([0-9]*\).*/\1/p' /sys/kernel/debug/qca-nss-drv/stats/n2h 2>/dev/null)
  af=$(sed -n 's/.*n2h_payload_alloc_fails *= *\([0-9]*\).*/\1/p' /sys/kernel/debug/qca-nss-drv/stats/n2h 2>/dev/null)
  la=$(cut -d' ' -f1 /proc/loadavg)
  echo "$(date +%s),$mf,$ma,$sl,$su,$sr,$ca,$np,$pf,$pt,$af,$la"
  i=$((i+1))
  sleep 1
done
