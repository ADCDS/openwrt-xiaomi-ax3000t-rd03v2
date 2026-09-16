#!/bin/sh
# v19-nss-pool-experiment.sh - does finding #1's runtime write actually free memory?
#
# Run ON the dev bench, on an NSS build:  ./bsh < v19-nss-pool-experiment.sh
#
# Finding #1 (stock-investigation/notes/V1.9-TUNING.md) proposes halving the NSS
# host-side buffer pool from the MEDIUM profile's 8704 buffers to stock's 4096,
# compensating on the NSS side with extra_pbuf_core0=802816. The arithmetic says
# ~10 MB of unreclaimable slab comes back:
#
#     (8704 - 4096) x 2304 B = 10,368 kB
#
# But writing the sysctl is NOT proof the memory is returned: the pool may be
# sized once at NSS init, in which case the knob is cosmetic and the change has
# to move to the build-time profile instead. That is the single question this
# script answers, and it is why it runs BEFORE the change is committed anywhere.
#
# Read-only until the marked write section; prints everything it does.
set -u

N2H=/proc/sys/dev/nss/n2hcfg
STATS=/sys/kernel/debug/qca-nss-drv/stats/n2h

say() { echo; echo "=== $* ==="; }

mem()  { grep -E '^(MemFree|MemAvailable|Slab|SReclaimable|SUnreclaim):' /proc/meminfo; }
pool() { for f in n2h_empty_pool_buf_core0 extra_pbuf_core0 n2h_high_water_core0 \
                  n2h_low_water_core0 n2h_queue_limit_core0; do
           [ -r "$N2H/$f" ] && printf '%-32s = %s\n' "$f" "$(cat "$N2H/$f")"
         done; }
nstat() { [ -r "$STATS" ] && grep -E 'pbuf_def_total|pbuf_def_free|payload_alloc_fails|pbuf_def_alloc_fail' "$STATS" \
           | sed 's/[[:space:]]\+/ /g' || echo "(debugfs n2h not readable)"; }

say "0. preconditions"
if [ ! -d "$N2H" ]; then
  echo "FATAL: $N2H missing - this is not an NSS build, or qca-nss-drv is not loaded."
  echo "       Finding #1 cannot be tested here. Flash an NSS image first."
  exit 1
fi
echo "uptime: $(uptime)"
echo "nss modules:"; lsmod | grep -E '^(qca_nss_drv|qca_nss_ecm|qca_nss_dp)' || echo "  (none!)"
echo "writability (both must be -rw- for the rc.local approach to be viable):"
ls -l "$N2H/n2h_empty_pool_buf_core0" "$N2H/extra_pbuf_core0" 2>&1

say "1. BEFORE - memory"
mem
say "1. BEFORE - pool config"
pool
say "1. BEFORE - n2h stats"
nstat

# ---- the only writes in this script ----
#
# ORDER: extra_pbuf_core0 first. Not because the driver requires it - the two
# sysctls take independent paths (different semaphores, different message types)
# and nss_n2h_set_empty_buf_pool() never consults buf_sz_allocated - but because
# extra_pbuf_core0 is WRITE-ONCE PER BOOT: nss_n2h_buf_cfg_core0_handler()
# returns -EPERM as soon as nss_ctx->buf_sz_allocated is non-zero. Write the
# knob that gets one chance while it still has it.
#
# THIS SCRIPT IS THEREFORE NOT RE-RUNNABLE WITHIN A BOOT. On a second run the
# -EPERM makes the write fail, yet the handler assigns the sysctl variable from
# buf_sz_allocated before returning, so the READBACK STILL PRINTS 802816. That
# looks like success. The check below distinguishes the two cases explicitly.
#
# Also note what this write is NOT: extra_pbuf pages are kzalloc(GFP_ATOMIC) +
# dma_map_single from HOST memory ("Add extra NSS bufs from host memory",
# nss_n2h.c), not the nss@40000000 carve-out. 802816 is a BYTE count
# (num_pages = ALIGN(size, PAGE_SIZE)/PAGE_SIZE), so it costs 196 pages =
# 784 KiB of extra Linux memory. The allocation loop carries BUG_ON(!page_count)
# if the first page of a message fails, and with MAX_PAGES_PER_MSG=32 those
# 196 pages span 7 messages - 7 chances to panic a memory-pressured box. Do not
# run this on anything you are not willing to reboot.
say "2. WRITE extra_pbuf_core0 = 802816 (stock's value)"
pre_extra=$(cat "$N2H/extra_pbuf_core0" 2>/dev/null)
echo "  before: $pre_extra"
if [ "${pre_extra:-0}" != "0" ]; then
  echo "  !! already non-zero: this boot has had extra_pbuf set already."
  echo "  !! The write below WILL fail with -EPERM and the readback will still"
  echo "  !! show the old value. Reboot before trusting this run."
fi
if echo 802816 > "$N2H/extra_pbuf_core0" 2>/dev/null; then
  echo "  write ok"
else
  echo "  WRITE FAILED (-EPERM => already set this boot; readback below is NOT proof)"
fi
sleep 2
echo "  readback: $(cat "$N2H/extra_pbuf_core0" 2>/dev/null)  <- equals buf_sz_allocated, not necessarily what we just wrote"

say "3. WRITE n2h_empty_pool_buf_core0 = 4096 (stock's value, ours is 8704)"
echo "  before: $(cat "$N2H/n2h_empty_pool_buf_core0" 2>/dev/null)"
if echo 4096 > "$N2H/n2h_empty_pool_buf_core0" 2>/dev/null; then
  echo "  write ok"
else
  echo "  WRITE FAILED"
fi
echo "  readback: $(cat "$N2H/n2h_empty_pool_buf_core0" 2>/dev/null)"

say "4. settle - sampling SUnreclaim every 10 s for 60 s"
echo "(the pool may only shrink as buffers are consumed, so watch the trend)"
i=0
while [ $i -lt 7 ]; do
  printf '  t+%-3ss  %s\n' "$((i*10))" "$(grep -E '^SUnreclaim:' /proc/meminfo | tr -s ' ')"
  i=$((i+1)); [ $i -lt 7 ] && sleep 10
done

say "5. AFTER - memory"
mem
say "5. AFTER - pool config"
pool
say "5. AFTER - n2h stats"
nstat

say "6. interpretation"
cat <<'EOT'
Compare SUnreclaim BEFORE vs AFTER.

NOTE: v1.9 ships the POOL KNOB ONLY, via /etc/init.d/nss-bufpool.
extra_pbuf_core0 was dropped - see V1.9-TUNING.md finding #1. This script still
writes both because its purpose is to characterise them; do not read a run of it
as a preview of the shipped configuration.

MEASURED on matched idle boots with the shipped (pool-only) configuration:

    SUnreclaim  44,576 -> 38,204 / 38,144 kB   =  about -6.3 MB

The arm that also set extra_pbuf gave only -5,212 kB from a single mid-boot
write, because that knob spends ~784 kB of host memory. Either way the original
9,584 kB estimate was wrong: it assumed 2,304 B per buffer, and back-solving from
the measurements gives 760-1,332 B, about kmalloc-1024 + skbuff_head_cache.
The 2,304 B figure came from a stock-vs-port SUnreclaim difference that also
contained ath11k and workload differences, so it was never a clean measurement.

  ~5,200 kB lower -> the runtime write DOES free memory. Finding #1 ships as an
                   rc.local block (build.sh's current block sets only
                   general/redirect and the two accel modes; the n2hcfg writes
                   would be added next to them).
  unchanged     -> the pool is sized at init only. The rc.local knob would be
                   cosmetic; #1 must instead become a build-time change, i.e.
                   the MEDIUM-vs-LOW profile decision of finding #4. Do NOT
                   ship the sysctl write in that case.

Also check pbuf_def_total_count: stock's extra_pbuf_core0=802816 grows the
NSS-side pool to 14884 (ours is 9984 with extra_pbuf_core0=0). If that number
does not move, the NSS core likely needs a restart to honour the new heap size,
which again makes this a build-time change rather than an rc.local one.

payload_alloc_fails is CUMULATIVE SINCE BOOT and does not advance at idle (it
read a frozen 45864 on the v1.8 reference AP after 8 d uptime). Its absolute
value is therefore NOT the pass/fail test and is not comparable to stock's "99"
on stock's own firmware. What matters is the DELTA across a forwarded-traffic
load run, measured after this change on our build.

Neither write persists across a reboot - but "not persistent" is not the same as
"reversible". n2h_empty_pool_buf_core0 can be written again freely;
extra_pbuf_core0 CANNOT be lowered or re-set this boot (-EPERM), and the pages it
allocated stay allocated until the module is reloaded. Reboot between runs.
EOT
