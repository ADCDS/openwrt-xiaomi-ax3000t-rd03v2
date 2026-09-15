# Live stock RD03v2: inspection itinerary

What to check if we ever get a root shell on an RD03v2 running Xiaomi's stock
firmware. We already have 2.0.28 extracted offline
(`~/dev/routers/rd03v2/ax3000t-firmware/rootfs28`), so this list skips anything a
file already tells us. It covers what only a running box can show: values
computed at boot, memory under load, and how stock behaves when the Wi-Fi
firmware crashes.

Nothing here has been measured on stock. Stock was never rooted
(`ax3000t-firmware/ROOT_ASSESSMENT.md`).

## Open questions this should answer

| # | Question | Why it matters to the port | Phase |
|---|---|---|---|
| Q1 | Where does stock's memory headroom come from? | NSS images OOM under sustained 5 GHz↔WAN load (#18). Stock runs a 32-bit kernel, so part of the answer may be pointer size | 1, 2, 8 |
| Q2 | Is Wi-Fi really NSS-offloaded at runtime (`nss_wifi_olcfg=7`)? | The script says yes on `ap-mp*`; confirm it isn't overridden | 3 |
| Q3 | How big are stock's NSS buffer pools, and do they move under load? | Sizing for PR #17's NSS memory profile | 4 |
| Q4 | Does stock enable RX pause on the switch-facing GMAC? | PR #19 turns it on for every build; check that stock agrees | 5 |
| Q5 | How does stock bring a radio back after a Q6 crash, and in what order? | v1.8 leaves radios dead. Our 0823 respawn can reset the board, and that is traced to powering the internal radio down before the root's `pas_shutdown` | 0b, 7 |
| Q6 | Which `restore_defaults` value does a TFTP recovery leave, so `boot_wait` gets reset? | Install guide warns about the reset; the script is known, the trigger isn't | 6 (partly out of scope) |
| Q7 | Does the stock firmware report a QCN6102 identity anywhere? | ath11k and its firmware report nothing on our port | 3 |

## Ground rules

- **Keep the box off the internet.** A newer stock raises the anti-rollback
  floor, and then our `recovery.bin` list stops working for that unit. The
  auto-update switch is `otapred.settings.auto` (`/etc/config/vas`, service
  `auto_upgrade`), but changing it is a flash write. Isolate the box instead:
  its WAN goes to a bench segment with no default route and no DNS. Phase 8's
  iperf3 server lives on that segment.
- **No writes to flash** until the read-only phases are captured: no
  `mtd write`, `nvram set/commit`, `fw_setenv`, or config saves from the web UI.
- **Stock writes nvram on every boot.** `/etc/init.d/boot_check` (START=99) sets
  `flag_boot_success`, clears `flag_try_sys1_failed`/`flag_try_sys2_failed`,
  updates `flag_last_success`, and runs `nvram commit`. Every reboot (planned, or
  a reset in phase 7 or 8) is a flash write, and a reset loop can make U-Boot
  fall back to the other system partition. Keep reboots few, and compare the
  boot flags against the phase 0 capture after each one.
- **Stream every capture to the host.** `/tmp` is RAM on a 256 MB box, so don't
  let captures pile up there. Pipe them over ssh, e.g.
  `ssh root@stock 'sh -s' < phase1.sh > phase1.txt`.
- **Prepare one read-only script per phase before the visit.** The visit should
  be running them and checking the output, not typing commands.
- **Record the ROM version first.** If it isn't 2.0.28, diff its rootfs against
  our extraction before trusting any file-based conclusion.
- **Kernel and userspace are both 32-bit ARM.** The 2.0.28 FIT image says
  `arch = "arm"` (Linux 4.4.60), the kernel strings are ARMv7, and
  `bin/busybox` is ELF32 ARM EABI5 (musl). Bring *static armv7* builds of
  anything missing: `iperf3`, `strace`, and `slabtop` is optional
  (`/proc/slabinfo` is enough). Stock already has `devmem`, `ssdk_sh`,
  `ethtool`, `tcpdump`, `iw`, `cfg80211tool`, `wifitool`, `wifistats`, `apstats`
  and `nvram`.
- **The stock kernel has no ftrace, kprobes, pstore/ramoops or netconsole.** It
  has dynamic debug and a symbol table. A board reset loses everything except
  UART, so bring a UART adapter.
- **Phases 7 and 8 are disruptive.** Run them last, after everything else is
  saved. If the router isn't ours, tell its owner first: they drop every client
  and can reboot the box.
- **Leave the box as found.** Before leaving, undo every runtime change
  (dynamic debug, sysctls, `ethtool` pause settings, subsystem-restart
  parameters) and check the boot flags and ROM version against phase 0.

## Time budget

| Phase | Time | Disruptive |
|---|---|---|
| 0 identity, boot flags | 10 min | no |
| 1–6 read-only captures | 60–90 min | no |
| 7 crash recovery | 60–90 min | yes (clients drop, may reboot) |
| 8 load test | 60 min | yes (load, may OOM) |
| teardown and final checks | 10 min | no |

## Phase 0: identity and boot flags (10 min)

```sh
cat /usr/share/xiaoqiang/xiaoqiang_version
uname -a; cat /proc/cmdline; cat /proc/version
cat /proc/cpuinfo; uptime
cat /proc/mtd; ubinfo -a 2>/dev/null
nvram get flash_type
lsmod
ls /sys/firmware/devicetree/base/        # expect MP_256
cat /sys/firmware/devicetree/base/model
dmesg > dmesg-boot.txt                   # full boot log, before it rotates
logread > logread-boot.txt
bootinfo                                 # read-only script: current system, ROM, mtd
for f in flag_boot_rootfs flag_last_success flag_try_sys1_failed flag_try_sys2_failed \
         flag_boot_success flag_ota_reboot flag_boot_recovery uart_en boot_wait; do
  echo "$f=$(nvram get $f)"; done
```

Save `/sys/firmware/fdt` (`cat /sys/firmware/fdt > live.dtb`). It's the tree the
kernel actually booted, after U-Boot's fixups. Compare it with
`stock_mp03.3.dts`, which was carved out of the image and may not be the one
that booted.

Check that:
- The kernel is 32-bit (`uname -m` reads `armv7l`).
- `/proc/cmdline` has a `console=`. Phase 7 relies on the UART console, and
  stock may run with `uart_en=0`.
- Both system partitions are identified: which one booted
  (`flag_boot_rootfs`) and which ROM version the other one holds. A reset loop
  in phase 7 can boot the other one.

## Phase 0b: offline, before the visit (Q5)

The ordering answer doesn't need a crash. The stock kernel ships its symbol
table, including `q6v5_wcss_stop`, `q6v5_wcss_userpd_stop`,
`stop_q6_userpd`, `restart_multipd_subsystem`, `wait_for_shutdown_ack`,
`qcom_scm_int_radio_powerdown` and `qcom_scm_pas_shutdown`.

- Decompress the kernel from `pv28/stripped_28.bin/img-546134002_vol-kernel.ubifs`
  (FIT, `kernel@1`, lzma). Rebuild the symbol table from its kallsyms and
  disassemble those functions with `arm-none-eabi-objdump`.
- Write down the crash-stop order: whether the internal radio is powered down
  before or after `pas_shutdown`, when the user PDs' memory is unlocked, and
  whether stock waits for a shutdown or stop ack first.
- Cross-check against the public QSDK 4.4 `drivers/remoteproc/qcom_q6v5_wcss.c`
  for IPQ5018 and `subsystem_restart.c`.

Phase 7 then only has to confirm the order on hardware, and whether the board
survives it.

## Phase 1: memory layout at boot (Q1)

Our port has 171 MB managed (175376 kB) with 21692 pages reserved, on an arm64
kernel. Find stock's equivalents.

```sh
dmesg | grep -i -E "Memory:|reserved|cma|no-map|Kernel code|rmem|lowmem|highmem"
cat /proc/iomem                          # which carve-outs are really reserved
cat /proc/meminfo
cat /proc/zoneinfo | grep -E "Node|min|low|high|managed|present|protection"
sysctl vm.min_free_kbytes vm.watermark_scale_factor vm.overcommit_memory 2>/dev/null
cat /proc/sys/vm/lowmem_reserve_ratio
ls /sys/kernel/debug/memblock 2>/dev/null && cat /sys/kernel/debug/memblock/reserved
```

Check that:
- `vm.min_free_kbytes` is really **2048** at runtime (`/etc/sysctl.conf`),
  and the init-script default (16384) didn't win.
- The `qcn9000_pcie0` (17 MB) and `dma_pool1` (16 MB) carve-outs in the DTS are
  really reserved on a board with no QCN9000. If they are, stock has *less*
  usable RAM than we do.
- The kernel's own text/data/bss size. A 32-bit 4.4 kernel is likely much
  smaller than our arm64 6.12; get the number.
- The `mem_map` cost: `struct page` is about half the size on 32-bit, so stock
  spends roughly 2 MB less on it for 256 MB.

## Phase 2: idle memory breakdown (Q1)

Capture after boot has settled (≥10 min up, Wi-Fi up, one client joined):

```sh
cat /proc/meminfo
cat /proc/slabinfo                       # sort by num_objs*objsize on the host
cat /proc/buddyinfo /proc/pagetypeinfo
cat /proc/vmstat
ps w; for p in /proc/[0-9]*; do echo "$p $(grep -E 'VmRSS' $p/status 2>/dev/null)"; done
cat /proc/net/skb_recycler/max_skbs /proc/net/skb_recycler/max_spare_skbs 2>/dev/null
ls /proc/net/skb_recycler/ 2>/dev/null
sysctl net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_count
sysctl -a 2>/dev/null > sysctl-all.txt
```

Compare slab caches one by one against the live AP (192.168.100.2) on the same
uptime and client count. The biggest unreclaimable caches on each side are the
answer to Q1.

Compare **object counts** (`num_objs`), not bytes. Pointer-heavy objects
(`skbuff_head_cache`, `kmalloc-*`, conntrack) are smaller on the 32-bit kernel,
so bytes alone would credit stock with savings that are only word size. Record
each cache's `objsize` on both sides; the ratio shows how much of the gap is
word size.

## Phase 3: Wi-Fi driver state (Q2, Q7)

```sh
cat /ini/global.ini | grep -E "nss_wifi|low_mem"      # after the script rewrote it
cat /ini/internal/QCN6122_i.ini /ini/internal/QCA5018_i.ini | grep -E "dp_|num_"
cat /lib/wifi/wifi_nss_olcfg 2>/dev/null
for m in qca_ol umac wifi_3_0 qca_nss_drv; do
  echo "== $m"; for p in /sys/module/$m/parameters/*; do echo "$p=$(cat $p)"; done
done
dmesg | grep -i -E "qcn6|6102|6122|chip|soc_id|board_id|bdf|bdwlan|caldata|fw_version|WLAN.HK|mem_mode|nss.*wifi|wifili"
iw dev; iw phy
cfg80211tool wifi0 get_nss_wifi_offload 2>/dev/null   # knob name unconfirmed; list with `cfg80211tool wifi0`
wifistats wifi0 1; wifistats wifi1 1                   # try ids until the DP/ring pages show
apstats -v
ls /sys/kernel/debug/qca-nss-drv/stats/ && cat /sys/kernel/debug/qca-nss-drv/stats/wifili 2>/dev/null
```

Check that:
- `wifili` stats exist and count packets while a client transfers. That settles
  Q2.
- `update_ini_for_lowmem` really ran: peers 128, vdevs 9, monitor rings 128/128/512.
- The board file stock loads on the 5 GHz radio: `qcn6122/bdwlan.bin` or `.b60`?
  Also which board ID it selects, and whether it reads caldata from `0:ART`.
- The firmware version (expected WLAN.HK 2.5.x, where we use 2.7) and any
  chip/variant string. The stock driver may print more than ath11k (Q7).

## Phase 4: NSS core and ECM (Q3)

```sh
cat /proc/sys/dev/nss/n2hcfg/* 2>/dev/null   # empty/paged pool sizes, high/low water, extra_pbuf
ls -R /proc/sys/dev/nss/ > nss-sysctl-tree.txt
for f in /sys/kernel/debug/qca-nss-drv/stats/*; do echo "== $f"; cat $f; done > nss-stats-idle.txt
cat /sys/kernel/debug/qca-nss-drv/meminfo 2>/dev/null
dmesg | grep -i -E "nss.*(version|profile|mem|pbuf|pool)"
uci show nss 2>/dev/null; uci show ecm
cat /etc/sysctl.d/qca-nss-ecm.conf
cat /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count 2>/dev/null
```

The n2h pool sizes and `extra_pbuf_core0` are the numbers to copy into PR #17's
memory profile. The sysctl names come from `qca-nss-drv.ko` strings, so the exact
paths may differ. Walk `/proc/sys/dev/nss` if these miss.

## Phase 5: switch and GMAC (Q4)

```sh
ethtool -a eth0; ethtool -a eth1          # pause settings as stock left them
ethtool -S eth0; ethtool -S eth1
ssdk_sh port flowctrl get 0 2>/dev/null   # AN8855 is its own module (AN8855.ko), ssdk may not see it
ls /sys/module/AN8855/parameters/ 2>/dev/null
dmesg | grep -i -E "an8855|hsgmii|sgmii|2500|flow"
```

Also read the MAC2 flow-control register with `devmem`, at the same address our
nss-dp patch reads back. Our port reads `0x4` there with RX pause on (see
`docs/nss-wifi-validation.md`). Read it again after a Wi-Fi→wired transfer, and
dump the AN8855 per-port drop counters (FlowControlDrop on our port) before and
after.

Don't change pause settings with `ethtool -A` here. If an A/B is worth it,
do it in phase 8 and restore stock's value afterwards.

## Phase 6: boot flags and the `boot_wait` reset (Q6)

Offline, the reset is already located. `lib/preinit/31_restore_nvram` replays
`/usr/share/xiaoqiang/xiaoqiang-defaults.txt`, which contains `uart_en=0` and
`boot_wait=off`, into nvram and commits it:

- **`restore_defaults=1` (factory reset):** defaults are replayed, then
  `bdata sync`. Nothing preserves `boot_wait`.
- **`restore_defaults=2` (OTA):** defaults are replayed, then `flag_override`.
  That keeps `uart_en`/`ssh_en`/`telnet_en`/`boot_wait` only where `bdata` holds `1`.
- **Missing SN, SSID or CountryCode:** treated as corrupt nvram, same path as a
  factory reset.

What only the live box shows:

```sh
nvram show 2>/dev/null > nvram.txt        # read only
bdata show 2>/dev/null > bdata.txt        # or: for f in uart_en ssh_en telnet_en boot_wait; do bdata get $f; done
nvram get restore_defaults; nvram get boot_wait; nvram get uart_en
cat /proc/xiaoqiang/* 2>/dev/null
grep -rl -E "restore_defaults|flag_boot_success|flag_try_sys" /etc /lib /sbin /usr/sbin 2>/dev/null
```

- **Whether `bdata` holds `boot_wait=1` on any unit.** If it does, an OTA keeps
  the console open but a factory reset doesn't.
- **Who sets `flag_boot_success`, and when.** Offline this is
  `/etc/init.d/boot_check` at START=99. Confirm with `logread` timestamps, and
  check that nothing earlier sets it.

**Out of scope for this visit:** which `restore_defaults` value a TFTP
recovery leaves. Seeing it needs a recovery flash, then UART or an early hook
on the first boot after it. Only do it with the owner's consent, and after
every other phase.

## Phase 7: Wi-Fi firmware crash recovery (Q5) — disruptive

Everything from phases 0–6 must be saved first, and phase 0b should already
give the expected order. Keep a UART log running, because a board reset loses
the tail of ssh output (on our port, the last lines lost were exactly the ones
that mattered).

### 7a: restart policy, before any crash

Stock recovers through Qualcomm's subsystem-restart framework as well as
remoteproc. Its kernel contains `subsys-restart: Resetting the SoC - %s
crashed`, SYSTEM and RELATED restart levels, ramdump parameters and `Ramdump(%s):
Timed out waiting for userspace`. With restart level SYSTEM, a Wi-Fi crash
reboots the box by design. Read the policy first:

```sh
for p in /sys/module/subsystem_restart/parameters/*; do echo "$p=$(cat $p)"; done
ls /sys/bus/msm_subsys/devices/ 2>/dev/null && for d in /sys/bus/msm_subsys/devices/*; do
  echo "$d $(cat $d/name) $(cat $d/restart_level 2>/dev/null)"; done
find /sys/firmware/devicetree/base -name 'qca,auto-restart' | sed 's#/qca,auto-restart##'
for n in $(find /sys/firmware/devicetree/base -iname '*@cd00000'); do
  echo "$n compatible=$(cat $n/compatible) status=$(cat $n/status 2>/dev/null)"; done
cfg80211tool wifi0 get_fw_recovery 2>/dev/null; cfg80211tool wifi1 get_fw_recovery 2>/dev/null   # 0 off, 1 auto, 2 wait for user, 3 SSR only
for p in /sys/module/qca_ol/parameters/*; do echo "$p=$(cat $p)"; done
cat /proc/sys/kernel/panic /proc/sys/kernel/panic_on_oops
grep -i -E 'q6v5|smp2p|wcss' /proc/interrupts
```

Check that:
- Which `@CD00000` node is enabled. The carved DTS has both
  `qca,q6v5-wcss-rproc-ipq50xx` and `qcom,ipq5018-wcss-pil`.
- Whether `qca,auto-restart` is on the Q6 and both user PDs in the live tree, as
  in the carved DTS.
- Each subsystem's `restart_level`, and whether ramdumps are on. Don't
  change them for the first series: stock's defaults are what we're measuring.

### 7b: logging

```sh
echo 1 > /sys/module/subsystem_restart/parameters/enable_debug
echo 'file qcom_q6v5_wcss.c +pt' > /sys/kernel/debug/dynamic_debug/control
echo 'file subsystem_restart.c +pt' > /sys/kernel/debug/dynamic_debug/control
grep -E 'q6v5_wcss|subsystem_restart' /sys/kernel/debug/dynamic_debug/control | head
```

Undo both after the phase.

### 7c: crashes

Crash under the conditions that reset our board, not on an idle box:

1. A 5 GHz client (the BCM43455 if possible) joined, stock unit fresh from boot.
2. About 200k small UDP frames to that client from a wired host, the
   `s1-kick.sh` pump. Then ping it to confirm it's alive.
3. Crash the 5 GHz radio (wifi1 / QCN6102) with `cfg80211tool wifi1
   set_fw_hang` (the handler is `ol_ath_set_fw_hang` in `qca_ol.ko`).
4. Wait 60 s, then check both radios, and whether both clients pass traffic
   again.

Run **10 crashes** this way, then 10 on the 2.4 GHz radio (wifi0, the internal
radio, pd-1). Our reset rate from a fresh boot is about 1 in 4. Zero resets
in 5 crashes would happen by chance about a quarter of the time; zero in 10,
about 6%. Reboot between crashes only if the radios didn't come back, and check
the boot flags after every reboot.

Record for every crash:

- **Which PD reports the fatal error.** On our port the QCN6122 assert escalates
  to a root PD crash (`fatal error received` on the root, process name `wlan1`).
  If stock's `set_fw_hang` only crashes a user PD, it doesn't exercise the path
  that resets our board. Then find a root crash trigger.
- **The kernel log sequence, in order.** Root PD vs user PD stop, what gets
  powered down, when the stop and shutdown acks arrive, and the restart level
  used. Compare with phase 0b's order and with our 0823 order.
- **Whether the board resets, and when.** Time from the fatal error to the last
  UART line.
- **Whether both radios come back, and how long it takes.**
- **Whether the other radio's clients stay connected**, and whether stations
  on the crashed radio pass traffic afterwards or stay deaf (packet numbers
  restarting, which our 960 handles).
- **The `q6v5`/`smp2p` interrupt counts** before and after.
- **Whether stock writes anything** to the `crash` / `crash_syslog` partitions,
  or waits for a userspace ramdump collector.

If stock recovers every time, the order from the log (and phase 0b) is what the
respawn fix needs.

## Phase 8: the #18 load test on stock (Q1, Q3) — disruptive

Same shape as the issue: a phone or laptop on 5 GHz, an iperf3 server on the
isolated WAN segment, sustained runs in both directions. Log once a second on
the router:

```sh
while :; do
  date +%s
  grep -E "MemFree|MemAvailable|SUnreclaim|Slab" /proc/meminfo
  cat /proc/sys/dev/nss/n2hcfg/n2h_empty_pool_buf_core0 2>/dev/null
  head -1 /proc/loadavg
  sleep 1
done                     # run it over ssh and redirect on the host, not into /tmp
```

Before and after each run, also save `slabinfo`, `nss-stats`, `wifistats` and
the ECM counts.

The result to compare: does stock's unreclaimable slab stay flat under the load
that grows `SUnreclaim` past 100 MiB on our NSS Wi-Fi image? Compare against the
current NSS Wi-Fi image from `main` (after PR #19), not v1.8. Run the same
client, channel and duration against the test box so the numbers line up, and
compare the growing caches by object count (see phase 2).

## Deliverables

- Raw captures per phase, named `stock-2.0.28-<phase>-<name>.txt`, kept next to
  the offline extraction (not in this repo, since they hold device identifiers).
- The phase 0b disassembly notes: stock's crash-stop order, with function
  offsets.
- A short findings note answering Q1–Q7, with the port-side follow-up for each
  (a sysctl default, NSS profile numbers, the respawn order, the RX pause
  default, the README install warning).
- A teardown check: boot flags, ROM version and runtime settings compared with
  phase 0.
