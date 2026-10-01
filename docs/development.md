# Build and technical reference

[Back to README](../README.md)

## Building from source

```bash
git clone <this repo> && cd openwrt-xiaomi-ax3000t-rd03v2
./build.sh            # clones OpenWrt @ 25ee126, applies files/, builds
NSS=1 ./build.sh      # ...plus experimental QCA NSS hardware offload (measured: 940 Mbit/s NAT at ~0% CPU)
KMODS=1 ./build.sh    # ...plus every kernel module as an installable package (slow; used for releases)
```

`KMODS=1` builds ~1100 modules as packages rather than installing them, which is what produces the
release `kmods.tar.gz`. It leaves the image's package set alone but **does change the kernel
vermagic**, so modules only install on an image from the same run — release images are therefore
built with it too. Expect a multi-hour build; without it you get a normal image in normal time.
Or manually: check out OpenWrt at `25ee126`, copy `files/*` over it, pin each feed in `feeds.conf.default` to its revision in [`feeds.lock`](../feeds.lock) (`src-git <name> <url>^<commit>`), `./scripts/feeds update -a && ./scripts/feeds install -a`, seed `.config` with the device + `CONFIG_TARGET_ROOTFS_INITRAMFS=y`, then `make defconfig && make -j$(nproc)`. Images land in `bin/targets/qualcommax/ipq50xx/`.

**NSS hardware offload** (`NSS=1`, opt-in) boots the IPQ5018's NSS network
processor to offload NAT routing at line rate. Measured LAN→WAN NAT over a
gigabit wire. The offload figures below are from the **current tree**, taken
after the ECM egress fix (`5a89896`) landed; the earlier `999-2758` tree
measured 895 TCP / 860 UDP on the same path:

| Path | NAT throughput | Router CPU under load |
|---|---|---|
| CPU slowpath | 619 Mbit/s | 95% sirq (saturated) |
| **NSS offload** | **940 Mbit/s** TCP / **898 Mbit/s** UDP | **~0% sirq, ~95-98% idle** |

Routed frames are delivered ARL-precise (the ECM rule carries the egress
tag_8021q VID — measured 940 Mbit/s TCP at ~99% idle with a 100 Mb/s device
on the LAN); flows the rule cannot tag fall back to a flood path gated by
the slowest LAN port. See "How routed frames actually reach the wire" in
[`docs/nss-offload.md`](nss-offload.md).

(LAN⇄LAN traffic between switch ports is forwarded by the AN8855 fabric at
line rate — ~890 Mbit/s measured — with or without NSS; the offload matters
for *routed* traffic. Verify offload is engaged by watching `top` during
load: near-idle sirq = NSS carrying the flow.) It's experimental and layers
heavy QCA feeds/patches on top of mainline — see
[`docs/nss-offload.md`](nss-offload.md).

See [`MANIFEST.txt`](../MANIFEST.txt) for every file and what it does.

---

## How it works (the interesting bits)

**The 2.5 G switch.** The AN8855 hangs off GMAC1 over a 2.5 G SerDes link with no PHY — which made `qca-nss-dp` abort probe (`swphy: unknown speed`). csharper2005's driver + nss-dp patch fix the phy-less 2500 CPU port; the switch then comes up as a normal DSA switch (`lan2/lan3/lan4/wan`).

**Making the locked bootloader boot OpenWrt.** Xiaomi's U-Boot boots by an A/B "try/fail" flag scheme and loads the kernel from a specific UBI volume. A naive `sysupgrade` fails (`Can't open device for writing`) and even a successful write wouldn't boot (the bootloader keeps loading the stock kernel). The fix is the `platform.sh` case for our board: it sets `CI_KERN_UBIPART`/`CI_ROOT_UBIPART`, and writes `fw_setenv` boot-flags (`flag_try_sys{1,2}_failed=8`, `flag_boot_rootfs=0`, `uart_en=1`, `boot_wait=on`) that force the bootloader onto our slot — mirroring the proven `xiaomi_ax6000`/`redmi-ax5400` path.

**The WiFi crash and native board data.** OpenWrt ships ath11k firmware `WLAN.HK.2.7.0.1`, while Xiaomi's stock `bdwlan` files target `2.5.r4`; passing the old format unchanged crashes Q6 (`phyrf_bdf.c … ANTENNACHAIN_AXIS_Z … zero`). Both radios now use native 2.7-layout files derived from this model's stock calibration: the QCN6122 conversion contributed in #6, and an auditable IPQ5018 conversion that changes only the common schema byte plus checksum. The earlier generic IPQ5018 entry booted but had a real channel-dependent receive-gain defect on channels 6/11. See [`docs/ipq5018-native-bdf.md`](ipq5018-native-bdf.md) for the packet-level A/B, generator and hashes. Per-unit calibration still comes from the board's own `0:ART` partition at runtime.

**RSSI reporting and the separate IPQ5018 receive defect (issue #3).** Patch `952` still fixes the firmware's uncalibrated reporting scale and noise floor. That reporting bug had obscured a second, real problem in the generic IPQ5018 BDF: a matched packet capture showed clean channel-1 exchanges but severe bidirectional retry bursts on channels 6/11 at the same independently measured signal. The native BDF fixes the effective gain (about −65 → −35 dBm for the test client) and packet loss. Cold-boot calibration is unrelated; toggling it did not change the failure.

**Bridge VLAN filtering under `tag_8021q` (NSS build).** The NSS build swaps the Airoha special tag for DSA's `tag_8021q` (the NSS datapath cannot parse the 4-byte special tag, so it exceptions every routed frame to the host), which means the CPU link carries a plain 802.1Q header whose VID encodes the source port. That collides head-on with a VLAN-aware bridge, which wants the same VID space and the same per-port PVID register. Up to v1.4 the driver lost that collision badly: the inherited mt7530 `.port_vlan_filtering` forced the **CPU** port to `EG_CONSISTENT` ("untagged in, untagged out"), so the conduit received frames with no VLAN header at all, the tagger had no VID to demux, and the host RX path died for every user port on that CPU port — while TX kept working, so the box stayed visible in the upstream router's FDB while being unreachable. A config revert didn't recover it; only a reboot did. The fix (`999-2762`) follows the mainline sja1105/vsc73xx model: CPU-port egress tagging is owned by `an8855_setup()` alone, and the two writers of the PVID register — `tag_8021q` and the bridge — keep **shadow PVIDs** that a single `commit` function arbitrates on the port's VLAN-awareness. Bridge VLANs in 3072–4095 are now rejected instead of silently corrupting the `tag_8021q` table. See [`docs/an8855-vlan-filtering.md`](an8855-vlan-filtering.md).

**Memory (256 MB, and the smallbuffers fix).** After the SoC reserves ~66 MB for the WiFi co-processor and bootloader, Linux sees **175 MB** (`MemTotal: 175760 kB`) — and by default the two ath11k radios hold ~85–90 MB of *unswappable* kernel memory (DMA ring buffers + firmware host memory). That left only ~15 MB free, and under load the kernel OOM-killer would shoot `hostapd`/`netifd`, dropping WiFi. The fix is **`kmod-ath11k-smallbuffers`** — Ziyang Huang's [PR #21495](https://github.com/openwrt/openwrt/pull/21495), which shrinks ath11k's DP ring buffers (TX-completion 32768→2048, RX-DMA 4096→1024, monitor rings down to 128–512), mirroring the long-standing `ath10k-smallbuffers`. It cuts the ath11k footprint from ~85 MB to **~38 MB** (PR #21495's figures; the before-state was not re-measured on this board). Measured here on a v1.7 NSS build serving as an AP with both radios up and 6 clients: **~45 MB `MemFree`, ~33 MB `MemAvailable`** after a week of uptime — most of the ~65 MB Slab is unreclaimable, so `MemAvailable` is the honest figure. Not roomy, but stable. Tested: a 70 MB memory-pressure spike (far beyond any real load) produces **zero OOM kills** with both radios up — on real RAM alone, no swap needed. Trade-off: smaller buffers mean less headroom at extreme throughput, and monitor-mode capture is degraded. The first one does bite occasionally — the same AP logged one burst of ten `ath11k: failed to transmit frame -28` (ENOSPC on the shrunken TX ring) over that week, with no user-visible effect. It remains the right trade for a low-RAM device, but it is a real cost, not a free win.

**v1.9 adds ~6 MB back.** Live inspection of a stock RD03v2 (ROM 2.0.28) showed stock hands the NSS
only 4096 host-side buffers where the NSS memory profile defaults to 8704. Those are empty skbs pinned
in Linux slab as `SUnreclaim`, so halving them is a straight return: measured boot-to-boot on the bench,
same image, idle, `SUnreclaim` **44,576 → 38,204 / 38,144 kB** across two boots and `MemAvailable` **37,088 → ~42,800 kB**. It ships
as `/etc/init.d/nss-bufpool` (NSS builds only in effect — on a plain build the sysctl tree does not exist
and the script is a no-op). See [`stock-investigation/`](../stock-investigation/) for the full comparison, and
Verified under load: with the NSS fast path genuinely accelerating (`ipv4_create_requests` climbing, 940 Mbit/s line rate on the 1 G WAN port), ~9 GB of NAT'd traffic left `n2h_payload_alloc_fails` untouched, and a control run at the old 8704 was 1 Mbit/s apart while costing 6.4 MB more. Note what v1.9 deliberately does **not** take from stock: `extra_pbuf_core0`, which *costs* ~784 kB of host
memory and whose allocator can `BUG_ON` at boot on a fragmented buddy list — a reboot loop on a board with
`panic_on_oops=1`. The ~66 MB of carve-outs, by contrast, are not the problem: stock reserves 65 MB.

**…but v1.9 also capped NSS at 4096 buffers (fixed after v1.10).** The pool write also sets the NSS
*high water mark*, the most buffers NSS may hold, to the pool size, and v1.9 and v1.10 left it there.
Stock sets its high water separately (16336), and was holding 10,557 buffers when captured. NSS Wi-Fi
offload, new in the same release, needs more than 4096 under load: both radios' Rx rings, the Ethernet
Rx ring and the Wi-Fi Tx queues all draw on them. A slow Wi-Fi client could drain them and freeze a
radio for seconds (issue #18). `nss-bufpool` now raises the high water mark back to 8704 after the pool
write. The idle saving stays, because it comes from the pool and the low water mark (4096/2048).
On the bench, idle `MemAvailable` was 28.4 MB, against 29.0 MB with the hard cap, on a fresh boot. Once
the wired port has carried traffic, NSS keeps ~1,400 more buffers, about 4.5 MB, which the hard cap had
been denying it. Reverting the pool to 8704 instead would have cost ~7 MB more for the same result.

---

## Known limitations

- **Front LED fade is software-timed** (`pwm-gpio` hrtimer soft-PWM at 200 Hz feeding `pwm-leds` — full 0–255 brightness and `pattern`/breathing triggers, zero cost in steady on/off states). True hardware PWM on these pins is impossible: the IPQ5018 TLMM has no PWM function on GPIO 12/13 (mainline and downstream QSDK pinctrl agree — `pwm2`/`pwm3` only reach GPIO 44/45), so stock's fade was software too.
- **NSS build: no DSA source-port precision under a VLAN-aware bridge.** With `vlan_filtering '1'`, frames reach software carrying the bridge VID rather than a `tag_8021q` VID, so DSA resolves the ingress port imprecisely (`dsa_find_designated_bridge_port_by_vid()`) and the software bridge sorts it out. This is the documented tradeoff for this class of driver in `net/dsa/tag_8021q.c`, not a shortcut here — hardware forwarding between user ports is unaffected. The default (non-NSS) build keeps full precision, because the MTK special tag carries the source port independently of the VLAN table.
- **The buttons need a backported `gpio-button-hotplug` fix** (`files/package/kernel/gpio-button-hotplug/patches/100-*.patch`). `struct gpio_keys_button::irq` is `unsigned int`, so the driver's `if (button->irq < 0) button->irq = 0;` clamp was dead code — harmless while `fwnode_irq_get()` returned 0 for a node with no `interrupts` property, but it now returns `-EINVAL`, which lands in the unsigned field as a huge positive number. The probe then treats it as a firmware-supplied interrupt, skips `gpiod_to_irq()`, drops the trigger flags and requests a nonsense IRQ, so both buttons stay dead (`failed to request irq:0 for gpio:-2`). **OpenWrt fixed this upstream in [`b0a03893cb52`](https://github.com/openwrt/openwrt/commit/b0a03893cb520c64dff89a7b83f6512aab86c15c) (2026-07-10); this port pins `25ee126` (2026-07-06), four days earlier**, so the fix is backported here and should be **dropped once the pin advances** ([#10](https://github.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2/issues/10)). Note the **mesh** button is `KEY_WPS_BUTTON` (→ `/etc/rc.button/wps`), not a second reset: `gpio-button-hotplug` picks the handler from the key code, not the DT label, so giving both buttons `KEY_RESTART` would make the mesh button factory-reset the router.
- This is a snapshot build; treat as beta.

## Credits

This port stands on the shoulders of prior work:

- **[csharper2005](https://github.com/csharper2005/openwrt)** — brought the **Airoha AN8855 DSA driver** to this target (the driver is Min Yao / Airoha's, with Christian Marangi's netdev submission), wrote the **base device tree**, and fixed **phy-less-2500 in `qca-nss-dp`**. Without that work the 2.5 GbE switch — the hard part of this SoC — wouldn't come up at all; the DTS and the driver integration here are theirs, carried from the `an8855h` branch.
- **[thmalmeida](https://forum.openwrt.org/t/adding-support-for-xiaomi-ax3000t-rd03v2/235136/28)** and the OpenWrt-forum thread **[“Adding support for Xiaomi AX3000T (RD03v2)”](https://forum.openwrt.org/t/adding-support-for-xiaomi-ax3000t-rd03v2/235136)** — the board teardown and the annotated UART/chip photo used in the [UART guide](installation-and-usage.md) (post 28). The earlier legwork in that thread is largely **Edrikk**'s — the serial/boot logs and the UART-readonly + TFTP-recovery procedure (posts 7/9/14) that step 2 of the UART guide descends from — with stamandr, alexq and anon63541380 filling in the hardware picture.
- **[Ziyang Huang (hzyitc)](https://github.com/hzyitc)** — the **ath11k “smallbuffers” low-memory support** ([OpenWrt PR #21495](https://github.com/openwrt/openwrt/pull/21495)), which halves ath11k's RAM footprint and is what lets both radios run comfortably on this 256 MB board. Carried here as a patch under `files/` with authorship preserved.
- **[OpenWrt](https://openwrt.org/)** — the `qualcommax/ipq50xx` target and everything underneath.

**What this repo adds on top** (the pieces that were missing to make it a *usable, installable* router):
1. **NAND install + boot integration** — wiring the device into `platform.sh` so `sysupgrade` actually writes to flash *and* sets the U-Boot boot-flags that make the stock bootloader boot OpenWrt instead of stock.
2. **The WiFi fix** — the ath11k firmware↔board-data version match that stops the Q6 co-processor crashing (both radios).
3. Per-board caldata extraction, the 2.4 GHz radio enablement, and this end-to-end install guide.

The goal is to feed this **upstream to OpenWrt**. If you can help clean it up for a PR, please do.

## License

**GPL-2.0-only** — full text in [`LICENSE`](../LICENSE).

This is not really a free choice: the kernel, driver and package patches under
`files/` and `nss/` are derivative works of GPL-2.0 code, and it matches OpenWrt
and the Linux kernel, which everything here is built against. The build scripts,
`tools/`, and the documentation are original to this repo and are offered under
the same terms.

Individual patches keep their original authors' copyright and `Signed-off-by`
lines, and the patch headers are the authoritative record of who wrote what — in
particular the **AN8855 DSA driver** (Min Yao / Airoha, with Christian Marangi's
netdev submission, carried here via csharper2005), the **base device tree**
(csharper2005), and the **ath11k smallbuffers** patch (Ziyang Huang). See
[Credits](#credits).

Experimental NSS Wi-Fi offload and local wired-to-5GHz measurements are documented in [docs/nss-wifi-validation.md](nss-wifi-validation.md).
