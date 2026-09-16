#!/bin/sh
# Phase 2 - idle memory breakdown (Q1).  READ ONLY.
# Run: ./rsh < phase2.sh > ../raw/phase2-idlemem.txt
sec() { echo; echo "===== $* ====="; }

sec marker
date; echo "uptime: $(cat /proc/uptime)"; cat /proc/loadavg

sec /proc/meminfo
cat /proc/meminfo

sec /proc/slabinfo
cat /proc/slabinfo

sec /proc/buddyinfo
cat /proc/buddyinfo

sec /proc/pagetypeinfo
cat /proc/pagetypeinfo

sec /proc/vmstat
cat /proc/vmstat

sec ps
ps w

sec per-process-rss
for p in /proc/[0-9]*; do
  n=$(sed -n 's/^Name:[[:space:]]*//p' $p/status 2>/dev/null)
  r=$(sed -n 's/^VmRSS:[[:space:]]*//p' $p/status 2>/dev/null)
  [ -n "$r" ] && echo "$r  pid=${p#/proc/}  $n"
done | sort -rn

sec skb_recycler
ls /proc/net/skb_recycler/ 2>/dev/null
for f in /proc/net/skb_recycler/*; do [ -f "$f" ] && echo "$f = $(cat $f 2>/dev/null)"; done
cat /proc/net/skb_recycler 2>/dev/null

sec skb-sysctls
ls /proc/sys/net/core/ 2>/dev/null
for k in /proc/sys/net/core/*; do [ -f "$k" ] && echo "$k = $(cat $k 2>/dev/null)"; done

sec conntrack
sysctl net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_count 2>/dev/null
cat /proc/sys/net/netfilter/nf_conntrack_buckets 2>/dev/null

sec vmallocinfo-total
awk '{s+=$2} END {printf "vmalloc total bytes = %d (%.1f MiB)\n", s, s/1048576}' /proc/vmallocinfo
echo "-- by caller --"
awk '{c=$3; for(i=4;i<=NF;i++){if($i=="pages="||$i ~ /^pages=/) break; c=c" "$i} s[c]+=$2} END {for (k in s) printf "%12d  %s\n", s[k], k}' /proc/vmallocinfo | sort -rn | head -30

sec sysctl-all
sysctl -a 2>/dev/null

sec free
free
