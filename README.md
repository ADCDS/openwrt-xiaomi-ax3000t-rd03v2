# OpenWrt for Xiaomi AX3000T (RD03v2)

OpenWrt for the **RD03v2 hardware revision** of the Xiaomi AX3000T: Qualcomm IPQ5018 with a
QCN6122 5 GHz radio, 256 MB RAM and 128 MB NAND. It installs permanently on NAND and
supports all four Ethernet ports, both Wi-Fi bands, the status LED, the NFC tag and LuCI,
with Qualcomm NSS hardware offload for routing and Wi-Fi.

**RD03v2 only.** The MediaTek RD03/RD23 revisions use different hardware and incompatible
firmware. Check your hardware revision before flashing.

This is v2 of the port: a pinned release of
[kuncy7/openwrt-nss-edma](https://github.com/kuncy7/openwrt-nss-edma) (kernel 6.18, NSS on
mainline stmmac) with this port's additions on top, and OpenWrt's own snapshot package
feeds. Nothing depends on kuncy7 merging or rebuilding anything: his tree is pinned to a
commit, and our changes are applied on top of it at build time. **Status: released
(v2.0.0).** What was tested on hardware, and what was not, is in
[VALIDATION.md](VALIDATION.md).

## Installation

- **From stock firmware:** use
  [xiaomi-openwrt-install](https://github.com/ADCDS/xiaomi-openwrt-install):
  `python3 install.py`. It installs the latest release over Ethernet or Wi-Fi (with its
  `-wifi` installer pair) **without opening the case or connecting UART**, validates the
  board and NAND, and verifies the images it writes. Its `--wifi-ssid`, `--wifi-key`,
  `--wifi-country` and `--root-password` options set up the installed system. v2 has one
  image, so the installer's `standard` and `nss` selections install the same one;
  `--release v1.14` selects v1.x.
- **From v1.x or another OpenWrt build:** as for any release of this port, boot the v2 RAM
  installer (`…-initramfs-factory.ubi` into `ubi_kernel`, see
  [updating without UART](docs/no-uart-reflash.md)) and run `sysupgrade` with the
  `…-squashfs-sysupgrade.bin` from there; never in place. Keep settings to carry a v1.x
  configuration over: the first boot migrates it ([upgrading from v1.x](#upgrading-from-v1x)).
- **Back to v1.x:** the same RAM-installer route with a v1.x `-nss` image. Restore a v1.x
  configuration backup, not one taken on v2.
- **Back to stock:** `revert.py` from xiaomi-openwrt-install.

## After installing

- Connect to a LAN port and open **http://192.168.1.1** for LuCI. Set a root password.
  Wi-Fi stays off until it is configured, unless the installer was given Wi-Fi settings.
- **Every flash, including updates, runs from the RAM installer.** `sysupgrade` from the
  installed NAND system is refused.
- Packages: `apk update`, then `apk add <package>`. Userspace comes from OpenWrt's snapshot
  feeds; kernel modules (`kmod-*`) and AmneziaWG come from this port's signed repository for
  the release, listed first in `/etc/apk/repositories.d/distfeeds.list`
  ([packages](#packages)). A sysupgrade keeps the configuration, not added packages: add
  them again after an upgrade, and restart the network (`/etc/init.d/network restart`) after
  adding a protocol such as WireGuard or AmneziaWG.
- The first boot clears the NFC tag, which still holds the Wi-Fi name and password stock
  last wrote to it. To share a network by tapping a phone, see [NFC tag](docs/nfc.md).

## What v2 adds to his release

| | How | Source |
|---|---|---|
| His NSS bring-up debug options reverted (serial sysrq, sysrq mask) | tree patch 0001 | his commit `5d86c24df4` asks for it in deployed builds |
| NFC tag: I2C bus, `/usr/sbin/nfc`, its service and config | tree patch 0002, `overlay/.../usr/sbin/nfc`, `etc/init.d/nfc`, `etc/config/nfc` | [docs/nfc.md](docs/nfc.md) |
| Q6 crash-dump policy applied before every ath11k probe: `coredump=disabled` by default, so a root-PD crash restarts the Q6 in seconds instead of waiting 5 min for a dump to be read | tree patch 0004, `overlay/.../rd03v2-q6` (service, config, hotplug, `rd03v2-q6-policy`) | C9 |
| ath11k statistics kept on by default on this board (`qca-nss-pbuf` turned them off after the 2.4 GHz AP started: zero station signal) | tree patch 0005 | C5 |
| Host-mode Wi-Fi: RX filter sizes in bytes (965), peer RX statistics (966) and monitor metadata (967) requested, so host mode receives correctly and reports station signal | `overlay/.../nss-extra/ath11k/999-999-rd03v2-965..967-*` | C4, C5 (host mode) |
| ath11k: in-flight TX frames are reported to mac80211 when the datapath is freed, which ends the "Have pending ack frames!" warning on a driver reload after a Q6 crash (974) | `overlay/.../nss-extra/ath11k/999-999-rd03v2-974-*` | C9 |
| Memory, NSS Wi-Fi offload on this 256 MB board: kuncy7's optional NSS 256 MiB ath11k profile switched on (`CONFIG_ATH11K_NSS_MEM_PROFILE_256M`, his PR #21, off for every board in his releases: no host TX arrays NSS does not use, 4096 TX descriptors and completions per radio, private RXDMA page-frag caches), a private page-frag cache per CE RX pipe (984), and the per-CPU free page lists capped (`vm.percpu_pagelist_high_fraction=100`; 6-18 MB of free pages were parked there, uncounted). MemAvailable idle with both radios up: 42 MB, against 13-21 MB before and 34-35 MB on v1.14-nss | `config/rd03v2.config`, `overlay/.../nss-extra/ath11k/999-999-rd03v2-984-*`, `overlay/.../etc/sysctl.d/13-rd03v2-pcp.conf` | [Memory](VALIDATION.md#memory-b19) |
| ath11k: the channel in use follows a channel switch (985). OpenWrt applies a channel change with a CSA, and ath11k left `rx_channel` on the old channel: `iw survey dump` showed the old channel in use with frozen counters, and the watchdog took that for a stuck radio and reloaded ath11k a few minutes after every channel change | `overlay/.../nss-extra/ath11k/999-999-rd03v2-985-*` | C10 |
| ath11k: a mesh interface under NSS Wi-Fi offload is refused with a message that names the remedy (986). NSS mesh is not built for 256 MB boards; without this the NSS vdev create failed with a bare -22 | `overlay/.../nss-extra/ath11k/999-999-rd03v2-986-*` | #21 |
| ath11k: "pdev N successfully recovered" is logged outside ath11k's shared warning rate limit, which a crash's failed commands often use up; the watchdog's mesh rejoin reads that line (977) | `overlay/.../nss-extra/ath11k/999-999-rd03v2-977-*` | C9 |
| AN8855: room for a second 802.1Q tag in the switch's RX length (0959e). A VLAN on a WAN VLAN (QinQ, `wan.20.30`) is `[20][30]` on the wire, 1526 bytes at MTU 1500; the switch dropped every such frame in both directions, offloaded or not, so QinQ carried no full-size packets | `overlay/target/linux/qualcommax/patches-6.18/0959e-*` | C3 (QinQ) |
| LuCI, full `wpad-mbedtls`, `i2c-tools` (for the NFC tool) in the image. `kmod-tun`, `kmod-inet-diag` and `kmod-nft-tproxy`, in the v1.x image, are in our repository instead (`apk add`) | `config/rd03v2.config` | as v1.x |
| `luci-app-nss` in the image | `config/rd03v2.config` | his package; his image has no LuCI |
| AmneziaWG (kmod, tools, LuCI) in our repository | `build.sh` (feed, `awg_pin`) | as v1.x, #39 |
| ath11k: calibrated survey noise floor (the noise-floor half of 952) | `overlay/.../nss-extra/ath11k/999-999-rd03v2-952-*` | v1.x 952 |
| ath11k: UK 5.8 GHz band (964) | `overlay/.../nss-extra/ath11k/999-999-rd03v2-964-*` | v1.x, #34 |
| smp2p: clear cached inbound bits across a Q6 restart (0918), so `rmmod`/`insmod` and crash recovery can start the Q6 again | `overlay/target/linux/qualcommax/patches-6.18/0918-*` | v1.x 0918, moved into his `wcss_sec_start()` |
| Wi-Fi watchdog, ported to his single `q6wcss` remoteproc, **acting by default** (`dryrun=0`, `reload=1`, `inplace` unset = off: it reloads ath11k rather than resetting one radio). It leaves a root-PD crash to the kernel's respawn (both Wi-Fi modes) and steps in when the radios are not back 120 s later, or the respawn was suppressed. An upgrade from an earlier candidate is migrated to `dryrun=0` | `overlay/.../usr/sbin/rd03v2-watchdog`, `overlay/.../uci-defaults/96-rd03v2-watchdog-defaults` | v1.x, #15 |
| hostapd sends the first 4-way handshake message 8 times (`wpa_pairwise_update_count=8` on every AP interface, once). NSS holds a radio's RX for a few seconds after an in-place recovery; without it 7 of 22 rejoins failed the handshake and backed off 10 s, with it 0 of 22 | `overlay/.../uci-defaults/97-rd03v2-four-way-retries` | v1.x, #25; C9 |
| First-boot Wi-Fi settings apply: both radio sections are written before any other uci-defaults script, as OpenWrt writes them. ath11k loads a minute into the first boot (after the NSS arm), so a first-boot script found no radio to configure: an install from stock with `--wifi-ssid` ended with both radios off | `overlay/.../uci-defaults/01-rd03v2-wireless` | C1 |
| apk pins for the packages he changes without a version bump | `overlay/.../uci-defaults/95-rd03v2-apk-pins` | see [Packages](#packages) |
| Migration of v1.x settings | `overlay/.../uci-defaults/00-rd03v2-migrate-v1x` | see [Upgrading from v1.x](#upgrading-from-v1x) |
| Our signing key, our repository first in `distfeeds.list` | `build.sh`, `keys/` | |

Our ath11k patches go in `patches/nss-extra/ath11k` and sort after all of his there
(`999-999-rd03v2-*`; that directory is applied after `patches/nss`), so each can be dropped on
its own once his tree covers it.
`tools/check-mac80211-series.sh` applies his whole mac80211 series plus ours without fuzz;
OpenWrt itself would accept a fuzzy hunk.

### Already in his tree (not carried)

- ath11k 950, and v1.x's 953, 954, 958 and 959, are in OpenWrt itself now (his 950, 951,
  956, 957 and 958). Our `sta_state` lock fix is his `999-961`.
- PPPoE over a WAN VLAN on the tag_8021q switch (#44) works on his stack as is (C3: 934 Mbit/s
  on `wan.20`, no frames leaked to the LAN), without v1.x's 999-2763/2764 and ECM 0026-0031.
  Not checked on v2: frames injected from the LAN, and trapped EAPOL/STP frames.
- The AN8855 driver, ECM, the NSS data plane, `nss-bufpool`, `board.d`, the boot flags
  (his `/etc/init.d/bootcount`), the caldata hotplug and the 256 MB memory profiles.
- Winbond W25N01KW NAND (v1.x 0413; his 0415), the gpio12 `pwm2` pinctrl function (his
  0306, the patch we sent upstream), the gpio-button-hotplug IRQ fix (now upstream) and this
  board's `uboot-envtools` entry.
- What v2 carried until his ipq50xx-2026.10.15 for crash recovery and boot: tree patches 0003
  (PPPoE re-dial, his `b2b6b3fff8`), 0006 (cfg80211 DFS state, his `238d307610`) and 0007
  (radio retry, his `dff118f852`); ath11k 955, 956, 960-963 and 982 (his `nss-extra` 9960-9966,
  the same code), 980 and 981 (his 977 and 978), 975 and 983 (his 976: user-PD respawn for his
  multi-PD QCN6122, including the restarts the driver asks for), 979 (in backports 7.2) and 973
  (his reworked user-PD stop); the frame-mode guard of #24 (his nss-tools passes `frame_mode=2`
  wherever it loads ath11k, `942926b47d`); and `/etc/board.json` in tmpfs (his wifi-scripts),
  which our former `81_rd03v2_board_json` worked around.
- Board data: the calibration payloads the firmware loads are byte-identical in our v1.x
  `ipq-wifi` files, his tree and his image (both radios; ours only adds an alias without
  the variant), so his files are used as they are (C7).

### Not carried

- **952's rx signal offsets** (+31 dB IPQ5018, +24 dB QCN6122). v1.x measured them with the
  generic IPQ5018 board file and a QCN6122 board file from another device. The board files
  built from this board's own calibration (QCN6122 in v1.2, IPQ5018 in v1.10; the same
  payloads this tree loads, C7) moved the firmware's RSSI up by about as much, so v1.x has
  read 24-31 dB high since (+9..+12 dBm for a client about 1 m away). Without the offsets,
  ath11k's own conversion gives dBm in both Wi-Fi modes, and the station signal and the
  management-frame signal (scan results, the probe, auth and assoc signal hostapd and
  steering daemons see) agree within 2 dB for the same client (C5). A candidate that offset
  the management frames alone (952b) was dropped: it would have put them 24-31 dB above
  the station signal of the same client.
- v1.x's multi-PD remoteproc patches, 951 (smallbuffers), 957, 999-994/995: his tree has its
  own multi-PD support (openwrt/openwrt#25393 for the QCN6122) and memory profiles.

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

Signal readings drop by 31 dB on 2.4 GHz and 24 dB on 5 GHz against v1.x, for stations,
scan results and the probe signal alike: v1.x reads high (see [Not carried](#not-carried)).
Thresholds set against v1.x numbers (`rssi_reject_assoc_rssi`, `rssi_ignore_probe_request`,
usteer or DAWN settings, scripts) need the same amount taken off.

## Known issues

- **On the earlier base, the board reset twice after an in-place Wi-Fi recovery.** On
  kuncy7's `ipq50xx-2026.10.09` (the rc1 builds), 2 of 45 hw-restarts with a station passing
  traffic were followed by a board reset 23-24 s later; the cause was not found. On
  `ipq50xx-2026.10.15-2`, which v2.0.0 is built on and which recovers through his own
  multi-PD respawn, none of about 20 induced crashes with stations attached reset the board
  (VALIDATION, C9). A Q6 firmware crash is rare in normal use; if one resets the board, the
  reboot brings the radios back.
- **A multi-day soak of v2 was not run.** MemAvailable is 42 MB idle with both radios up and
  NSS offload, and stayed at 40 MB through 100 minutes of Wi-Fi traffic both ways; repeated
  client sessions, in-place recoveries and driver reloads did not make it drift (VALIDATION).
- **Signal on 2.4 GHz is checked to about ±10 dB only.** 5 GHz is reciprocal with the test
  client within 3 dB (C5), but the test client's own 2.4 GHz readings jump by about 20 dB
  (its Wi-Fi and Bluetooth share one chip). A small 2.4 GHz correction is neither
  established nor excluded; v1.x's 31 dB is excluded.
- **802.11s mesh needs host Wi-Fi mode.** v2 does not build NSS mesh offload (kuncy7 builds
  it for his std group only; an active mesh costs RAM a 256 MB board cannot spare). With NSS
  Wi-Fi offload on, configuring a mesh interface does not work and takes that radio's AP down
  until the mesh interface is removed; the kernel log says so and names the remedy (patch
  986). Run mesh in host mode (`nss.general.wifi_offload='0'`), where it starts and the AP
  stays up. v1.x's experimental NSS mesh (#21) is not carried.
- `n2h_rx_queue[0]_drops` rise during offloaded PPPoE uploads. That queue is still 256 on
  256 MB boards; his 10-09 release raised it only for 512 MB and 1 GB boards.

## Building

```sh
git clone https://github.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2.git
cd openwrt-xiaomi-ax3000t-rd03v2
TAG=DEV-<name> ./build.sh            # or a release tag; PREPARE_ONLY=1 stops before make
```

- The workspace is this repository plus, next to it: `mirrors/` (his tree and his nss feed,
  never pruned, with reflogs), `keys/v2/` (the signing key), `dl-v2/` (the download cache),
  `ccache-v2/`, `v2-tmp/` (scratch space), `v2-validation/` (the lock that keeps builds and
  bench runs apart), `pages-worktree/` (the `gh-pages` worktree `publish-repo.sh` fills) and
  a checkout of [xiaomi-openwrt-install](https://github.com/ADCDS/xiaomi-openwrt-install)
  (`verify-artifacts.py` uses its image checks). `RD03V2_WS` points elsewhere; each path
  also has its own variable. The build tree defaults to `openwrt-v2/` and release assets to
  `rel-v2-<tag>/`, both inside the repository and ignored by git.
- `upstream.lock`: his release and commit. His CI keeps only three releases and his branches
  get rebased, so the commits a release of ours builds on live in our forks, tagged
  `rd03v2/<his release>`: [ADCDS/openwrt](https://github.com/ADCDS/openwrt) (his tree; the fork
  in his fork network) and [ADCDS/nss-packages](https://github.com/ADCDS/nss-packages) (his nss
  feed). The build reads the local mirrors and fills them from the forks when a pinned commit
  is missing, so a fresh workspace builds from the forks alone.
  `tools/bump-upstream.sh <release>` takes a new release from his repositories, tags its
  commits in the mirrors and, with `PUSH_PINS=1`, pushes the tags to the forks.
- `feeds.lock`: every feed pinned to a commit: the ones his CI built our board group with,
  from the `feeds-256m.buildinfo` it attaches to each release (`tools/freeze-feeds.sh` picks
  them by date for a release without one).
- `tree-patches/`: our changes to his files, applied with `git am` (no fuzz).
- `overlay/`: new files only; the build refuses to overwrite his.
- `config/`: his CI fragments for the 256 MB group are used as they are; ours follow.
- `tools/verify-v2.sh --tree` checks the result; the build fails on any FAIL.

## Other documents

- [VALIDATION.md](VALIDATION.md): what was tested on hardware, and what was not
- [NFC tag](docs/nfc.md)
- [Updating without UART](docs/no-uart-reflash.md)
- [UK 5.8 GHz channels and the firmware's regulatory database](docs/regulatory-gb-5ghz.md)

## v1.x

The v1.x releases (OpenWrt kernel 6.12 with qosmio's NSS stack, v1.0 to v1.14) are on branch
`v1`. That line is no longer developed.

| | v1.x (branch `v1`) | v2 |
|---|---|---|
| Kernel | 6.12 | 6.18 (his release) |
| NSS | qosmio's stack, 12.5 firmware, maintained here | his stack on mainline stmmac, 12.5 firmware |
| Userspace packages | built here from a pinned OpenWrt snapshot; drifts from OpenWrt's feeds | OpenWrt's snapshot feeds, like his images |
| Kernel modules | release archive | our package repository for each release (`v2/<tag>/`) |
| Wi-Fi | NSS offload or host | NSS offload (default) or host; host mode is fixed here (965-967, tree patch 0005) |

## Credits and contributing

Thanks to [kuncy7](https://github.com/kuncy7) for openwrt-nss-edma and its NSS stack for
IPQ50xx, which v2 is built on;
[csharper2005](https://github.com/csharper2005/openwrt) for the AN8855 integration and base
device tree; Min Yao / Airoha and Christian Marangi for the driver work; thmalmeida, Edrikk
and the
[OpenWrt forum contributors](https://forum.openwrt.org/t/adding-support-for-xiaomi-ax3000t-rd03v2/235136)
for the hardware and recovery groundwork; and
[Ziyang Huang](https://github.com/hzyitc) for ath11k smallbuffers support.

Contributions are welcome, especially help upstreaming the port to OpenWrt.
Licensed under [GPL-2.0-only](LICENSE); patches retain their original attribution.
