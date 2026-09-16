# Q1 — where stock's memory headroom actually comes from

The observation that started this:

```
Mem: 137908K used, 48756K free, 1832K shrd, 5928K buff, 29776K cached
```

48 MB free on a box where our port runs at ~15 MB free before the smallbuffers
fix. This note takes that apart. Measured side by side:

- **stock** — RD03v2, ROM 2.0.28, Linux 4.4.60 armv7l, 1 h uptime, both radios up
  (5 GHz ch 48 @ 160 MHz), 1 station.
- **port** — `192.168.100.2`, this port at **v1.8**, Linux 6.12.94 aarch64,
  8 d 18 h uptime, both radios up, 2 stations, `kmod-ath11k-smallbuffers`.

Captures: `captures/memdeep-stock.txt`, `captures/memdeep-port.txt`,
`captures/phase1-memlayout.txt`, `captures/slab-port.txt`.

> v1.8, not `main`. `main` has had PR #19 since. The structural findings below
> (kernel size, carve-outs, watermarks, NSS pool sizing) do not depend on that,
> but the exact slab number might.

---

## The headline numbers

| | stock | port v1.8 | delta |
|---|---:|---:|---:|
| `MemTotal` | **186,664 kB** | 175,760 kB | **+10,904** |
| `MemFree` (idle, before captures warmed the cache) | 48,548 kB | 46,244 kB | +2,304 |
| **`MemAvailable`** | **65,224–67,820 kB** | **31,844–32,304 kB** | **+33,380** |
| `Slab` | 54,152 kB | 67,392 kB | −13,240 |
| `SUnreclaim` | **50,836 kB** | **61,492 kB** | **−10,656** |
| `Cached` + `Buffers` | 35,828 kB | 15,696 kB | +20,132 |
| `vm.min_free_kbytes` | **2048** | **16384** | |
| zone `low` watermark | 1024 pg = 4,096 kB | 5120 pg = 20,480 kB | |

`MemFree` is the misleading one — it moves with page cache and it moved 34 MB
during my own captures (reading `/proc` and `/sys` filled the cache; `MemFree`
fell to 13 MB while `MemAvailable` stayed at 65 MB). **`MemAvailable` is the
honest figure, and stock has 2.05× ours.**

## Decomposition of the 33 MB gap

| contribution | ≈ MB | what it is |
|---|---:|---|
| smaller 32-bit kernel | **+10.6** | shows up directly in `MemTotal` (10,904 kB) |
| lower `min_free_kbytes` | **+16.0** | reserve `MemAvailable` subtracts (16,384 kB) |
| less unreclaimable slab | **+10.4** | `SUnreclaim` difference (10,656 kB) |
| overlap / sampling | −4.4 | the three terms are not strictly additive |
| **observed `MemAvailable` delta** | **+32.6** | 33,380 kB |

Three separate causes, roughly equal thirds. Only one of them is about Wi-Fi.

---

## 1. It is **not** the carve-outs (this was the main hypothesis, and it is wrong)

The itinerary expected stock might have *less* usable RAM, because
`stock_mp03.3.dts` reserves `qcn9000_pcie0@4E000000` (17 MiB) and
`dma_pool1@4F100000` (16 MiB) on a board with no QCN9000. **Neither is in the
live tree.** The bootloader rewrites them into two 512 KiB stubs:

```
rsvd1@4E000000 { no-map; reg = <0x00 0x4e000000 0x00 0x80000>; };
rsvd2@4E080000 { no-map; reg = <0x00 0x4e080000 0x00 0x80000>; };
```

So `/sys/firmware/fdt` is materially different from the carved DTS, and 32 MiB of
the carved reservations are handed back at boot. Anything reasoned from
`stock_mp03.3.dts` about runtime memory needs re-checking against `captures/live.dts`.

What each side actually reserves out of the 256 MiB:

| region | stock | port v1.8 |
|---|---:|---:|
| `nss@40000000` / `memory@40000000` | 8 MiB | 8 MiB |
| `tzapp` / `tz_apps@4a400000` | — | **4 MiB** |
| `uboot` / `bootloader@4a800000` | 2 MiB | 2 MiB |
| `sbl@4aa00000` | 1 MiB | 1 MiB |
| `smem@4ab00000` | 1 MiB | 1 MiB |
| `tz@4ac00000` | **4 MiB** | 2 MiB |
| `q6_mem_regions` / `wcss@4b000000` | 48 MiB | 48 MiB |
| `rsvd1` + `rsvd2` | **1 MiB** | — |
| **total no-map** | **65 MiB** | **66 MiB** |
| **System RAM left** | **191 MiB** | **190 MiB** |

Cross-checked against `/proc/iomem` on both boxes:

```
stock:  40800000-4a7fffff (160 MiB) + 4e100000-4fffffff (31 MiB) = 191 MiB
port :  40800000-4a3fffff (156 MiB) + 4ae00000-4affffff (2 MiB)
                                     + 4e000000-4fffffff (32 MiB) = 190 MiB
```

**One megabyte apart.** The carve-outs explain nothing.

(Side note for the port: our DT declares `wcss@4b000000` and `q6_mem_regions@4b000000`
over the same 48 MiB and the kernel prints `OF: reserved mem: OVERLAP DETECTED!`.
Harmless today — same base, same size — but it is a duplicate declaration.)

## 2. The 32-bit kernel: +10.9 MB of `MemTotal`

Same System RAM, different `MemTotal`, because the kernel's own static cost differs:

| | stock | port v1.8 |
|---|---:|---:|
| System RAM | 195,584 kB (191 MiB) | 194,560 kB (190 MiB) |
| `MemTotal` (managed) | 186,664 kB | 175,760 kB |
| **kernel + bootmem overhead** | **8,920 kB** | **18,800 kB** |

Where the ~9.9 MB of overhead difference goes:

- **Kernel image ≈ 6 MB.** Port, from its own boot line:
  `8768K kernel code, 906K rwdata, 2808K rodata, 960K init, 288K bss` — 12.5 MiB
  resident after init is freed. Stock, from `/proc/iomem` and kallsyms
  (`_stext 0x81208200`, `_etext 0x817c92a4`): 5.75 MiB code + 0.68 MiB data
  ≈ 6.4 MiB. A 4.4 kernel with a hand-picked config against a 6.12 kernel with
  OpenWrt's.
- **`mem_map` ≈ 2 MB.** `struct page` is 32 bytes on 32-bit 4.4 and 64 bytes on
  arm64 6.12. Over 65,536 spanned pages that is 2 MiB against 4 MiB.
- **≈ 2 MB of everything else** — arm64's 4-level page tables, 16 KiB thread
  stacks against 8 KiB, per-cpu areas, larger early allocations.

This part is **structural**. Short of a smaller kernel config it is not
recoverable, and it is the one third of the gap that is genuinely "because stock
is 32-bit".

## 3. `min_free_kbytes`: +16.4 MB of `MemAvailable`

```
stock:  vm.min_free_kbytes = 2048    zone Normal  min 512  low 1024  high 2560  (pages)
port :  vm.min_free_kbytes = 16384   zone DMA     min 4096 low 5120  high 6144  (pages)
        vm.watermark_scale_factor = 10
```

`MemAvailable` is computed as free minus the **low** watermark, plus the
reclaimable part of page cache and slab. Our low watermark is 20,480 kB against
stock's 4,096 kB, so **16,384 kB of the gap is nothing but this sysctl**.

Stock sets it explicitly in `/etc/sysctl.conf` (`vm.min_free_kbytes=2048`); ours
is the OpenWrt/kernel default scaled to zone size. This is the cheapest
single change available to the port, and it is a one-line sysctl default.

Two cautions before shipping it:

- **`min_free_kbytes` is not free memory, it is crash insurance.** It is the
  reserve that lets atomic/`GFP_ATOMIC` allocations succeed in interrupt context —
  exactly where an NSS or ath11k RX path allocates. Dropping 16 MB → 2 MB makes
  `MemAvailable` look better and makes atomic allocation failure more likely under
  burst. That must be validated under the #18 load, not just at idle.
- **Stock is not playing the same game if it loses.** Stock runs
  `vm.panic_on_oom=2` with `kernel.panic=3`: under memory exhaustion it *reboots*
  rather than OOM-killing. Ours OOM-kills `hostapd`/`netifd`. So "stock survives
  on 2 MB of reserve" is a claim about a box configured to reboot on failure.
- Stock's watermark ratios are also patched (1× / 2× / 5× rather than mainline
  4.4's 1× / 1.25× / 1.5×), so stock's `low` and `high` sit relatively further
  above `min` than a stock-kernel `min_free_kbytes=2048` would give us. Copying
  only the sysctl does not copy that behaviour.

## 4. Unreclaimable slab: +10.7 MB — and it looks like one NSS knob

Stock carries **50,836 kB** `SUnreclaim`, rock-steady across every sample
(50,836 → 50,840 → 50,848 → 50,860 over an hour). Our v1.8 carries **61,492 kB**
after 8 days. We are 10.7 MB heavier — with *fewer* modules (87 against stock's
206) and fewer features.

Neither kernel will name the caches (no `CONFIG_SLUB_DEBUG` on either side), so
this is arithmetic rather than measurement. But it lands very close:

```
n2h_empty_pool_buf_core0:  port 8704  -  stock 4096  =  4608 host skbs
assume kmalloc-2048 (2048 B) + skbuff_head_cache (~256 B)  ≈ 2304 B each
4608 × 2304 B                                              = 10,368 kB
observed SUnreclaim difference                             = 10,656 kB   (97% match)
```

The per-buffer size is the assumption to attack: 2304 B holds only if the NSS
payload size lands in `kmalloc-2048`. If it spills to `kmalloc-4096` the estimate
becomes 19,584 kB and badly overshoots the observed 10,656 kB — which is itself
weak evidence for the 2048 bucket, but not proof.

`n2h_empty_pool_buf_core0` is the count of empty buffers the **host** allocates
and hands to the NSS. They are ordinary skbs in Linux slab, permanently held, and
therefore unreclaimable. Stock asks Linux for half as many as we do.

Stock does not simply run with less buffering. It moves the buffering to the other
side of the fence:

| | stock | port v1.8 |
|---|---:|---:|
| `extra_pbuf_core0` (extra NSS descriptors, host-backed) | **802,816** | **0** |
| `n2h_empty_pool_buf_core0` (host-side, Linux slab) | **4096** | **8704** |
| resulting `n2h_pbuf_def_total_count` | **14,884** | 9,984 |
| `n2h_pbuf_def_free_count` | 6,692 | 9,982 |

Stock ends up with **more** NSS descriptors (14,884 vs 9,984) while spending
**less** Linux memory on the empty-buffer pool.

> **Correction (v1.9 review).** An earlier revision of this section said
> `extra_pbuf_core0` is "carved out of `nss@40000000`", i.e. that stock moves the
> buffering to the other side of the fence for free. **That is wrong**, and the
> error propagated into `V1.9-TUNING.md` and briefly into
> `tools/integrate-wifi-nss.py` before an adversarial review of the v1.9 changes
> caught it. In `nss-drv` the extra pbuf pages come from **host** memory:
> `nss_n2h_buf_pool_cfg()` does `kzalloc(PAGE_SIZE, GFP_ATOMIC)` +
> `dma_map_single()` per page, the function header reads "Add extra NSS bufs from
> host memory", and `nss_core.h` names the accounting field
> `buf_sz_allocated /* size of bufs allocated from host */`.
>
> So 802,816 bytes is ~784 KiB of **additional** Linux memory, not a relocation
> out of Linux. The net of matching stock is still strongly positive — roughly
> 10 MB of empty-pool slab returned against ~0.8 MB handed back — but it is a
> net, not a free transfer, and that distinction is what makes the arithmetic
> below honest.
>
> Two further properties of this knob, from the same source:
> - **Write-once per boot.** The handler returns `-EPERM` once
>   `buf_sz_allocated` is non-zero, so `extra_pbuf_core0` cannot be re-tuned or
>   undone without a module reload. It is *not* "runtime-reversible".
> - **`BUG_ON` on the first failed atomic page.** The allocation loop is
>   `GFP_ATOMIC` with `BUG_ON(!page_count)`. Setting this on a memory-pressured
>   box is therefore not risk-free, and it interacts badly with any proposal to
>   shrink `vm.min_free_kbytes` (finding #2) on the same box.

The NSS's own DDR heap is separate and unchanged by this knob:
`/sys/kernel/debug/qca-nss-drv/meminfo/core0` shows `heap_ddr_size 0x800000 @
0x40000000`, the 8 MiB `nss@40000000` region that is `no-map` reserved on our
board whether we use it or not.

**This is the actionable finding for PR #17's NSS memory profile:** set
`n2h_empty_pool_buf_core0=4096` and `extra_pbuf_core0=802816`, matching stock.
Both are runtime sysctls under `/proc/sys/dev/nss/n2hcfg/`, so the hypothesis is
cheap to falsify — write the values on a test box and re-read `SUnreclaim`. If
the arithmetic above is right, it should drop by about 10 MB.

Two smaller related items:
- Stock's `qca-nss-drv` is built **without** the skb recycler (`/proc/net/skb_recycler`
  does not exist). Ours has it and it is disabled (`skb_recycler_enable=0`,
  `max_skbs=512`). No memory difference today, but it is dead weight.
- `n2h_wifi_pool_buf` is **0** on both — the dedicated NSS Wi-Fi pool is not in use
  even on stock, where Wi-Fi offload *is* active.

## 5. What is **not** the answer

Worth recording, because these were the plausible suspects:

- **Wi-Fi DMA rings are nearly a tie.** Stock's `dma_alloc_coherent` total for both
  radios is **16.67 MiB** (86 allocations, all `__qdf_mem_alloc_consistent`). Ours
  is **18.87 MiB** (`dma_common_contiguous_remap`). `kmod-ath11k-smallbuffers`
  has already closed this to ~2 MB. The README's "~38 MB ath11k footprint" is
  therefore mostly slab, not DMA rings — and that reframes where to look next.
  - Stock gets its 16.67 MiB partly for free from NSS offload: with `wifili`
    engaged the host allocates `dp_nss_reo_dest_rings=1` and
    `dp_nss_tcl_data_rings=1` instead of the non-offload `dp_reo_dest_rings=4` /
    `dp_tcl_data_rings=3`. Monitor rings are off entirely
    (`dp_pdev_rx_ring=0`, `dp_pdev_tx_ring=0`).
- **Modules cost stock *more*.** 206 modules, 10.05 MiB of vmalloc, against our
  87 modules and ~6 MiB. Stock is carrying a much larger netfilter/ipset/Xiaomi
  module set and still comes out ahead.
- **Page cache is a symptom, not a cause.** Stock had 53 MB cached to our 15 MB.
  That is what a box with room does, not why it has room.

## What to do with this

Ranked by MB per unit of risk:

1. **NSS pool sizing** (**shipped in v1.9 as the pool knob only: ~6.3 MB
   measured**). `extra_pbuf_core0` was dropped - it costs ~784 kB of host memory,
   is write-once per boot, and its `GFP_ATOMIC` allocator carries a `BUG_ON`
   that would be a reboot loop at boot. See `V1.9-TUNING.md` finding #1.
   `n2h_empty_pool_buf_core0=4096`, `extra_pbuf_core0=802816`. Verify by reading
   `SUnreclaim` before/after on a test box.
2. **Finish NSS Wi-Fi offload** (Q2). Beyond CPU, it collapses the host DP ring
   layout from 4+3 rings to 1+1 and is how stock reaches 16.67 MiB of coherent DMA.
3. **`vm.min_free_kbytes`** (~16 MB of `MemAvailable`, but see the cautions).
   Do not ship it on the strength of idle numbers; run the #18 load first, and
   decide separately whether we want stock's reboot-on-OOM posture.
4. **Kernel size** (~6 MB) — a config exercise, low leverage per hour.

## Under load

Phase 8 was run in reduced form (details and caveats in
[`FINDINGS.md`](FINDINGS.md#phase-8--load-partial-q1)): 180 s of sustained 5 GHz
RX into the router, 2.35 GB moved, sampled at 1 Hz.

```
SUnreclaim              51,016 -> 51,304 kB   (+288 kB, +0.6%, plateaus)
MemAvailable            65,112 -> 63,312 kB   (-1,800 kB, then flat)
n2h_pbuf_def_free_count  6,692 ->  6,691      (pool never drained)
n2h_payload_alloc_fails     99 ->     99      (no new failures)
```

Stock's unreclaimable slab is **flat** under the load I could generate. The
number that holds our 50 MB / 61 MB difference is a fixed allocation on both
sides, not something that grows — consistent with it being the NSS host pool,
which is sized once at init.

The caveat matters: my traffic terminated on the router, so ECM/NSS *forwarding*
acceleration was never exercised, and 5 minutes is not a soak. This does not yet
refute #18's mechanism; it only says stock does not leak in the regime reachable
on this bench.

## Still open

- **The real #18 comparison.** Needs a wired host on one of the RD03v2's LAN
  ports so traffic is forwarded (5 GHz ↔ wired) rather than terminated, and needs
  hours rather than minutes. The bench currently has no wired client on the stock
  unit's LAN.
- **Confirming the NSS pool hypothesis** by writing
  `n2h_empty_pool_buf_core0=4096` on a port-side test box and re-reading
  `SUnreclaim`. Runtime-only, and re-tunable for the pool knob (though
  `extra_pbuf_core0` is write-once per boot); not done here because the only
  port-side box available is in service.
- Per-cache attribution on either side. Blocked: no `CONFIG_SLUB_DEBUG` on stock
  *or* on our build. Getting it needs a kernel rebuild on our side; on stock it is
  not obtainable at all.
