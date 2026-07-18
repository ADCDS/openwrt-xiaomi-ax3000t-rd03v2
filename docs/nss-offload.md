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
- **~11 kernel patches** (`nss/overlay/.../patches-6.12/`): ECM netfilter/PPPoE/DSCP support, NSS clients (l2tp/pptp/bridge-mgr), the `skb_recycler`, and the IPQ5018 **NSS reserved-memory** node.
- **`ipq5018-nss.dtsi`**: the `nss@40000000` node (core CSM regs, 8 IRQs, 8 MB reserved DDR at `0x40000000`), `#include`d into the device DTS.
- **`kmod-qca-nss-drv kmod-qca-nss-ecm kmod-qca-nss-drv-bridge-mgr nss-firmware-ipq50xx`** added to the device's `DEVICE_PACKAGES`.
- **The core-boot fix** (`nss/feed-patches/qca-nss-drv/0029-…`) — see below.
- **The tag_8021q + ecm-frontend fix**: `nss/overlay/.../an8855.c` switches the AN8855 DSA tagger, `nss/feed-patches/qca-nss-ecm/0026-…` teaches ECM about DSA conduits, and `CONFIG_NET_DSA_TAG_VSC73XX_8021Q` selects the tagger — see below.
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

**Standalone wan port dead after a clean boot** (no CPU traffic in or out of
the `wan` interface, LAN fine, slowpath and NSS alike): known driver-ordering
bug — DSA programs the tag_8021q VLANs against the default conduit before
netifd moves `wan` to `eth0`. The overlay ships a hotplug workaround that
cycles the port through a bridge join/leave once per boot; see the tracking
issue for the proper `port_change_conduit` fix.
- **Recovery.** Nothing here changes the flash-recovery story — the stock TFTP
  recovery (see the main README) always brings the box back.

## Credits

The NSS packages and the bulk of the qualcommax NSS patchset are
[qosmio/nss-packages](https://github.com/qosmio/nss-packages) and the
`qosmio/openwrt-ipq` work. The IPQ5018 mainline core-boot fix (patch 0029) is
original to this port.
