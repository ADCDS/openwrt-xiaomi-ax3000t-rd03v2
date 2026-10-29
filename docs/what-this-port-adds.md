# What this port adds to kuncy7's release

The image is built from a pinned release of
[kuncy7/openwrt-nss-edma](https://github.com/kuncy7/openwrt-nss-edma). On top of it, this
port adds what follows: tree patches (`tree-patches/`, applied with `git am`), new files
(`overlay/`, never overwriting his) and configuration (`config/`), all applied at build time
([building](building.md)). Nothing depends on kuncy7 merging or rebuilding anything.

| | How | Source |
|---|---|---|
| His NSS bring-up debug options reverted (serial sysrq, sysrq mask) | tree patch 0001 | his commit `5d86c24df4` asks for it in deployed builds |
| NFC tag: I2C bus, `/usr/sbin/nfc`, its service and config | tree patch 0002, `overlay/.../usr/sbin/nfc`, `etc/init.d/nfc`, `etc/config/nfc` | [docs/nfc.md](nfc.md) |
| Q6 crash-dump policy applied before every ath11k probe: `coredump=disabled` by default, so a root-PD crash restarts the Q6 in seconds instead of waiting 5 min for a dump to be read | tree patch 0004, `overlay/.../rd03v2-q6` (service, config, hotplug, `rd03v2-q6-policy`) | C9 |
| ath11k statistics kept on by default on this board (`qca-nss-pbuf` turned them off after the 2.4 GHz AP started: zero station signal) | tree patch 0005 | C5 |
| Host-mode Wi-Fi: RX filter sizes in bytes (965; his c36db6321c put the constant itself back to 2048, so 965 now only keeps the byte count explicit at the call sites), peer RX statistics (966) and monitor metadata (967) requested, so host mode receives correctly and reports station signal | `overlay/.../nss-extra/ath11k/999-999-rd03v2-965..967-*` | C4, C5 (host mode) |
| ath11k: in-flight TX frames are reported to mac80211 when the datapath is freed, which ends the "Have pending ack frames!" warning on a driver reload after a Q6 crash (974) | `overlay/.../nss-extra/ath11k/999-999-rd03v2-974-*` | C9 |
| Memory, NSS Wi-Fi offload on this 256 MB board: kuncy7's optional NSS 256 MiB ath11k profile switched on (`CONFIG_ATH11K_NSS_MEM_PROFILE_256M`, his PR #21, off for every board in his releases: no host TX arrays NSS does not use, 4096 TX descriptors and completions per radio, private RXDMA page-frag caches), a private page-frag cache per CE RX pipe (his 999-997 for NSS mode; our 984 extends it to host mode and drains it under `ce_lock`, which the RX replenish timer also takes), and the per-CPU free page lists capped (`vm.percpu_pagelist_high_fraction=100`; 6-18 MB of free pages were parked there, uncounted). MemAvailable idle with both radios up: 42 MB, against 13-21 MB before and 34-35 MB on v1.14-nss | `config/rd03v2.config`, `overlay/.../nss-extra/ath11k/999-999-rd03v2-984-*`, `overlay/.../etc/sysctl.d/13-rd03v2-pcp.conf` | [Memory](../VALIDATION.md#memory-b19) |
| ath11k: the channel in use follows a channel switch (985). OpenWrt applies a channel change with a CSA, and ath11k left `rx_channel` on the old channel: `iw survey dump` showed the old channel in use with frozen counters, and the watchdog took that for a stuck radio and reloaded ath11k a few minutes after every channel change | `overlay/.../nss-extra/ath11k/999-999-rd03v2-985-*` | C10 |
| ath11k: a mesh interface under NSS Wi-Fi offload is refused with a message that names the remedy (986). NSS mesh is not built for 256 MB boards; without this the NSS vdev create failed with a bare -22 | `overlay/.../nss-extra/ath11k/999-999-rd03v2-986-*` | #21 |
| ath11k: host Wi-Fi mode no longer resets the board when a station associates (987). His NSS patch set rebuilds the 802.11 header from the RX descriptor through four driver functions it fills in for IPQ8074 and QCN9074 only, and his 10.15-2 runs host mode with ethernet decap too, so on IPQ5018 the first EAPOL frame called a NULL function. 987 uses the QCN9074 ones, which IPQ5018 already uses for every other descriptor field | `overlay/.../nss-extra/ath11k/999-999-rd03v2-987-*` | #47 |
| A client (station) interface stays on the NSS path (from v2.1.0). v2.0.1 and v2.0.2 moved Wi-Fi to the host path whenever one was configured, because on v2.0.0 an NSS station could not send frames over about 860 bytes; re-measured on his newer base it sends full-size frames on both bands, against HE and HT-only APs, faster than host mode. `nss.general.wifi_offload_sta='0'` (or `off`, `no`, `false`, `disabled`) keeps Wi-Fi on the host path while a station is configured; ath11k loads once per boot, so a change needs a reboot (`nss-status` says so) | tree patch 0008 | #48 |
| ECM gives both QoS tags of a ported connection a value (9001). For a uni-direction UDP connection (every UDP connection by default) it wrote uninitialised stack into `skb->priority` of reply packets; in host Wi-Fi mode ath11k turned that into the TCL TID, and TIDs 8-15 asserted the Wi-Fi firmware (`ar_wal_tx_send.c:22193`) on routed UDP to a Wi-Fi client, e.g. YouTube over QUIC | `feed-overlay/nss/qca-nss-ecm/patches/9001-*` | #52 |
| ath11k keeps the TX TID of a data frame in 0-7 (988), so no stray `skb->priority` (ECM, `SO_PRIORITY`, tc, nft) can assert the firmware in host Wi-Fi mode; mac80211 gives the 802.3 TX queue a defined value under his `HAS_TX_QUEUE` instead of an uninitialised index (989) | `overlay/.../nss-extra/ath11k/999-999-rd03v2-988-*`, `overlay/.../nss-extra/subsys/999-999-rd03v2-989-*` | #52 |
| ath11k: received 802.11 fragments go to a ring that is read (990). On IPQ5018 and QCN6122 the REO takes the fragment destination from `REO1_MISC_CTL`, which ath11k never wrote (it writes the IPQ8074 field in `GEN_ENABLE`), so it kept the firmware's choice: a ring towards the firmware that nothing drains. 63 fragments from any client filled it and the radio received nothing more until a reboot, while memory leaked. 990 writes it: the NSS REO destination ring with offload, the host's REO exception ring in host mode | `overlay/.../nss-extra/ath11k/999-999-rd03v2-990-*` | #53 |
| ath11k: the CE RX replenish timer is stopped before the copy-engine pipes are cleaned (991). Only the IPQ5018 stop path stopped it; on QCN6122 and in firmware-crash recovery a pending retry (armed after a failed RX buffer post, likely under memory pressure) could post into rings being cleared and dereference NULL | `overlay/.../nss-extra/ath11k/999-999-rd03v2-991-*` | review |
| PTK rekeys become a disconnect and reconnect (`wpa_deny_ptk0_rekey`, default 1, AP and station interfaces). Neither radio can replace a pairwise key in place: a rekey stalled traffic for 16-31 s and ended in a deauth; with the option the outage is 0-1 s as an AP. `option wpa_deny_ptk0_rekey '0'` on a `wifi-iface` restores the in-place rekey | tree patch 0009 | #49, #13 |
| ath11k: "pdev N successfully recovered" is logged outside ath11k's shared warning rate limit, which a crash's failed commands often use up; the watchdog's mesh rejoin reads that line (977) | `overlay/.../nss-extra/ath11k/999-999-rd03v2-977-*` | C9 |
| AN8855: room for a second 802.1Q tag in the switch's RX length (0959e). A VLAN on a WAN VLAN (QinQ, `wan.20.30`) is `[20][30]` on the wire, 1526 bytes at MTU 1500; the switch dropped every such frame in both directions, offloaded or not, so QinQ carried no full-size packets | `overlay/target/linux/qualcommax/patches-6.18/0959e-*` | C3 (QinQ) |
| LuCI, full `wpad-mbedtls`, `i2c-tools` (for the NFC tool) in the image. `kmod-tun`, `kmod-inet-diag` and `kmod-nft-tproxy`, in the v1.x image, are in our repository instead (`apk add`) | `config/rd03v2.config` | as v1.x |
| `luci-app-nss` in the image | `config/rd03v2.config` | his package; his image has no LuCI |
| AmneziaWG (kmod, tools, LuCI) in our repository | `build.sh` (feed, `awg_pin`) | as v1.x, #39 |
| ath11k: calibrated survey noise floor (the noise-floor half of 952) | `overlay/.../nss-extra/ath11k/999-999-rd03v2-952-*` | v1.x 952 |
| ath11k: UK 5.8 GHz band (964) | `overlay/.../nss-extra/ath11k/999-999-rd03v2-964-*` | v1.x, #34 |
| smp2p: clear cached inbound bits across a Q6 restart (0918), so `rmmod`/`insmod` and crash recovery can start the Q6 again | `overlay/target/linux/qualcommax/patches-6.18/0918-*` | v1.x 0918, moved into his `wcss_sec_start()` |
| Wi-Fi watchdog, ported to his single `q6wcss` remoteproc, **acting by default** (`dryrun=0`, `reload=1`, `inplace` unset = off: in host Wi-Fi mode it reloads ath11k rather than resetting one radio; with NSS Wi-Fi offload it reboots instead, from v2.1.0, because after a reload no client or station completes a 4-way handshake until a reboot). It leaves a root-PD crash to the kernel's respawn (both Wi-Fi modes) and steps in when the radios are not back 120 s later, or the respawn was suppressed. An upgrade from an earlier candidate is migrated to `dryrun=0` | `overlay/.../usr/sbin/rd03v2-watchdog`, `overlay/.../uci-defaults/96-rd03v2-watchdog-defaults` | v1.x, #15 |
| hostapd sends the first 4-way handshake message 8 times (`wpa_pairwise_update_count=8` on every AP interface, once). NSS holds a radio's RX for a few seconds after an in-place recovery; without it 7 of 22 rejoins failed the handshake and backed off 10 s, with it 0 of 22 | `overlay/.../uci-defaults/97-rd03v2-four-way-retries` | v1.x, #25; C9 |
| First-boot Wi-Fi settings apply: both radio sections are written before any other uci-defaults script, as OpenWrt writes them. ath11k loads a minute into the first boot (after the NSS arm), so a first-boot script found no radio to configure: an install from stock with `--wifi-ssid` ended with both radios off | `overlay/.../uci-defaults/01-rd03v2-wireless` | C1 |
| apk pins for the packages he changes without a version bump | `overlay/.../uci-defaults/95-rd03v2-apk-pins` | see [Packages](packages.md) |
| Migration of v1.x settings | `overlay/.../uci-defaults/00-rd03v2-migrate-v1x` | see [Upgrading from v1.x](upgrading-from-v1.md) |
| Our signing key, our repository first in `distfeeds.list` | `build.sh`, `keys/` | |

Our ath11k patches go in `patches/nss-extra/ath11k` and sort after all of his there
(`999-999-rd03v2-*`; that directory is applied after `patches/nss`), so each can be dropped on
its own once his tree covers it.
`tools/check-mac80211-series.sh` applies his whole mac80211 series plus ours without fuzz;
OpenWrt itself would accept a fuzzy hunk. The exception is a patch of his listed with its
sha256 in `tools/mac80211-fuzz-reviewed.txt`, after a review of where it lands (on his
c36db6321c: his 999-972, refreshed against a series with the mesh patches our 256 MB build
leaves out). Ours never qualify. Our mac80211 core patches go in `patches/nss-extra/subsys`
the same way, and our ECM patches in `feed-overlay/nss/qca-nss-ecm/patches`.

## Already in his tree (not carried)

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
- The json-c 0.19 leak in `json_object_put()` (#50): his libjson-c 0.19-r2 (json-c
  `f291fa81`), and since his merge of OpenWrt main of 2026-10-21 also the two follow-up
  fixes (OpenWrt's `102f4eebca`, 0.19-r3) our tree patch 0010 carried. libffi in the core
  tree (OpenWrt's `9b835ec626`, our former tree patch 0011) came with the same merge.
  `verify-v2` checks that his tree still has both.
- Board data: the calibration payloads the firmware loads are byte-identical in our v1.x
  `ipq-wifi` files, his tree and his image (both radios; ours only adds an alias without
  the variant), so his files are used as they are (C7).

## Not carried

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
