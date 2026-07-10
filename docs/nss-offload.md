# NSS hardware offload (experimental)

Mainline OpenWrt on the IPQ5018 has **no hardware NAT offload**, so routing is
CPU-bound at roughly **~380 Mbps** (with software flow-offload). The IPQ5018 has
a dedicated network processor — the **NSS** (Network Sub System, a UBI32 core) —
that can offload the routing/NAT fast path and reach **line rate (~900 Mbps)**.

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
- **`/etc/modules.d/33-qca-nss-ecm`** so ECM autoloads at boot.

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

## Verifying on the device

After first boot (unattended, from NAND):

```sh
dmesg | grep "booted successfully"                 # core booted
grep nss_queue0 /proc/interrupts                    # interrupts firing (nonzero)
cat /sys/kernel/debug/qca-nss-drv/stats/n2h | grep rx_pkts   # climbing
lsmod | grep -E "qca_nss_drv|qca_nss_dp|^ecm"       # drv + dp + ecm loaded
ls /sys/kernel/debug/ecm/ecm_nss_ipv4               # NSS (hardware) front-end active
cat /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count   # >0 under real routed traffic
```

## Caveats

- **Experimental.** This pulls heavy downstream QCA patches onto a mainline
  kernel. It boots and routes, but it hasn't had wide testing.
- **Software vs NSS offload.** ECM and the kernel software flowtable
  (`config defaults` → `flow_offloading`) both hook conntrack and can pre-empt
  each other. If NSS isn't accelerating flows under load, try disabling software
  flow-offload so ECM/NSS owns the fast path.
- **Recovery.** Nothing here changes the flash-recovery story — the stock TFTP
  recovery (see the main README) always brings the box back.

## Credits

The NSS packages and the bulk of the qualcommax NSS patchset are
[qosmio/nss-packages](https://github.com/qosmio/nss-packages) and the
`qosmio/openwrt-ipq` work. The IPQ5018 mainline core-boot fix (patch 0029) is
original to this port.
