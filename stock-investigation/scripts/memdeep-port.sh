#!/bin/sh
# Port-side mirror of memdeep.sh, for the A/B against stock.  STRICTLY READ ONLY.
# Target: 192.168.100.2, running v1.8 of this port (in service as backhaul).
# Run: ./psh 'sh -s' < memdeep-port.sh > ../raw/memdeep-port.txt
sec() { echo; echo "===== $* ====="; }

sec marker
date; echo "uptime: $(cat /proc/uptime)"; cat /proc/loadavg
uname -a
cat /etc/openwrt_release 2>/dev/null

sec meminfo
cat /proc/meminfo

sec zone-managed
grep -E "present|managed|spanned|start_pfn|Node" /proc/zoneinfo

sec dmesg-memory
dmesg 2>/dev/null | grep -i -E "Memory:|reserved|cma|Kernel code|rmem|available" | head -30

sec iomem
cat /proc/iomem 2>/dev/null | grep -i -E "System RAM|Kernel"

sec reserved-memory-dt
for n in /sys/firmware/devicetree/base/reserved-memory/*; do
  [ -d "$n" ] || continue
  echo "-- ${n##*/}"
done

sec vm-sysctls
for k in min_free_kbytes watermark_scale_factor overcommit_memory lowmem_reserve_ratio \
         panic_on_oom swappiness vfs_cache_pressure; do
  [ -e /proc/sys/vm/$k ] && echo "vm.$k = $(cat /proc/sys/vm/$k)"
done

sec zone-watermarks
grep -E "zone|min|low|high|managed|present" /proc/zoneinfo | head -40

sec slabinfo-top
if [ -r /proc/slabinfo ]; then
  echo "-- top 30 caches by bytes (active_objs * objsize) --"
  grep -v '^#' /proc/slabinfo | awk 'NF>=6 {printf "%10.1f KiB  objs=%-8s objsize=%-6s %s\n", ($2*$4)/1024, $2, $4, $1}' | sort -rn | head -30
  echo "-- total from pages --"
  grep -v '^#' /proc/slabinfo | awk 'NF>=15 {s+=$15*$6*4} END {printf "slab pages total = %.1f MiB\n", s/1024}'
else
  echo "no /proc/slabinfo"
  ls /sys/kernel/slab >/dev/null 2>&1 && echo "(sysfs slab present)"
fi

sec module-memory
awk '{s+=$2; n++} END {printf "modules=%d total=%d bytes (%.2f MiB)\n", n, s, s/1048576}' /proc/modules
sort -k2 -rn /proc/modules | head -20 | awk '{printf "%10.2f KiB  %s\n", $2/1024, $1}'

sec vmallocinfo
if [ -r /proc/vmallocinfo ]; then
  awk '{s+=$2} END {printf "vmalloc total = %d bytes (%.2f MiB)\n", s, s/1048576}' /proc/vmallocinfo
  awk '$NF!="ioremap" {s+=$2} END {printf "non-ioremap = %.2f MiB\n", s/1048576}' /proc/vmallocinfo
  echo "-- by caller (top 30) --"
  awk '{
    key="";
    for (i=3; i<=NF; i++) {
      if ($i ~ /^pages=/ || $i ~ /^phys=/ || $i=="vmalloc" || $i=="ioremap" || $i=="user" || $i=="vpages") break;
      key = (key=="" ? $i : key" "$i);
    }
    s[$NF" | "key]+=$2;
  } END { for (k in s) printf "%12d  %s\n", s[k], k }' /proc/vmallocinfo | sort -rn | head -30
else
  echo "vmallocinfo not readable (kptr_restrict?)"
fi

sec ath11k-dma
grep -iE "ath11k|dma" /proc/vmallocinfo 2>/dev/null | head -20

sec cma
cat /proc/meminfo | grep -i cma
ls /sys/kernel/debug/cma 2>/dev/null

sec buddyinfo
cat /proc/buddyinfo

sec wifi-state
iw dev 2>/dev/null | grep -E "Interface|ssid|channel|type"
for p in /sys/kernel/debug/ieee80211/*; do echo "-- ${p##*/}"; done 2>/dev/null

sec stations
for i in $(ls /sys/class/net/ | grep -E '^(wlan|phy)'); do
  echo "-- $i: $(iw dev $i station dump 2>/dev/null | grep -c '^Station')"
done

sec lsmod-count
lsmod | wc -l

sec processes-rss
tot=0
for p in /proc/[0-9]*; do
  r=$(sed -n 's/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p' $p/status 2>/dev/null)
  [ -n "$r" ] && tot=$((tot+r))
done
echo "sum VmRSS = ${tot} kB"

sec accounting
awk '
/^MemTotal:/    {t=$2} /^MemFree:/ {f=$2} /^Buffers:/ {b=$2} /^Cached:/ {c=$2}
/^AnonPages:/   {a=$2} /^Slab:/ {s=$2} /^KernelStack:/ {k=$2} /^PageTables:/ {p=$2}
END {
  known=f+b+c+a+s+k+p;
  printf "MemTotal      %8d kB\n", t;
  printf "  MemFree     %8d kB\n", f;
  printf "  Buffers     %8d kB\n", b;
  printf "  Cached      %8d kB\n", c;
  printf "  AnonPages   %8d kB\n", a;
  printf "  Slab        %8d kB\n", s;
  printf "  KernelStack %8d kB\n", k;
  printf "  PageTables  %8d kB\n", p;
  printf "  ---------------------\n";
  printf "  accounted   %8d kB\n", known;
  printf "  UNACCOUNTED %8d kB\n", t-known;
}' /proc/meminfo

sec ethtool-pause-and-mac
for i in eth0 eth1; do echo "== $i"; ethtool -a $i 2>&1 | head -8; done
command -v devmem >/dev/null 2>&1 && { echo "-- GMAC flow ctrl regs --"; devmem 0x39c00018 32; devmem 0x39d00018 32; } || echo "no devmem"
