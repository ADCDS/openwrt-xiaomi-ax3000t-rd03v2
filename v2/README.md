# RD03v2 v2: kuncy7's NSS tree plus this port's extras

**Status: in development, not released.** Nothing here is published yet.

v2 builds the Xiaomi AX3000T v2 (RD03v2) image from a pinned release of
[kuncy7/openwrt-nss-edma](https://github.com/kuncy7/openwrt-nss-edma) instead of this
repository's own OpenWrt tree. On top of that release it adds what v1.x has and his tree does
not. Nothing depends on kuncy7 merging or rebuilding anything: his tree is pinned to a
commit, and our changes are applied on top of it at build time.

| | v1.x (`main`) | v2 |
|---|---|---|
| Kernel | 6.12 | 6.18 (his release) |
| NSS | qosmio's stack, 12.5 firmware, maintained here | his stack on mainline stmmac, 12.2 firmware |
| Userspace packages | built here from a 2025 snapshot; drifts from OpenWrt's feeds | OpenWrt's snapshot feeds, like his images |
| Kernel modules | release archive | our package repository for each release (`v2/<tag>/`) |
| Wi-Fi | NSS offload or host | NSS offload (host mode is broken on his tree, see below) |

## What v2 adds to his release

| | How | Source |
|---|---|---|
| His NSS bring-up debug options reverted (serial sysrq, sysrq mask) | tree patch 0001 | his commit `5d86c24df4` asks for it in deployed builds |
| NFC tag: I2C bus, `/usr/sbin/nfc`, its service and config | tree patch 0002, `shared.list` | [docs/nfc.md](../docs/nfc.md) |
| Every PPPoE session made again once the NSS PPPoE manager is resident, not only the default-route WAN's (otherwise a second PPPoE WAN stays on the host path after every boot) | tree patch 0003 | gate soak, 2026-10-10 |
| LuCI, full `wpad-mbedtls`, `i2c-tools`, `kmod-tun`/`-inet-diag`/`-nft-tproxy` | `config/rd03v2.config` | as v1.x |
| `luci-app-nss` in the image | `config/rd03v2.config` | his package; his image has no LuCI |
| AmneziaWG (kmod, tools, LuCI) in our repository | `build.sh` (feed, `awg_pin`) | as v1.x, #39 |
| ath11k: calibrated survey noise floor (the noise-floor half of 952) | `overlay/.../nss/ath11k/999-999-rd03v2-952-*` | v1.x 952 |
| ath11k: crash-recovery fixes 955, 956, 960, 961, 962, 963 | `overlay/.../nss/ath11k/999-999-rd03v2-9xx-*` | v1.x, #15 |
| ath11k: UK 5.8 GHz band (964) | `overlay/.../nss/ath11k/999-999-rd03v2-964-*` | v1.x, #34 |
| smp2p: clear cached inbound bits across a Q6 restart (0918), so `rmmod`/`insmod` and crash recovery can start the Q6 again | `overlay/target/linux/qualcommax/patches-6.18/0918-*` | v1.x 0918, moved into his `wcss_sec_start()` |
| Wi-Fi watchdog, ported to his single `q6wcss` remoteproc, **dry-run by default** | `overlay/.../usr/sbin/rd03v2-watchdog` | v1.x, #15 |
| apk pins for the packages he changes without a version bump | `overlay/.../uci-defaults/95-rd03v2-apk-pins` | see [Packages](#packages) |
| Migration of v1.x settings | `overlay/.../uci-defaults/00-rd03v2-migrate-v1x` | see [Upgrading from v1.x](#upgrading-from-v1x) |
| Our signing key, our repository first in `distfeeds.list` | `build.sh`, `keys/` | |

Our ath11k patches sort after all of his (`999-999-rd03v2-*` in the NSS directory, which is
applied last), so each can be dropped on its own once his tree covers it.
`tools/check-mac80211-series.sh` applies his whole mac80211 series plus ours without fuzz;
OpenWrt itself would accept a fuzzy hunk.

### Already in his tree (not carried)

- ath11k 950, and v1.x's 953, 954, 958 and 959, are in OpenWrt itself now (his 950, 951,
  956, 957 and 958). Our `sta_state` lock fix is his `999-961`.
- PPPoE over a WAN VLAN on the tag_8021q switch (#44) works on his stack as is in the gate
  (933/930 Mbit/s on `wan.20`, no frames leaked to the LAN), without v1.x's 999-2763/2764 and
  ECM 0026-0031. The other checks from our #44 review (frame injection from the LAN,
  trapped EAPOL/STP frames) have not run on his image yet (phase A5).
- The AN8855 driver, ECM, the NSS data plane, `nss-bufpool`, `board.d`, the boot flags
  (his `/etc/init.d/bootcount`), the caldata hotplug and the 256 MB memory profiles.
- Winbond W25N01KW NAND (v1.x 0413; his 0415), the gpio12 `pwm2` pinctrl function (his
  0306, the patch we sent upstream), the gpio-button-hotplug IRQ fix (now upstream) and this
  board's `uboot-envtools` entry.
- Still open: our board data files (v1.x `ipq-wifi`) against his, decided by the phase C
  A/B test (C7).

### Not carried

- **952's rx signal offset** (+31 dB IPQ5018, +24 dB QCN6122). With NSS Wi-Fi offload the
  station signal is already in dBm (gate: AP -47 vs client -49 dBm on 5 GHz, -34 vs -26 on
  2.4 GHz); v1.14-nss, which adds the offset, reads +1..+11 dBm. Management frames (scan
  results, the probe request signal hostapd and steering daemons see) come from a WMI event
  on the same firmware, which v1.x measured 31 dB low: `candidates/…-952b-…` compensates
  only those. It joins the overlay if phase C (C5) shows the same on this tree.
- v1.x's multi-PD remoteproc patches, 951 (smallbuffers), 957, 999-994/995: his tree has its
  own driver and memory profiles.

## Packages

The image lists our repository first, then OpenWrt's snapshot feeds `base`, `luci`,
`packages`, `routing`, `telephony` and `video`. The official kmods feed is left out, because
its kernel is not ours. Kernel modules come from our repository, which is built with the
image and signed with our key. A kmod installs only on the image of the same build, since
it depends on `kernel=<version>~<vermagic>` exactly.

Userspace comes from OpenWrt's snapshot feeds and drifts with them. That is the point: it
is maintained there. The exception is the packages his tree changes without a version
change. An `apk upgrade` would replace them with OpenWrt's builds and drop his changes, so
the first boot pins them in `/etc/apk/world`, and our repository carries those exact
versions:

| Package | His change |
|---|---|
| `netifd` | a dotted name that already exists is used as a plain device (DSA tag_8021q) |
| `wifi-scripts` | Wi-Fi setup does not fail while ath11k has no PHY yet |
| `tc-full` | tc for the NSS qdiscs and `nssmirred` (SQM in the NSS firmware) |
| `dnsmasq` | no signal to an instance a reload has just restarted |
| `uboot-envtools` | this board's U-Boot environment |
| `ath11k-firmware-ipq5018-qcn6122`, `ipq-wifi-xiaomi_mi-router-ax3000t-v2` | Wi-Fi firmware layout and board data |

`apk add <name>` with the plain name lifts a pin.

## Upgrading from v1.x

A sysupgrade that keeps settings carries v1.x files that do not fit his stack. On the first
boot, `00-rd03v2-migrate-v1x` runs before every other first-boot script:

- It defuses v1.x's `/etc/uci-defaults/10_disable_services`, which v1.x `-nss` config
  backups carry. That script disables `qca-nss-ecm`, which loads ECM on his stack.
- It unsets `nss.general.topology`, so his `99-nss-topology` sets up the NSS plane as on a
  fresh install. The other `nss` options are the same on both.
- It removes `options ecm front_end_selection=0` from `/etc/modules.conf`.
- It removes the boot-flag and NSS-knob blocks from `/etc/rc.local` when they are unchanged.

It then sets `rd03v2.v2.migrated`, so later v2 upgrades skip it. The radio paths
(`platform/soc@0/c000000.wifi`, `.../b00a040.wifi`) and port names are the same in both trees.

## Known issues (phase A gate, 2026-10-10)

- Fixed in v2 by tree patch 0003; affects his release: a PPPoE session that does not hold
  the default route (mwan3, a backup line, PPPoE next to a DHCP uplink) is never offloaded
  after a boot. It connects before the NSS PPPoE manager loads, and his re-dial only covers
  `network_find_wan`. Measured: 80/93 Mbit/s with 13k retransmissions, then 200/200 after
  `ifup` of that interface.

- **Host-mode Wi-Fi is broken on his tree** (`nss.general.wifi_offload=0`): "invalid msdu
  len" and PSK mismatches. Offload mode works (5 GHz 254/341 Mbit/s, 2.4 GHz 12/32,
  downloads intact).
- **Less free memory:** MemAvailable is 17-24 MB with both radios up, against 33-35 MB on
  v1.14-nss. The 24 h soak decides whether that is stable.
- `n2h_rx_queue[0]_drops` rise during offloaded PPPoE uploads. That queue is still 256 on
  256 MB boards; his 10-09 release raised it only for 512 MB and 1 GB boards.
- A v2→v2 upgrade that keeps settings skips his `99-nss-topology`, because the topology is
  already set, so `qca-nss-drv`'s init script stays enabled. His own comment says its IRQ
  writes just fail on this SoC. To check in phase C (C1b).

## Building

```
TAG=DEV-<name> v2/build.sh            # or a release tag; PREPARE_ONLY=1 stops before make
```

- `upstream.lock`: his release and commit, built from a local mirror (his CI keeps only
  three releases, and his branches get rebased).
- `feeds.lock`: every feed pinned to a commit. `tools/freeze-feeds.sh` picks the commits as
  of his release time.
- `tree-patches/`: our changes to his files, applied with `git am` (no fuzz).
- `overlay/` and `shared.list`: new files only; the build refuses to overwrite his.
- `config/`: his CI fragments for the 256 MB group are used as they are; ours follow.
- `tools/verify-v2.sh --tree` checks the result; the build fails on any FAIL.
