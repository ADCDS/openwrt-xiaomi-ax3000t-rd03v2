#!/bin/sh
# Stock has CONFIG_SLUB without SLUB_DEBUG, so there is no /proc/slabinfo.
# Walk /sys/kernel/slab instead.  Merged caches appear as symlink aliases onto a
# single real directory (":t-0000NNN" / ":at-0000NNN"), so only real dirs are
# counted and the aliases are listed separately.  READ ONLY.
# Run: ./rsh < slabdump.sh > ../raw/phase2-slab.txt
echo "===== slab real caches (name objects object_size slab_size total_objects slabs order) ====="
for d in /sys/kernel/slab/*; do
  [ -L "$d" ] && continue
  [ -d "$d" ] || continue
  n=${d##*/}
  printf '%s %s %s %s %s %s %s\n' "$n" \
    "$(cat $d/objects 2>/dev/null)" \
    "$(cat $d/object_size 2>/dev/null)" \
    "$(cat $d/slab_size 2>/dev/null)" \
    "$(cat $d/total_objects 2>/dev/null)" \
    "$(cat $d/slabs 2>/dev/null)" \
    "$(cat $d/order 2>/dev/null)"
done

echo
echo "===== slab aliases (merged caches) ====="
for d in /sys/kernel/slab/*; do
  [ -L "$d" ] || continue
  echo "${d##*/} -> $(readlink $d)"
done

echo
echo "===== slab reclaim_account flags ====="
for d in /sys/kernel/slab/*; do
  [ -L "$d" ] && continue
  [ -d "$d" ] || continue
  echo "${d##*/} reclaim_account=$(cat $d/reclaim_account 2>/dev/null) cache_dma=$(cat $d/cache_dma 2>/dev/null) align=$(cat $d/align 2>/dev/null)"
done
