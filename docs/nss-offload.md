# NSS hardware offload (experimental)

Mainline OpenWrt on the IPQ5018 has **no hardware NAT offload**, so routing is
CPU-bound at roughly **~380 Mbps** (with software flow-offload). The IPQ5018 has
a dedicated network processor — the **NSS** (Network Sub System, a UBI32 core) —
that offloads the routing/NAT fast path and reaches **line rate**. Measured on
this port across a routed + NAT gigabit path: **862 Mbps at ~99 % router-CPU
idle** with the offload engaged, versus ~275 Mbps CPU-bound on the software path.

This is an **opt-in, experimental** build. The default `./build.sh` stays pure
mainline. To build with NSS:

```sh
NSS=1 ./build.sh
```

## What `NSS=1` layers on

`build.sh` overlays `../nss/` onto the tree:

- **Two feeds** (`nss/feeds.conf.append`): [qosmio/nss-packages](https://github.com/qosmio/nss-packages) `NSS-12.5-K6.x` (the `qca-nss-drv`/`ecm`/client packages) and `sqm-scripts-nss`.
- **16 kernel patches** (`nss/overlay/.../patches-6.12/`): ECM netfilter/PPPoE/DSCP support, NSS clients (l2tp/pptp), the `skb_recycler`, the IPQ5018 **NSS reserved-memory** node, and the AN8855 tag_8021q stack (`999-2758..2762`).
- **`ipq5018-nss.dtsi`**: the `nss@40000000` node (core CSM regs, 8 IRQs, 8 MB reserved DDR at `0x40000000`), `#include`d into the device DTS.
- **`kmod-qca-nss-drv kmod-qca-nss-ecm kmod-qca-nss-drv-pppoe nss-firmware-ipq50xx`** added to the device's `DEVICE_PACKAGES`. (**Not** `kmod-qca-nss-drv-bridge-mgr`: it is ipq807x/60xx-only — its init returns early on `qcom,ipq5018` and `nss_bridge.o` isn't even built for this target — yet selecting it drags in a `kmod-bonding` dep that breaks ecm. `build.sh` strips it.)
- **The core-boot fixes** (`nss/feed-patches/qca-nss-drv/0029-…`, `0031-…`) — see below.
- **The tag_8021q + ecm-frontend fix**: `nss/overlay/.../an8855.c` switches the AN8855 DSA tagger, `nss/feed-patches/qca-nss-ecm/0026-…` teaches ECM about DSA conduits, and `CONFIG_NET_DSA_TAG_VSC73XX_8021Q` selects the tagger — see below.
- **The tag_8021q host-FDB VID fix** (`999-2760`, issue #7): host/assisted-learning FDB entries must land in the tag_8021q VID the data path uses, or downstream unicast to a roamed wifi client is same-port-filtered against its stale learned entry (DHCP-after-roam fails). See [`an8855-tag8021q-fdb.md`](an8855-tag8021q-fdb.md).
- **Gateway wiring**: `nss/overlay/.../board.d/02_network` moves the WAN onto the `eth0` CPU port (offload needs WAN and LAN on *different* CPU ports); `.../etc/rc.local` enables `redirect` + `ipv{4,6}_accel_mode` after the modules load.
- **`/etc/modules.d/33-qca-nss-ecm`** so ECM autoloads at boot (loading `ecm` pulls in `qca-nss-drv`, which boots the core); `uci-defaults/00-nss-manual` disables the package init scripts so they don't *also* load the modules.

## The core-boot fix (why this works at all)

The 12.5 `qca-nss-drv` never boots the NSS core on **mainline** 6.12. Its
`__nss_hal_core_reset` only ever *de*-asserts the UBI32 GCC resets — which works
on the downstream QSDK kernel (where the bootloader leaves them **asserted**, so
the de-assert is the start edge). Mainline's clean clk/reset split leaves those
resets **already de-asserted** (register `0x01868010` reads `0x0` at probe), so
the de-assert is a no-op, the core never sees a reset edge, and it free-runs from
a garbage PC — no interrupts, `n2h=0`, empty firmware log, no error.

`0029-ipq50xx-nss-core-boot-reset-pulse.patch` fixes it by **pulsing** the reset
(assert → de-assert) to create a real edge, and — the subtle part — writing the
CSM boot config (`AMC`/`BAR`/`BOOT_ADDR`/`IFETCH`) **after** the de-assert, since
asserting the reset clears those registers. After the fix:

```
qca-nss 7a00000.nss: NSS core 0 booted successfully
```

> **Note:** in the NSS build the fix is not optional. `qca-nss-dp` (the ethernet
> dataplane) can't open the AN8855 switch conduit (`failed to open conduit eth1`)
> unless the core is up — so without the fix, adding `qca-nss-drv` breaks **all
> wired ethernet**, not just offload. With the fix, the core boots, the conduit
> attaches, and wired + offload both work.

Two later findings, both measured on hardware (2026-08):

- **`0031-nss-meminfo-map-block-table-noncacheable`** fixes a *nondeterministic*
  core boot: the vendor feed's patch `0004` deleted the cache flush on the
  meminfo block table (the structure telling the firmware where its rings and
  heap live) without a replacement, so the core read whatever fraction of the
  table had been evicted to DRAM. Measured over 33 cold boots: ~50% booted, ~28%
  coredumped (`nss_fw_coredump_notify()` then *panics the kernel*, producing a
  reboot loop that self-clears when a boot lands well), ~22% never signalled.
  Mapping the table `ioremap_wc` took it to 21/21 clean boots.
- **The exact reset ordering in `0029` decides whether the booted core can
  TRANSMIT.** Holding the core in CSM reset across the whole GCC pulse barely
  moves the boot rate (noise), but with the stock ordering the core boots,
  services N2H (wire→host) perfectly — and silently swallows every H2N
  (host→wire) frame, with zero drop counters anywhere. Nothing at boot time
  distinguishes the two states; only an actual transmit does. Quick
  discriminator on a live box: `ethtool -S eth1 | head -3` — if the first block
  is a small independent counter set (the firmware's per-`phys_if` stats), NSS
  owns the data plane; if `rx_packets` tracks the netdev, it does not.

## The tag_8021q + ecm DSA-conduit fix (why the fast path accelerates)

Booting the core is necessary but not sufficient. The NSS data plane is
**inline**: at core boot the driver hands the GMAC DMA rings to the NSS firmware,
which parses every frame itself. Two things then block acceleration on a DSA
switch like the AN8855:

1. **The DSA tag.** The stock AN8855 driver uses the 4-byte **Mediatek special
   tag** (`DSA_TAG_PROTO_MTK`), which lands exactly where the NSS parser expects
   the EtherType, so every WAN↔LAN frame is exceptioned to the host at L2 before
   the IPv4 fast path (`ipv4_rx_pkts` stays 0). The overlay `an8855.c` switches
   the tagger to the hardware-agnostic **`tag_8021q`** scheme
   (`DSA_TAG_PROTO_VSC73XX_8021Q`) — a plain 802.1Q VID per port that the parser
   passes through. This needs the CPU-port egress tag set to *follow the VLAN
   table* (`PVC_EG_TAG = EG_DISABLED`, not `CONSISTENT`), or the switch can't
   decode the source port. tag_8021q ports must be **bridged** (a single-port
   bridge is fine); a standalone port egresses untagged on the conduit and fails.

2. **ECM doesn't know DSA.** ECM resolves a flow's ingress/egress netdev to an
   NSS interface number, but a DSA user port (`lan3`, `wan`) is not itself an NSS
   interface — its **CPU conduit** (`eth0`/`eth1`) is. Patch `0026` adds a
   front-end helper (`ecm_nss_common_dsa_conduit_get`) that, for a DSA user port
   *or a bridge master over one*, returns the conduit netdev so ECM can build an
   accelerable rule.

With both in place, plus a **dual-CPU-port** topology — LAN on `eth1` (2.5 G),
WAN moved to `eth0` (1 G, via the board.d `conduit` assignment) so the two
directions ride different CPU ports — the WAN↔LAN NAT flow accelerates end to
end (`tcp_accelerated_count` and `ipv4_create_requests` climb, router CPU stays
~99 % idle at line rate).

> **Recovery.** The LAN/management path never depends on the offload, so a
> misbehaving fast path can't lock you out. To back it out entirely:
> `rm /etc/modules.d/33-qca-nss-ecm && reboot` — the box returns to software
> routing.

## How routed frames actually reach the wire (and the PVID-0 pin)

Discovered by release archaeology + register-level injection (2026-08), because
accelerated flows black-holed on any config with a `vlan_filtering=1` bridge:

- **ECM's routed rules carry no VLAN.** `vlan_primary_rule` is populated only
  from `ECM_DB_IFACE_TYPE_VLAN` netdevs; a DSA user port resolves to its bare
  conduit (patch `0026`), so the NSS firmware emits routed frames **untagged**
  on the conduit.
- An untagged frame entering the switch on a CPU port is classified into that
  port's **PVID**. The driver never wrote CPU-port PVIDs, so they sat at the
  hardware default **1**. In the 895 Mbit/s-era configs nothing installed a
  valid VID 1, so untagged CPU ingress fell into the invalid-VID fallback —
  **port-matrix flood** — and was delivered. It worked by accident.
- Once any VLAN-aware bridge installs VID 1 (every modern config here), that
  same frame is confined to VID 1's member set; a routed port living in its own
  bridge is not a member, and the flow black-holes — silently, with the rule
  installed and the CPU ~99% idle.
- **The fix** (in `999-2758`): pin CPU-port PVIDs to **VID 0**, the
  driver-owned, always-valid, all-ports entry. Untagged NSS egress then always
  has a deterministic flood fallback, independent of the user's VLAN config.

**Flood delivery has a real cost:** switch flood replication is gated by the
*slowest member port*. Measured: with a 100 Mb/s device on the LAN, an
accelerated TCP flow managed ~60 Mbit/s (massive retransmits); with that port
out of the flood set, **860 Mbit/s UDP at ~98% idle CPU**. The precise fix —
putting the egress port's tag_8021q VID into the ECM rule so the switch
ARL-forwards instead of flooding — is `nss/feed-patches/qca-nss-ecm/0027-…`.

## Runtime knobs — two traps

- **`/proc/sys/dev/nss/ipv4cfg/ipv4_accel_mode` does NOT stop ECM**, and it is
  one-way at runtime: writing `0` succeeds, writing `1` back returns `-EIO`
  until reboot (`rc.local` re-arms it at boot). Do not use it for A/B tests.
- The effective A/B knob is **`/sys/kernel/debug/ecm/front_end_ipv4_stop`**:
  `1` = ECM stops accelerating new flows (pure CPU slowpath), `0` = normal.
  This is reversible at runtime.
- When experimenting with DSA conduits at runtime, release the port from its
  bridge **in UCI first** (`uci del_list network.@device[0].ports=…` +
  `bridge-vlan`, commit, reload). A bare `ip link set … nomaster` gets undone
  by a netifd hotplug within ~3 s, silently re-bridging the port — which makes
  conduit experiments look broken when they aren't.

## Verifying on the device

After first boot (unattended, from NAND):

```sh
dmesg | grep "booted successfully"                 # core booted
grep nss_queue0 /proc/interrupts                    # interrupts firing (nonzero)
cat /sys/kernel/debug/qca-nss-drv/stats/n2h | grep rx_pkts   # climbing
lsmod | grep -E "qca_nss_drv|qca_nss_dp|^ecm"       # drv + dp + ecm loaded
ls /sys/kernel/debug/ecm/ecm_nss_ipv4               # NSS (hardware) front-end active
cat /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count   # >0 under real routed traffic
cat /sys/kernel/debug/ecm/ecm_nss_ipv4/tcp_accelerated_count # climbs as TCP flows offload
grep ipv4_create_req /sys/kernel/debug/qca-nss-drv/stats/ipv4  # rules pushed to the NSS
```

Under a parallel routed download the aggregate should approach line rate while
the **router** CPU stays near-idle (`grep '^cpu ' /proc/stat` on the router — the
idle field keeps climbing under load). If throughput is capped but CPU is idle
and links are 1 G, the bottleneck is upstream/at the client, not the offload.

## Persistent boot on NAND (the uboot-envtools fix)

Booting the offload image *once* is not the same as booting it *unattended
forever*. The stock miwifi bootloader has a dual-boot failsafe: it tracks a
per-system boot-failure counter (`flag_try_sys*_failed`) and relies on
`flag_boot_success=1` to keep booting the same rootfs. The OS is meant to
re-assert those flags via `fw_setenv` — but this device was **missing from the
uboot-envtools device list**, so `/etc/fw_env.config` was never generated,
`fw_setenv` silently failed, and a sysupgrade could not set the flags. Symptom:
a freshly-sysupgraded image loops in U-Boot (*"Boot failure detected on both
systems"*) even though the identical image RAM-boots fine.

Two fixes (both apply to the base port too, not just NSS):

- **`files/…/uboot-envtools/files/qualcommax_ipq50xx`** adds
  `xiaomi,mi-router-ax3000t-v2` with its env geometry
  (`0:APPSBLENV 0x0 0x10000 0x20000`), so `fw_env.config` is generated and
  `fw_setenv`/`fw_printenv` work.
- **`rc.local`** re-asserts `flag_boot_success=1` and resets the counters on
  every boot, so the failsafe can never trip over time.

Verified across repeated unattended reboots: `/` stays on the NAND `overlay`,
the flags come back armed, and the offload re-engages each boot.

## Caveats

- **Experimental.** This pulls heavy downstream QCA patches onto a mainline
  kernel. It boots and routes, but it hasn't had wide testing.
- **Software vs NSS offload.** ECM and the kernel software flowtable
  (`config defaults` → `flow_offloading`) both hook conntrack and can pre-empt
  each other. If NSS isn't accelerating flows under load, try disabling software
  flow-offload so ECM/NSS owns the fast path.

## Troubleshooting

**The entire LAN (and WAN) is dead — every port logs `failed to open conduit
eth1`/`eth0`, and `ip link set ethX up` returns `Resource temporarily
unavailable` (EAGAIN), while dmesg still says `NSS core 0 booted
successfully`.** That is the signature of a **firmware/driver version
mismatch**, not a switch or DSA problem. `CONFIG_NSS_FIRMWARE_VERSION`
selects *both* the `qca-nss-drv` source tree *and* the firmware blob; the
nss feed branch (`NSS-12.5-K6.x`) targets the 12.5 ABI, but a bare
`make defconfig` resolves the choice to 11.4 (`build.sh` pins it since
36a41ce). With mismatched versions the core boots but never answers phys_if
messages, so every conduit open EAGAINs — silently, with zero drop counters.
Check both sides:

```
dmesg | grep "NSS FW Version"          # what the core is running
grep qca-nss-drv /etc/*_manifest* 2>/dev/null   # or the image .manifest:
#   kmod-qca-nss-drv - <kernel>.12.5.2024...  = 12.5 driver source (good)
#   kmod-qca-nss-drv - <kernel>.11.4.0.5.2021... = 11.4 (mismatched)
```

**Never mix the blob and the driver** (e.g. dropping a 12.5
`qca-nss0-retail.bin` onto an 11.4-driver image): the mismatch *half*-works —
conduits open and LAN-to-LAN hardware forwarding runs — but the firmware
silently eats every CPU-bound TX frame, so the router itself becomes
unreachable over ethernet while everything else looks healthy. It is a
vicious red herring; match the pair.

> The same eats-every-CPU-TX-frame signature also occurs with a **matched**
> pair when the core-boot reset ordering is wrong — measured with 12.5/12.5
> and the stock (un-patched) reset sequence. A matched version pair does not
> clear you; see the `0029` notes above and use the `ethtool -S eth1`
> discriminator.

**Backing the offload out** (always-working slowpath fallback):

```
rm /etc/modules.d/32-qca-nss-drv /etc/modules.d/33-qca-nss-ecm \
   /etc/modules.d/51-qca-nss-drv-pppoe   # keep 31-qca-nss-dp
reboot
```

Removing only `33-qca-nss-ecm` is *not* enough: `qca-nss-drv` alone flips
`nss-dp` onto the NSS data plane, and under a version mismatch that kills the
LAN with no ecm involved. And **never `rmmod qca-nss-drv` on a live system** —
it resets the Q6 remoteproc and crashes the box; remove the autoload files and
reboot instead.

**The initramfs image runs the full NSS stack too.** If the RAM-booted
initramfs has no LAN, suspect the version mismatch above first — it is not an
initramfs quirk.

**Standalone wan port dead after a clean boot** — fixed (`999-2761`, issue #5).
The real root cause was never the conduit or the tag_8021q VLANs: setup
excluded user ports from the BCF/UNUF/UNMF flood masks, and only a bridge
join ever set them — so a standalone port (learning disabled, everything
CPU-bound flood-class under tag_8021q) had a completely dead egress
direction. The old bridge join/leave "heal" worked by accidentally applying
BR_FLOOD; the hotplug workaround has been removed. One residual upstream
behavior to know about: a conduit change makes the port inherit the new
conduit's MAC, so peers with the old MAC cached black-hole replies until
their ARP entry refreshes.
- **Recovery.** Nothing here changes the flash-recovery story — the stock TFTP
  recovery (see the main README) always brings the box back.

## Credits

The NSS packages and the bulk of the qualcommax NSS patchset are
[qosmio/nss-packages](https://github.com/qosmio/nss-packages) and the
`qosmio/openwrt-ipq` work. The IPQ5018 mainline core-boot fix (patch 0029) is
original to this port.
