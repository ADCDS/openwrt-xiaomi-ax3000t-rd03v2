# Live stock RD03v2 — findings (Q1–Q7)

First execution of [`STOCK-LIVE-ITINERARY.md`](../STOCK-LIVE-ITINERARY.md) against a real rooted RD03v2 running
Xiaomi stock. Phases 0–6 and the read-only half of 7 are done. Phases 7c (crash
injection) and 8 (load test) are **not** in this note.

| | |
|---|---|
| Unit | RD03v2, `Hardware: Ver. A`, bench, `192.168.31.1` |
| ROM | **2.0.28**, `release` channel, BUILDTS 1766551036 (2025-12-24), GTAG `d40e7037e28d…` |
| Kernel | Linux **4.4.60** `#0 SMP PREEMPT`, **armv7l** (32-bit), musl userspace |
| Uptime during capture | 58 min → 1 h 15 min, no reboot |
| Wi-Fi at capture time | 2.4 GHz ch 6 HT20, 5 GHz ch 48 **160 MHz**, both AP, 1 station (capture host) |
| Reference for A/B | `192.168.100.2`, this port at **v1.8**, kernel 6.12.94 aarch64, 8 d 18 h uptime, 2 stations |

The ROM matches the offline extraction (`ax3000t-firmware/rootfs28`), so the
file-based conclusions in the itinerary hold.

> The v1.8 reference box is in service as backhaul. Everything taken from it was
> read-only. `main` has moved past v1.8, so treat port-side numbers as "v1.8",
> not "current".

---

## Answers in one line each

| # | Question | Answer |
|---|---|---|
| Q1 | Where does stock's memory headroom come from? | **Not** from carve-outs — those match ours within 1 MiB. It is ~11 MB smaller 32-bit kernel + ~16 MB lower `min_free_kbytes` + ~11 MB less unreclaimable slab. See [`Q1-MEMORY.md`](Q1-MEMORY.md). |
| Q2 | Is Wi-Fi really NSS-offloaded at runtime? | **Yes.** `wifili[0..2]` counters move with traffic. Our v1.8 has no `wifili` node at all. |
| Q3 | NSS buffer pool sizes? | Host pool **4096** (ours 8704), `extra_pbuf_core0` **802816** (ours 0), high/low water **16336/2048** (ours 8704/4352), `n2h_wifi_pool_buf` **0**. |
| Q4 | RX pause on the switch-facing GMAC? | Stock enables **RX *and* TX** pause in the MAC (`0x6`), on **both** GMACs. Our patch sets RX only (`0x4`). |
| Q5 | Crash recovery policy? | `restart_level = **RELATED**` on the root Q6 and both user PDs; ramdumps off; `qca,auto-restart` on every node. A Wi-Fi crash is *not* meant to reboot the box. |
| Q6 | What does a reset leave behind? | `bdata` holds `uart_en=0 ssh_en=0 telnet_en=0` and **no `boot_wait` key at all** — so *both* a factory reset and an OTA close the console. |
| Q7 | Does stock report a QCN6102 identity? | No — stock calls it **QCN6122** everywhere. Firmware **`WLAN.HK.2.5.r4-00683-QCAHKSWPL_SILICONZ-1.90153.1.94432.2`**. |

---

## Phase 0 — identity

`captures/phase0-identity.txt`, `captures/live.dts`

The kernel command line is the interesting part:

```
ubi.mtd=rootfs root=mtd:ubi_rootfs rootfstype=squashfs
cnss2.bdf_integrated=0x24 cnss2.bdf_pci0=0x60 cnss2.bdf_pci1=0x60
cnss2.skip_radio_bmap=4 rootwait uart_en=1 swiotlb=1
```

- `cnss2.skip_radio_bmap=4` — bit 2 set, so the third radio slot is skipped.
  This unit is a 2-radio board and stock tells the driver so on the command line.
- Board-data-file selectors are passed as `cnss2.bdf_*`: `0x24` for the
  integrated IPQ5018 radio, `0x60` for both PCIe slots.
- `swiotlb=1` — the smallest possible bounce buffer, i.e. effectively disabled.
- **There is no `console=`.** The console comes from the device tree instead:
  `chosen { stdout-path = "serial0"; }` → `/soc/serial@78af000`. `uart_en=1` is a
  Xiaomi-specific token, not a kernel one. Phase 7's UART plan is fine, but do not
  grep `/proc/cmdline` for `console=` to decide whether it will work.

Flags as found (and unchanged at teardown):

```
flag_boot_rootfs=0   flag_boot_success=1   flag_last_success=0
flag_try_sys1_failed=0  flag_try_sys2_failed=0  flag_ota_reboot=0
uart_en=1  boot_wait=on  ssh_en=1  telnet_en=0  restore_defaults=0
```

`flag_boot_rootfs=0` → booted system 1. This unit has been opened up by whoever
rooted it: `uart_en`/`ssh_en`/`boot_wait` are all *non-default* in nvram (see Q6).

**Caveat for every future visit: the dmesg ring had already wrapped at 58 min
uptime.** Every `dmesg | grep` for boot-time lines came back empty, so the boot
log (memory map, firmware loads, NSS init) is *not* recoverable over ssh on a box
that has been up for an hour. Boot-log questions need either a reboot (which is a
flash write, see the ground rules) or UART from cold. The memory numbers in this
note were reconstructed from `/proc/iomem`, `/sys/kernel/debug/memblock` and
`/proc/zoneinfo` instead.

## Phase 1–2 — memory

See [`Q1-MEMORY.md`](Q1-MEMORY.md) for the full analysis. The two structural
results:

**The live device tree is not the carved one.** `stock_mp03.3.dts` contains
`qcn9000_pcie0@4E000000` (17 MiB) and `dma_pool1@4F100000` (16 MiB). Neither is
in `/sys/firmware/fdt`. The bootloader replaces them with two 512 KiB `rsvd1`/
`rsvd2` stubs, handing 32 MiB back to Linux. The itinerary's worry — "if they are
[reserved], stock has *less* usable RAM than we do" — is settled: **they are not
reserved.** Also absent from the live tree: `tzapp@4a400000`, which our port
*does* reserve as `tz_apps@4a400000` (4 MiB).

**`vm.min_free_kbytes` really is 2048 at runtime** — the itinerary's check passes.
Our v1.8 runs the OpenWrt default of 16384, eight times higher.

One oddity worth recording: stock's watermarks are `min 512 / low 1024 / high
2560` pages. Mainline 4.4 would compute `low = min + min/4` and `high = min +
min/2`, i.e. 512/640/768. Stock's are 1×/2×/5×, so the QSDK/Xiaomi kernel carries
a patched `__setup_per_zone_wmarks()`. It reclaims later but harder than
mainline.

**Neither kernel can be asked for per-cache slab data.** Stock is `CONFIG_SLUB`
without `CONFIG_SLUB_DEBUG`: no `/proc/slabinfo`, and the `objects`/
`total_objects`/`slabs` sysfs attributes are absent or read 0. Our v1.8 build is
the same. The itinerary's phase 2 plan — "compare slab caches one by one … by
object count" — **cannot be executed on either side without rebuilding a kernel.**
`/proc/meminfo`'s `Slab`/`SUnreclaim` is the whole budget. Plan around this.

## Phase 3 — Wi-Fi driver state (Q2, Q7)

`captures/phase3-wifi.txt`

**Q2 — yes, NSS Wi-Fi offload is live.** `/sys/kernel/debug/qca-nss-drv/stats/wifili`
exists with three soc/pdev indices and moving counters:

```
wifili[0]_rx_deliverd   = 6242      wifili[0]_tx_sent_count = 8110
wifili[0]_reo_reaped    = 6241      wifili[0]_tcl_ring_sent = 8110
```

while the legacy `stats/wifi` node is all zeros — so the datapath is the Lithium
(`wifili`) offload, not the older `wifi` one. On the v1.8 reference box
`/sys/kernel/debug/qca-nss-drv/stats/` has **no `wifili` and no `wifi` node at
all**: our released image runs the ath11k datapath entirely on the ARM cores.

One stock counter is not clean: `wifili[0]_rx_desc_alloc_fail = 66122`. Stock
does run out of RX descriptors on the 2.4 GHz SoC index; it just doesn't fall over.

**Q7 — stock says QCN6122, never QCN6102.** The name appears as
`/ini/internal/QCN6122_i.ini`, `/lib/firmware/qcn6122/`, the cnss debugfs device
`QCN6122_1`, and the DT nodes `q6_qcn6122_data1@4CF00000` /
`q6_qcn6122_etr_1@4DF00000`. Both radios report firmware readiness through cnss:

```
/sys/kernel/debug/cnss/QCA5018/stats   State: 0x7 (QMI_WLFW_CONNECTED | FW_MEM_READY | FW_READY)
/sys/kernel/debug/cnss/QCN6122_1/stats State: 0x7 (QMI_WLFW_CONNECTED | FW_MEM_READY | FW_READY)
```

Firmware version (`/lib/firmware/IPQ5018/fw_version.txt`):

```
WLAN.HK.2.5.r4-00683-QCAHKSWPL_SILICONZ-1.90153.1.94432.2 v1
```

as the itinerary predicted (2.5.x where we run 2.7). The 5 GHz radio is a user PD
on the same Q6, so it has no separate version file; `/lib/firmware/qcn6122/` holds
only `bdwlan.bin`, `bdwlan.b60`, `caldata_1.bin` and `m3_fw.*`. **Both**
`bdwlan.bin` and `bdwlan.b60` are on disk, and the cmdline pins the choice with
`cnss2.bdf_pci0=0x60` — so it is the `.b60` variant that is selected, by board id
`0x60`, not by probing. Calibration comes from `caldata_1.bin` in the rootfs, not
from `0:ART` directly.

**`update_ini_for_lowmem` did not run on this ROM.** `/ini/global.ini` has
`low_mem_system=0`, `max_peers=0`, `max_vdevs=0` — all stock defaults, not the
lowmem rewrite the itinerary expected. What limits stock instead is in the
per-chip INIs, and it is aggressive in a different place:

```
dp_max_clients=64        dp_max_peer_id=64
dp_pdev_rx_ring=0        dp_pdev_tx_ring=0      # monitor rings OFF entirely
dp_nss_reo_dest_rings=1  dp_nss_tcl_data_rings=1
dp_reo_dest_rings=4      dp_tcl_data_rings=3    # the non-NSS path, unused here
```

That last pair is the important one. With NSS offload engaged the host allocates
**one** REO destination ring and **one** TCL data ring instead of four and three.
Stock's whole `dma_alloc_coherent` footprint for both radios is 16.67 MiB — see
Q1 — and this is why.

## Phase 4 — NSS core and ECM (Q3)

`captures/phase4-nss.txt`

| knob | stock | v1.8 port |
|---|---|---|
| `n2h_empty_pool_buf_core0` | **4096** | **8704** |
| `n2h_high_water_core0` | 16336 | 8704 |
| `n2h_low_water_core0` | 2048 | 4352 |
| `extra_pbuf_core0` | **802816** | **0** |
| `n2h_wifi_pool_buf` | 0 | 0 |
| `n2h_queue_limit_core0` | 256 | 256 |
| `rps/enable` | 1 | 0 |
| `qca_nss_drv.max_ipv4_conn` / `max_ipv6_conn` | 512 / 512 | — |
| `/proc/net/skb_recycler` | **absent** (compiled out) | present, `skb_recycler_enable=0` |

And the resulting pools, live:

| | stock | v1.8 port |
|---|---|---|
| `n2h_pbuf_ocm_total_count` | 1500 | 1500 |
| `n2h_pbuf_def_total_count` | **14884** | **9984** |
| `n2h_pbuf_def_free_count` | 6692 | 9982 |
| `n2h_n2h_tot_payloads` | 10617 | 4520 |

Read those two tables together, because the pattern is the whole point: **stock
buys more NSS-side descriptors while spending far less Linux memory on the
empty-buffer pool.** (Not "moves the buffering into the NSS's own reserved
heap" - see the correction below; the extra pbuf pages are host-allocated.)
`extra_pbuf_core0=802816` grows the NSS-side descriptor pool to 14884. The
host-side pool it asks Linux for is only 4096 buffers, half of ours.

> **Correction (v1.9 review).** This paragraph used to say those descriptors are
> "paid for out of the 8 MiB `nss@40000000` carve-out". They are not: in
> `nss-drv` the extra pbuf pages are `kzalloc(GFP_ATOMIC)` + `dma_map_single`
> from **host** memory. 802,816 is a byte count, so it is ~784 KiB of extra
> Linux memory, and the net gain of matching stock is ~9.4 MB, not ~10 MB. The
> knob is also write-once per boot (`-EPERM`). See `Q1-MEMORY.md`.

`/sys/kernel/debug/qca-nss-drv/meminfo/core0` confirms where the NSS heap lives:

```
22  heap_ddr_size   (null) (null) 0x800000  0x40000000    # 8 MiB @ nss@40000000
Available IMEM: 0x0
```

ECM is loaded and idle (`accelerated_count=0`, `connection_count=0`) — the bench
box has no WAN, so there is nothing to accelerate. `dev.nss.ipv4cfg.ipv4_conn` is
set to 4096 by `/etc/sysctl.d/qca-nss-drv.conf` but the sysctl **does not exist**
at runtime (only `ipv4_accel_mode` and `ipv4_dscp_map` are there); the module
parameter `max_ipv4_conn=512` is what actually sized the table. That sysctl line
is dead config on this build — worth knowing before copying it.

## Phase 5 — switch and GMAC (Q4)

`captures/phase5-switch.txt`

`ethtool -a eth0` reports `RX: off / TX: off` — and it is **wrong**, or at least
not describing the MAC. Reading the register directly:

```
devmem 0x39c00018 32  ->  0xFFFF0006     # eth0
devmem 0x39d00018 32  ->  0xFFFF0006     # eth1
```

In the DWMAC `GMAC_FLOW_CTRL` layout that is pause-time `0xFFFF` with bit 2 (RFE,
receive flow control enable) **and** bit 1 (TFE, transmit flow control enable)
both set. So:

- **Stock runs symmetric pause — RX *and* TX — on both GMACs.**
- Our nss-dp patch reads back `0x4` there (`docs/nss-wifi-validation.md`), i.e.
  RX only.
- `ethtool -a` on the port box also says `off/off`, so that output is uninformative
  on both sides. The register is the ground truth.

`eth1` has no PHY at its MDIO address, so `ethtool eth1` returns `I/O error`; only
the register read works there. On the AN8855 switch, `ssdk_sh port flowctrl get`
reports `ENABLE` on ports 1 and 2 and rejects the others as out of range.

This answers Q4 more strongly than the question asked: PR #19 turning RX pause on
for every build agrees with stock's *direction*, but stock also enables TX pause,
which we do not.

> I did not touch pause settings. If an A/B is wanted, it belongs in phase 8 with
> a restore afterwards.

## Phase 6 — the `boot_wait` reset (Q6)

`captures/phase6-nvram.txt`

This is the cleanest result of the visit. `bdata` on this unit holds:

```
uart_en=0    ssh_en=0    telnet_en=0
boot_wait    -> key absent entirely
```

while nvram holds `uart_en=1 ssh_en=1 boot_wait=on`. Combined with
`lib/preinit/31_restore_nvram`, which the itinerary already decoded offline:

- **`restore_defaults=1` (factory reset):** defaults replayed, `bdata sync`.
  `uart_en=0`, `boot_wait=off`. Console closed.
- **`restore_defaults=2` (OTA):** defaults replayed, then `flag_override` keeps
  `uart_en`/`ssh_en`/`telnet_en`/`boot_wait` *only where `bdata` holds `1`*.
  Here bdata holds `0` for the three it has and nothing for `boot_wait`.
  **Console closed as well.**

So on a unit prepared the way this one was, **both** paths shut the console. The
nvram values that keep UART and `boot_wait` alive are not protected by anything.
The README install warning should say: after rooting, also write the bdata copies
(`bdata set uart_en=1`, `ssh_en=1`, `boot_wait` likewise) if the access is meant
to survive a reset or an OTA — and that is a flash write, so it is a deliberate
decision, not a side effect.

Files that reference the reset machinery on the live box:
`/etc/init.d/boot_check`, `/etc/init.d/key_services_boot_check`,
`/lib/preinit/31_restore_nvram`, `/lib/preinit/39_mount_ubi_data`,
`/lib/preinit/90_mount_bind_etc`, `/sbin/re_restore.sh`, `/usr/sbin/bootinfo`,
`/usr/sbin/flashtestctl.sh`, `/usr/sbin/restore_defaults.sh`.

Which `restore_defaults` value a TFTP recovery leaves is still open — it needs a
recovery flash, and it stays out of scope.

## Phase 7a — restart policy, read-only (Q5)

`captures/phase7a-restart-policy.txt`

```
subsys0  qcom_q6v5_wcss      restart_level=RELATED  crash_count=0
subsys1  q6v5_wcss_userpd1   restart_level=RELATED  crash_count=0
subsys2  q6v5_wcss_userpd2   restart_level=RELATED  crash_count=0

subsystem_restart: enable_ramdumps=0  enable_mini_ramdumps=0
                   max_restarts=0  disable_restart_work=0  enable_debug=0
kernel.panic=3   kernel.panic_on_oops=1   vm.panic_on_oom=2
```

- **`RELATED`, not `SYSTEM`.** The itinerary flagged that a `SYSTEM` restart level
  would reboot the box on a Wi-Fi crash by design. It does not: stock restarts the
  related subsystems and keeps running. So if a crash *does* reset the board, that
  is a failure, not policy — same bug class as ours.
- Ramdumps are off, so nothing waits for a userspace collector. A crash should
  proceed immediately.
- `qca,auto-restart` is present on `q6v5_wcss@CD00000`,
  `qcom_q6v5_wcss@CD00000` and both its user PDs, plus `q6v5_m3`, `wifi3@f00000`
  and `wifi4@f00000` — matching the carved DTS.
- **Both `@CD00000` nodes are in the live tree**, `qcom,ipq5018-wcss-pil` and
  `qca,q6v5-wcss-rproc-ipq50xx`, and *neither* has a `status` property, so both
  default to `okay`. The one that actually bound is the PIL variant: remoteproc0
  carries `firmware = IPQ5018/q6_fw.mdt` and the subsys names are
  `qcom_q6v5_wcss` / `q6v5_wcss_userpdN`.
- `cfg80211tool wifiN get_fw_recovery` returns **0** on both radios — the driver's
  own recovery is off, and recovery is delegated entirely to SSR/remoteproc.
- smp2p interrupt counts from boot: `q6v5 ready` 2, `handover` 2,
  `userpdN_ready` 2, `userpdN_spawn_ack` 2, `userpdN_stop_ack` 1, and every
  `*_fatal` at **0**. This unit has never had a Wi-Fi firmware crash.

That is the pre-crash baseline phase 7c needs. Nothing was enabled or changed.

## Phase 8 — load, partial (Q1)

`captures/phase8-pre.txt`, `captures/phase8-monitor.csv`, `captures/phase8-post.txt`

Run in a reduced form, because the bench has **no wired host on the stock unit's
LAN** — `/proc/net/arp` had exactly one entry — and the box has no WAN uplink, so
the itinerary's "5 GHz client ↔ iperf3 server on the WAN segment" shape is not
reachable. What was done instead:

- `hal` joined the 5 GHz BSS (BSSID-pinned to `wl0`, ch 48 / 160 MHz) and served
  `/dev/zero` over TCP; the router pulled it with four parallel `nc` streams for
  180 s. That drives the 5 GHz **RX** path — `wifili` RX descriptors, NSS→host
  delivery, skb allocation — at ~47 Mbit/s per stream.
- A 90 s TCP run between a 2.4 GHz client and the 5 GHz client managed only
  6 Mbit/s (the capture host's 2.4 GHz dongle is the bottleneck) and is not
  useful as a load.
- 2.35 GB total through `wl0`; `n2h_rx_byts` reached 4.30 GB.

Result over 300 samples at 1 Hz:

| | start | end | drift |
|---|---:|---:|---:|
| `SUnreclaim` | 51,016 kB | 51,304 kB | **+288 kB (+0.6%)** |
| `MemAvailable` | 65,112 kB | 63,312 kB | −1,800 kB, then flat |
| `Slab` | 59,276 kB | 59,552 kB | +276 kB |
| `n2h_pbuf_def_free_count` | 6,692 | 6,691 | −1 |
| `n2h_payload_alloc_fails` | 99 | 99 | **0** |

**Stock's unreclaimable slab does not grow under sustained Wi-Fi RX load.** It
moved less than 1% and plateaued; the NSS pbuf pool was never drained and took no
new allocation failures. `wifili[1]_rx_desc_alloc_fail` climbed into the millions
over the run — stock does starve its RX descriptor ring — but that costs
throughput, not memory. No crash, no reboot: all three `crash_count` still 0.

**This is not yet the #18 comparison.** #18 is sustained 5 GHz↔WAN *forwarding*,
which engages ECM/NSS acceleration; my traffic terminated on the router, so ECM
never accelerated anything. And 5 minutes is not the multi-hour soak where our
`SUnreclaim` climbs past 100 MiB. Treat this as "stock shows no growth in the
regime I could reach", not as a refutation of #18's mechanism. To close it
properly the bench needs a wired host on one of the RD03v2's LAN ports.

---

## Port-side follow-ups

| Finding | Follow-up |
|---|---|
| `min_free_kbytes` 2048 vs our 16384 | Ship a sysctl default. ~16 MB of `MemAvailable` on a 175 MB box. Test under load before committing — see Q1 note for the caveat. |
| Host NSS pool 4096 vs our 8704, `extra_pbuf_core0` 802816 vs 0 | The numbers PR #17's memory profile asked for. Returns ~10 MB of Linux slab and spends ~0.8 MB of host memory on `extra_pbuf` (which is **not** the carve-out), so ~9.4 MB net. |
| `wifili` present on stock, absent on v1.8 | Q2 is settled in favour of finishing the NSS Wi-Fi work; it is also what buys stock the 1-ring DP layout. |
| MAC flow control `0x6` vs our `0x4` | PR #19's RX pause matches stock's direction; consider TX pause too. |
| `bdata` does not protect `boot_wait`/`uart_en` | README install warning needs the `bdata set` step spelled out. |
| `restart_level=RELATED`, ramdumps off, `get_fw_recovery=0` | The configuration phase 7c must reproduce before comparing crash behaviour. |
| Neither kernel has `CONFIG_SLUB_DEBUG` | Amend the itinerary: per-cache slab comparison is not possible as written. |
| `dev.nss.ipv4cfg.ipv4_conn` sysctl does not exist | Don't copy that line from stock's `/etc/sysctl.d/qca-nss-drv.conf`; use the module parameter. |
| Stock: `vm.panic_on_oom=2`, `kernel.panic=3` | Stock *reboots* instead of OOM-killing. Any "stock never OOMs" claim must be checked against that. |

## Teardown

Verified after the last capture: no reboot (uptime continuous), all twelve boot
flags byte-identical to phase 0, ROM still 2.0.28/BUILDTS 1766551036, all three
`crash_count` still 0, `dynamic_debug` untouched (the 2 pre-existing `=p` entries
only), and no leftover files in `/tmp`. Nothing was written to flash: no `mtd
write`, no `nvram set`/`commit`, no `bdata set`/`commit`, no `fw_setenv`, no UCI
commit. `devmem` was used for reads only.
