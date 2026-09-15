#!/bin/sh
# Phase 1 - memory layout at boot (Q1).  READ ONLY.
# Run: ./rsh < phase1.sh > ../raw/phase1-memlayout.txt
sec() { echo; echo "===== $* ====="; }

sec dmesg-memory-lines
dmesg | grep -i -E "Memory:|reserved|cma|no-map|Kernel code|rmem|lowmem|highmem|Virtual kernel memory|vmalloc|\.text|\.data|\.init" | head -100

sec /proc/iomem
cat /proc/iomem

sec /proc/meminfo
cat /proc/meminfo

sec /proc/zoneinfo
cat /proc/zoneinfo

sec vm-sysctls
for k in min_free_kbytes watermark_scale_factor overcommit_memory overcommit_ratio \
         lowmem_reserve_ratio swappiness vfs_cache_pressure extra_free_kbytes \
         page-cluster dirty_ratio dirty_background_ratio panic_on_oom oom_kill_allocating_task; do
  [ -e /proc/sys/vm/$k ] && echo "vm.$k = $(cat /proc/sys/vm/$k)"
done

sec etc-sysctl-conf
cat /etc/sysctl.conf 2>/dev/null
echo "-- /etc/sysctl.d --"
for f in /etc/sysctl.d/*; do echo "## $f"; cat "$f"; done 2>/dev/null

sec memblock-reserved
cat /sys/kernel/debug/memblock/reserved 2>/dev/null

sec memblock-memory
cat /sys/kernel/debug/memblock/memory 2>/dev/null

sec reserved-memory-dt
for n in /sys/firmware/devicetree/base/reserved-memory/*; do
  [ -d "$n" ] || continue
  echo "-- $n"
  echo "   compatible=$(tr '\0' ' ' < $n/compatible 2>/dev/null)"
  echo "   no-map=$([ -e $n/no-map ] && echo yes || echo no)"
  echo -n "   reg=" ; hexdump -v -e '1/4 "%08x "' $n/reg 2>/dev/null; echo
  echo -n "   size="; hexdump -v -e '1/4 "%08x "' $n/size 2>/dev/null; echo
  echo -n "   alignment="; hexdump -v -e '1/4 "%08x "' $n/alignment 2>/dev/null; echo
  echo "   status=$(tr -d '\0' < $n/status 2>/dev/null)"
done

sec memory-node-dt
for n in /sys/firmware/devicetree/base/memory*; do
  echo "-- $n"; echo -n "   reg="; hexdump -v -e '1/4 "%08x "' $n/reg 2>/dev/null; echo
done

sec show_mem_notifier
ls /sys/kernel/debug/show_mem_notifier 2>/dev/null
cat /sys/kernel/debug/show_mem_notifier/show_mem 2>/dev/null | head -60

sec vmallocinfo-top
sort -k2 -n -r /proc/vmallocinfo 2>/dev/null | head -40

sec kernel-size-symbols
grep -E " (_text|_etext|_sdata|_edata|__bss_start|__bss_stop|_end|__init_begin|__init_end)$" /proc/kallsyms 2>/dev/null
