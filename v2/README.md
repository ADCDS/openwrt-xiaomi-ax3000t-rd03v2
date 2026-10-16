# RD03v2 v2: kuncy7's NSS tree plus this port's extras

**Status: release candidate, not published.** What was tested on hardware, and what was
not, is in [VALIDATION.md](VALIDATION.md).

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
| Wi-Fi | NSS offload or host | NSS offload (default) or host; host mode is fixed here (965-967, tree patch 0005) |

## What v2 adds to his release

| | How | Source |
|---|---|---|
| His NSS bring-up debug options reverted (serial sysrq, sysrq mask) | tree patch 0001 | his commit `5d86c24df4` asks for it in deployed builds |
| NFC tag: I2C bus, `/usr/sbin/nfc`, its service and config | tree patch 0002, `shared.list` | [docs/nfc.md](../docs/nfc.md) |
| Every PPPoE session made again once the NSS PPPoE manager is resident, not only the default-route WAN's (otherwise a second PPPoE WAN stays on the host path after every boot) | tree patch 0003 | gate soak, 2026-10-10; kuncy7/openwrt-nss-edma#25 |
| cfg80211 keeps the DFS state of the channels when ath11k applies its domain again after a firmware restart. Without it an AP on a DFS channel (52-144, or 36 at 160 MHz) lost its carrier and channel 60 s after every in-place recovery, with hostapd still reporting it enabled | tree patch 0006 | kuncy7 238d307610 (10.15-2), kuncy7/openwrt-nss-edma#28 |
| A radio that netifd gave up on while ath11k loaded is set up again once every radio has its phy (with NSS offload the 5 GHz QCN6122 probes about 4 s after the 2.4 GHz radio) | tree patch 0007 | kuncy7 dff118f852 (10.15-2), kuncy7/openwrt-nss-edma#29 |
| Q6 crash-dump policy applied before every ath11k probe: `coredump=disabled` by default, so a root-PD crash restarts the Q6 in seconds instead of waiting 5 min for a dump to be read | tree patch 0004, `overlay/.../rd03v2-q6` (service, config, hotplug, `rd03v2-q6-policy`) | gate A5 |
| ath11k statistics kept on by default on this board (`qca-nss-pbuf` turned them off after the 2.4 GHz AP started: zero station signal) | tree patch 0005 | phase C, B7-B9 |
| Host-mode Wi-Fi: RX filter sizes in bytes (965), peer RX statistics (966) and monitor metadata (967) requested, so host mode receives correctly and reports station signal | `overlay/.../nss/ath11k/999-999-rd03v2-965..967-*` | phase C, B5-B9 |
| ath11k: after a Q6 crash, skip the user-PD stop handshake nobody can answer (973), and report in-flight TX frames to mac80211 when the datapath is freed (974; ends the "Have pending ack frames!" warning on reload) | `overlay/.../nss/ath11k/999-999-rd03v2-973-*`, `-974-*` | phase C, C9 |
| ath11k_ahb: in-place recovery after a Q6 root-PD crash. When the root PD restarts, its user PDs are spawned again and ath11k rebuilds both radios in a second or two, as v1.x did with its user-PD remoteprocs; a hw-restart of one radio restarts the root PD first, because a user PD spawned again on the root that ran it crashes the root. At most 6 respawns an hour (`respawn_max_per_hour`); `respawn_userpds=0` turns it off (975) | `overlay/.../nss/ath11k/999-999-rd03v2-975-*` | C9 |
| ath11k with NSS Wi-Fi offload: what makes an in-place recovery work with the offload on. The shared ring-pointer state is cleared on restart (979, upstream f51e4b3b5574: the restarted firmware read the old head pointer of the NSS-filled RXDMA ring, a NOC error once traffic came), NSS is torn down after the crash-path IRQ quiesce (980), and the NSS VAP nodes and peers of the old instance are released before the recovery (981: without it the radios beaconed but no station completed a 4-way handshake, and unloading ath11k afterwards reset the board). From v1.x, as carried in kuncy7's ipq50xx-2026.10.12 | `overlay/.../nss/ath11k/999-999-rd03v2-979..981-*` | C9 |
| ath11k: a restarted firmware gets the user's country again (982, kuncy7) | `overlay/.../nss/ath11k/999-999-rd03v2-982-*` | his 9966 |
| Memory, NSS Wi-Fi offload on this 256 MB board: kuncy7's optional NSS 256 MiB ath11k profile switched on (`CONFIG_ATH11K_NSS_MEM_PROFILE_256M`, his PR #21, off for every board in his releases: no host TX arrays NSS does not use, 4096 TX descriptors and completions per radio, private RXDMA page-frag caches), a private page-frag cache per CE RX pipe (984), and the per-CPU free page lists capped (`vm.percpu_pagelist_high_fraction=100`; 6-18 MB of free pages were parked there, uncounted). MemAvailable idle with both radios up: 42 MB, against 13-21 MB before and 34-35 MB on v1.14-nss | `config/rd03v2.config`, `overlay/.../nss/ath11k/999-999-rd03v2-984-*`, `overlay/.../etc/sysctl.d/13-rd03v2-pcp.conf` | memory deep dive |
| ath11k: "pdev N successfully recovered" is logged outside ath11k's shared warning rate limit, which a crash's failed commands often use up; the watchdog's mesh rejoin reads that line (977) | `overlay/.../nss/ath11k/999-999-rd03v2-977-*` | C9 |
| AN8855: room for a second 802.1Q tag in the switch's RX length (0959e). A VLAN on a WAN VLAN (QinQ, `wan.20.30`) is `[20][30]` on the wire, 1526 bytes at MTU 1500; the switch dropped every such frame in both directions, offloaded or not, so QinQ carried no full-size packets | `overlay/target/linux/qualcommax/patches-6.18/0959e-*` | C3 (QinQ) |
| ECM package release 3: his sources as they are. Release 2 (rc1) carried our 0053, which kept QinQ off the NSS firmware; it is gone, QinQ is offloaded since 0959e | `tools/feed-overlay-v2.py` | C3 (QinQ) |
| LuCI, full `wpad-mbedtls`, `i2c-tools`, `kmod-tun`/`-inet-diag`/`-nft-tproxy` | `config/rd03v2.config` | as v1.x |
| `luci-app-nss` in the image | `config/rd03v2.config` | his package; his image has no LuCI |
| AmneziaWG (kmod, tools, LuCI) in our repository | `build.sh` (feed, `awg_pin`) | as v1.x, #39 |
| ath11k: calibrated survey noise floor (the noise-floor half of 952) | `overlay/.../nss/ath11k/999-999-rd03v2-952-*` | v1.x 952 |
| ath11k: crash-recovery fixes 955, 956, 960, 961, 962, 963 | `overlay/.../nss/ath11k/999-999-rd03v2-9xx-*` | v1.x, #15 |
| ath11k: UK 5.8 GHz band (964) | `overlay/.../nss/ath11k/999-999-rd03v2-964-*` | v1.x, #34 |
| smp2p: clear cached inbound bits across a Q6 restart (0918), so `rmmod`/`insmod` and crash recovery can start the Q6 again | `overlay/target/linux/qualcommax/patches-6.18/0918-*` | v1.x 0918, moved into his `wcss_sec_start()` |
| Wi-Fi watchdog, ported to his single `q6wcss` remoteproc, **acting by default** (`dryrun=0`, `reload=1`, `inplace` unset = off: it reloads ath11k rather than resetting one radio). It leaves a root-PD crash to the kernel's respawn (both Wi-Fi modes) and steps in when the radios are not back 120 s later, or the respawn was suppressed. An upgrade from an earlier candidate is migrated to `dryrun=0` | `overlay/.../usr/sbin/rd03v2-watchdog`, `overlay/.../uci-defaults/96-rd03v2-watchdog-defaults` | v1.x, #15 |
| hostapd sends the first 4-way handshake message 8 times (`wpa_pairwise_update_count=8` on every AP interface, once). NSS holds a radio's RX for a few seconds after an in-place recovery; without it 7 of 22 rejoins failed the handshake and backed off 10 s, with it 0 of 22 | `overlay/.../uci-defaults/97-rd03v2-four-way-retries` | v1.x, #25; stock round trip, 2026-10-16 |
| First-boot Wi-Fi settings apply: both radio sections are written before any other uci-defaults script, as OpenWrt writes them. ath11k loads a minute into the first boot (after the NSS arm), so a first-boot script found no radio to configure: an install from stock with `--wifi-ssid` ended with both radios off | `overlay/.../uci-defaults/01-rd03v2-wireless` | stock round trip, 2026-10-16 |
| An empty or unreadable `/etc/board.json` is generated again at boot. An unclean reboot can leave it empty (wifi-detect rewrites it without fsync), and OpenWrt only generates a missing one: the radios then stayed down on every boot ("PHY is undefined") | `overlay/.../lib/preinit/81_rd03v2_board_json` | crash reboots, 2026-10-16 |
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

Signal readings drop by 31 dB on 2.4 GHz and 24 dB on 5 GHz against v1.x, for stations,
scan results and the probe signal alike: v1.x reads high (see [Not carried](#not-carried)).
Thresholds set against v1.x numbers (`rssi_reject_assoc_rssi`, `rssi_ignore_probe_request`,
usteer or DAWN settings, scripts) need the same amount taken off.

## Known issues

- **The board reset twice after an in-place Wi-Fi recovery with a client passing traffic.**
  37 hw-restarts of the 2.4 GHz radio with a station pinging the router recovered in place
  and the station rejoined after about 6 s; in 2 of them, both in the first hour after an
  install from stock, the board stopped 23-24 s after the restart and rebooted. Not seen in
  the 35 runs after those, and the cause is not known (VALIDATION, C9). A Q6 firmware crash
  is rare in normal use; if one resets the board, the reboot brings the radios back.
- **A multi-day soak of v2 was not run.** MemAvailable is 42 MB idle with both radios up and
  NSS offload, and settles at 34-36 MB once Wi-Fi clients have carried traffic; repeated
  client sessions, in-place recoveries and driver reloads did not make it drift (VALIDATION).
- **Signal on 2.4 GHz is checked to about ±10 dB only.** 5 GHz is reciprocal with the test
  client within 3 dB (C5), but the test client's own 2.4 GHz readings jump by about 20 dB, and
  one earlier comparison with Xiaomi's firmware on the same unit read 6 dB higher than this
  tree would. A small 2.4 GHz correction is neither established nor excluded; v1.x's 31 dB is
  excluded.
- `n2h_rx_queue[0]_drops` rise during offloaded PPPoE uploads. That queue is still 256 on
  256 MB boards; his 10-09 release raised it only for 512 MB and 1 GB boards.
- Fixed here, open in his release: a PPPoE session that does not hold the default route
  (mwan3, a backup line, PPPoE next to a DHCP uplink) is never offloaded after a boot
  (tree patch 0003; kuncy7/openwrt-nss-edma#25).

## Installing

v2 is published as a GitHub **pre-release**: tools that look for the latest release, like
`xiaomi-openwrt-install` without `--release`, keep installing v1.x.

- **From stock firmware:** `python3 install.py nss-v2 --release <v2 tag>` with
  [xiaomi-openwrt-install](https://github.com/ADCDS/xiaomi-openwrt-install). It roots stock,
  boots the v2 RAM installer and writes v2 to NAND, over a cable or (with the `-wifi`
  installer pair) over Wi-Fi.
- **From v1.x or another OpenWrt build:** as for any release of this port, boot the v2 RAM
  installer (`…-initramfs-factory.ubi` into `ubi_kernel`, see
  [docs/no-uart-reflash.md](../docs/no-uart-reflash.md)) and run `sysupgrade` with the
  `…-squashfs-sysupgrade.bin` from there; never in place. Keep settings to carry a v1.x
  configuration over: the first boot migrates it (below).
- **Back to v1.x:** the same RAM-installer route with a v1.x `-nss` image. Restore a v1.x
  configuration backup, not one taken on v2.
- **Back to stock:** `revert.py` from xiaomi-openwrt-install.

After installing, kernel modules come from our repository for that release (`apk add
kmod-…`); see [Packages](#packages). A sysupgrade keeps the configuration, not added
packages: add them again after an upgrade, and restart the network
(`/etc/init.d/network restart`) after adding a protocol such as WireGuard or AmneziaWG.

## Building

```
TAG=DEV-<name> v2/build.sh            # or a release tag; PREPARE_ONLY=1 stops before make
```

- The workspace is this repository plus, next to it: `mirrors/` (his tree and his nss feed,
  never pruned, with reflogs), `keys/v2/` (the signing key) and `dl-v2/` (the download
  cache). `RD03V2_WS` points elsewhere; each path also has its own variable.
- `upstream.lock`: his release and commit, built from the local mirror (his CI keeps only
  three releases, and his branches get rebased). The commits a release of ours builds on
  are also tagged `rd03v2/<his release>` in our forks
  [ADCDS/openwrt](https://github.com/ADCDS/openwrt) (his tree) and
  [ADCDS/nss-packages](https://github.com/ADCDS/nss-packages) (his nss feed). His
  `ipq50xx-rebase` branch no longer contains the nss commit of `ipq50xx-2026.10.09`.
  `bump-upstream.sh` tags new pins in the mirrors; pushing those tags is a separate step.
- `feeds.lock`: every feed pinned to a commit. `tools/freeze-feeds.sh` picks the commits as
  of his release time.
- `tree-patches/`: our changes to his files, applied with `git am` (no fuzz).
- `overlay/` and `shared.list`: new files only; the build refuses to overwrite his.
- `config/`: his CI fragments for the 256 MB group are used as they are; ours follow.
- `tools/verify-v2.sh --tree` checks the result; the build fails on any FAIL.
