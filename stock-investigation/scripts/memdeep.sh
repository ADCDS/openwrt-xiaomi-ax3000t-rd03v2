#!/bin/sh
# Deep memory accounting (Q1).  READ ONLY.
# Answers: where does stock's headroom come from, and what is holding the rest.
# Run: ./rrun memdeep.sh > ../raw/memdeep.txt
sec() { echo; echo "===== $* ====="; }

sec marker
date; echo "uptime: $(cat /proc/uptime)"; cat /proc/loadavg

sec meminfo
cat /proc/meminfo

sec zone-managed
grep -E "present|managed|spanned|start_pfn" /proc/zoneinfo

sec kernel-image-extent
# _text/_etext/_edata/_end give the static kernel footprint
grep -E " (_text|_stext|_etext|_sdata|_edata|__init_begin|__init_end|__bss_start|__bss_stop|_end)$" /proc/kallsyms
echo "-- iomem kernel lines --"
grep -i "Kernel" /proc/iomem

sec module-memory
echo "-- sum of module sizes from /proc/modules --"
awk '{s+=$2; n++} END {printf "modules=%d  total=%d bytes (%.2f MiB)\n", n, s, s/1048576}' /proc/modules
echo "-- top 25 modules by size --"
sort -k2 -rn /proc/modules | head -25 | awk '{printf "%10.2f KiB  %s\n", $2/1024, $1}'
echo "-- vmalloc attributed to load_module --"
grep -c load_module /proc/vmallocinfo
awk '/load_module/ {s+=$2} END {printf "load_module vmalloc = %d bytes (%.2f MiB)\n", s, s/1048576}' /proc/vmallocinfo

sec dma-coherent-wifi
echo "-- qdf DMA-consistent (Wi-Fi datapath rings/descriptors) --"
awk '/__qdf_mem_alloc_consistent/ {s+=$2; n++} END {printf "allocs=%d total=%d bytes (%.2f MiB)\n", n, s, s/1048576}' /proc/vmallocinfo
echo "-- dma_alloc / atomic pool --"
awk '/atomic_pool_init/ {s+=$2} END {printf "atomic_pool = %d bytes (%.2f MiB)\n", s, s/1048576}' /proc/vmallocinfo
echo "-- all 'user' (dma) mappings --"
awk '$NF=="user" {s+=$2; n++} END {printf "user/dma mappings=%d total=%d bytes (%.2f MiB)\n", n, s, s/1048576}' /proc/vmallocinfo

sec vmalloc-breakdown
awk '{
  key="";
  for (i=3; i<=NF; i++) {
    if ($i ~ /^pages=/ || $i ~ /^phys=/ || $i=="vmalloc" || $i=="ioremap" || $i=="user" || $i=="vpages") break;
    key = (key=="" ? $i : key" "$i);
  }
  kind=$NF;
  s[kind" | "key]+=$2;
} END { for (k in s) printf "%12d  %s\n", s[k], k }' /proc/vmallocinfo | sort -rn | head -40

sec vmalloc-real-ram
# ioremap entries map device/no-map memory and cost no RAM; vmalloc/user/vpages do.
awk '$NF!="ioremap" {s+=$2} END {printf "non-ioremap vmalloc = %d bytes (%.2f MiB)\n", s, s/1048576}' /proc/vmallocinfo
awk '$NF=="ioremap" {s+=$2} END {printf "ioremap (no RAM cost) = %d bytes (%.2f MiB)\n", s, s/1048576}' /proc/vmallocinfo

sec slab-note
echo "stock is CONFIG_SLUB without CONFIG_SLUB_DEBUG: no /proc/slabinfo and"
echo "the per-cache objects/slabs sysfs attributes read 0/absent."
echo "meminfo Slab/SReclaimable/SUnreclaim (from vmstat NR_SLAB_*) is all there is."
grep -E "nr_slab" /proc/vmstat

sec percpu
grep -E "pcpu|percpu" /proc/vmallocinfo
echo "nr_cpus: $(grep -c ^processor /proc/cpuinfo)"

sec buddyinfo
cat /proc/buddyinfo
echo "-- free memory by order (KiB) --"
awk '/Normal/ {for(i=5;i<=NF;i++){o=i-5; printf "order-%-2d count=%-6s = %8.0f KiB\n", o, $i, $i*(2^o)*4}}' /proc/buddyinfo

sec processes-rss
echo "-- userspace RSS total --"
tot=0
for p in /proc/[0-9]*; do
  r=$(sed -n 's/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p' $p/status 2>/dev/null)
  [ -n "$r" ] && tot=$((tot+r))
done
echo "sum VmRSS (double counts shared) = ${tot} kB"
echo "-- top 20 --"
for p in /proc/[0-9]*; do
  n=$(sed -n 's/^Name:[[:space:]]*//p' $p/status 2>/dev/null)
  r=$(sed -n 's/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p' $p/status 2>/dev/null)
  [ -n "$r" ] && echo "$r $n"
done | sort -rn | head -20

sec accounting
awk '
/^MemTotal:/      {t=$2}
/^MemFree:/       {f=$2}
/^Buffers:/       {b=$2}
/^Cached:/        {c=$2}
/^AnonPages:/     {a=$2}
/^Slab:/          {s=$2}
/^KernelStack:/   {k=$2}
/^PageTables:/    {p=$2}
/^Shmem:/         {sh=$2}
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
  printf "  UNACCOUNTED %8d kB   <- modules + DMA-coherent + percpu + memmap gaps\n", t-known;
}' /proc/meminfo

sec swiotlb
dmesg | grep -i swiotlb
cat /sys/kernel/debug/swiotlb/* 2>/dev/null
