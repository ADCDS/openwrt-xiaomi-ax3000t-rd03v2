# v2 validation

What v2.0.0 to v2.1.0 were tested on before release, and what they were not. Everything
here ran on one Xiaomi AX3000T (RD03v2, 256 MB), installed on NAND, with:

- a wired client on a LAN port (1 GbE), the WAN port on an upstream LAN with
  internet access, and a PPPoE server on a WAN VLAN;
- one Wi-Fi client (a 1x1 QCA9377 card, about 1 m away) that joins the bench AP
  on each band;
- references measured on the same bench: v1.14 and v1.14-nss of this port
  ("B"), and kuncy7's `ipq50xx-2026.10.09` image as he publishes it ("K").

v2.0.0 is built on kuncy7's `ipq50xx-2026.10.15-2`. Most checks first ran on
his `ipq50xx-2026.10.09` (builds b5-b21 and the rc1 candidate builds). His 10.15
release changed almost everything under Wi-Fi: mac80211 backports 7.2, multi-PD
for the QCN6122 with his own user-PD respawn, NSS firmware 12.5, kernel 6.18.55
and a reworked wifi-scripts. On that base (b22, then the v2.0.0 build) the checks
those changes touch ran again: see
[On ipq50xx-2026.10.15-2](#on-ipq50xx-20261015-2-b22-v200). v2.0.2 moves to his
`ipq50xx-2026.10.19`: see [v2.0.2](#v202). v2.1.0 moves to his branch head of 2026-10-27
(`c36db6321c`): see [v2.1.0](#v210).

Each result names the build it ran on. The test builds (`v2.0.0-local.bN`) come
from the same tree as the release, built with `build.sh`; a release build
differs from its test build only in its version stamp and repository address, except
where the table below says it adds changes (v2.1.0 does).

| Build | What it adds |
|---|---|
| b5-b12 | the port onto kuncy7's tree, host-mode Wi-Fi fixes, the watchdog |
| b16 | in-place recovery after a root-PD crash (975, 977) |
| rc1-a | the first release candidate build: b16 plus the watchdog default |
| b17 | NSS in-place recovery (979-982) |
| b18 | 983 (a fatal during a planned root restart) |
| b19 | memory (per-CPU list cap, NSS 256 MiB profile, 984), QinQ (0959e), ECM release 3 |
| rc1 (b19 sources) | the release candidate built from b19 |
| b21 | first-boot Wi-Fi defaults (`01-rd03v2-wireless`), the `board.json` check (`81_rd03v2_board_json`), the 4-way handshake setting (`97-rd03v2-four-way-retries`), tree patches 0006 (DFS state) and 0007 (radio retry) |
| rc1 (b21 sources) | the release candidate built from b21 |
| rc1 | the release candidate: b21 plus 985 (the channel in use follows a channel switch); `kmod-tun`, `kmod-inet-diag` and `kmod-nft-tproxy` moved from the image to our repository |
| rc1 (final) | rc1 plus 986 (clear mesh error) and 995 (frame_mode guard), built fresh from the lean branch; flashed to NAND |
| b22 | his `ipq50xx-2026.10.15-2`: 16 of our patches dropped as his (see [the README](docs/what-this-port-adds.md#already-in-his-tree-not-carried)), our 10 ath11k patches in `patches/nss-extra` |
| v2.0.0 | the release: b22's sources without `81_rd03v2_board_json` (his `/etc/board.json` is in tmpfs), built fresh |
| v2.0.1 | v2.0.0 plus 987 (host Wi-Fi mode, #47) and tree patches 0008 (a station keeps Wi-Fi on the host path, #48) and 0009 (`wpa_deny_ptk0_rekey`, #49), built fresh; see [v2.0.1](#v201) |
| v2.0.2-local.b2 | v2.0.1's sources on his `ipq50xx-2026.10.19` (0008 refreshed), plus tree patches 0010 (json-c cleanup fixes, #50) and 0011 (libffi in the core tree); b1, the same without 0011, stopped at python3 |
| v2.0.2 | the release: b2's sources, built fresh; see [v2.0.2](#v202) |
| DEV-c36db-b1 | his `c3po-tag-8021q` head `c36db6321c`, tree patches 0010 and 0011 dropped (in his tree), 984 reworked onto his 999-997, the #52 fixes (ECM 9001, ath11k 988, mac80211 989) |
| DEV-c36db-b2 | b1 with tree patch 0008 reworked: a station stays on the NSS path (#48) |
| v2.1.0 | the release: b2's sources plus the watchdog's reboot instead of a driver reload under NSS offload, 990 (#53), and the review fixes (991, the guard in 990, `wifi_offload_sta` spellings, the watchdog's offload decision before ath11k loads), built fresh; see [v2.1.0](#v210) |

**Not tested:** a multi-day soak (the longest single runs were hours), more
than one unit of the hardware, and RF performance beyond throughput at one
distance. The reset button, the LEDs and an NFC tap with a phone were checked
by hand on rc1 (C8, C14).

## Summary

| | Check | Result (10.09 builds) | Build | On 10.15-2 |
|---|---|---|---|---|
| C1 | Install, upgrade and rollback paths, stock firmware both ways | see below | b5-b21 | stock 2.0.28 -> v2.0.0 with the reworked installer, its Wi-Fi and root settings applied; back to stock with `revert.py` (v2.0.0, b22) |
| C2 | Reboots, half of them power cuts | pass: 20 / 20 (b9), 4 / 4 (rc1-a) | b9, rc1-a | pass: 2 / 2 reboots, 2 / 2 power cuts (v2.0.0) |
| C3 | Wired through NSS: NAT, WAN VLAN, PPPoE on a WAN VLAN, QinQ, IPv6 over QinQ | pass, all offloaded, 923-941 Mbit/s | b9, b19 | pass, all offloaded, 915-937 Mbit/s (b22) |
| C4 | Wi-Fi, both modes, both bands | pass (b9, b16, b19, rc1 each build); 2.4 GHz needs the test client's Bluetooth off, see below | b9-rc1 | pass: 274 / 324 on 5 GHz, 39 / 58 on 2.4 GHz (v2.0.0); 276 / 341 on 5 GHz (b22). Host mode first measured on v2.0.1: 186 / 294 on 5 GHz (upload below v1.14), 36 / 58 on 2.4 GHz |
| C5 | Signal and noise floor in dBm | pass on 5 GHz (within 3 dB); 2.4 GHz within about 10 dB; v1.x reads 24-31 dB high | rc1 | noise floor -96 / -91 dBm (b22); otherwise not re-run: same ath11k conversion and patches |
| C6 | Regulatory: GB, US, DE, both Wi-Fi modes | pass | b9 | GB channel 149 at 23 dBm, kept through two recoveries (b22, #34); US and DE not re-run |
| C7 | Board data | byte-identical to v1.x and kuncy7 | - | board data and Wi-Fi firmware byte-identical to rc1's (b22) |
| C8 | NFC tag | pass, including a phone tap in both modes | b9, rc1 | the tag holds the configured network, in sync (b22); the phone tap not repeated |
| C9 | Recovery from Q6 firmware crashes, both Wi-Fi modes | pass, in place; a DFS AP stays up (b21, rc1); **2 board resets in 45 recoveries with a station passing traffic, cause not found** | b18-rc1 | pass, in place, about 20 events with no reset and no warning; a DFS AP stays up (b22, v2.0.0) |
| C10 | Watchdog against user actions | pass | b16 | pass (b22); from v2.1.0, with NSS Wi-Fi offload, a reboot where it reloaded ath11k (see [v2.1.0](#v210)) |
| C11 | Memory | 42 MB available idle, 34-36 MB in use, no drift; a multi-day soak not run | b19 | 42 MB available idle at 5 / 15 / 25 min; 100 min of Wi-Fi traffic: flat at 40 MB (b22) |
| C12 | Packages from our repository, tunnels, SQM | pass | b9 | kmods and AmneziaWG from the build's repository (b22); AmneziaWG from the published repository, with traffic, a reboot and the LuCI import (v2.0.0) |
| C13 | Upgrade from a realistic v1.x install | pass | b16 | not re-run; the migration's assumptions checked against his nss-tools |
| C14 | Buttons and LEDs | pass: both LEDs, both buttons, reboot, failsafe, factory reset | b9, rc1 | not re-run (no hardware or device tree change) |
| C15 | Package signature failures | pass, 8 checks | b9 | not re-run (same signing) |

## v2.1.0

v2.0.2 moved to his `c3po-tag-8021q` branch head of 2026-10-27 (`c36db6321c`, after his
`ipq50xx-2026.10.23`), plus the fixes for #52 and #53, a station on the NSS path (#48) and a
watchdog that reboots instead of reloading the driver under NSS offload. His tree has
no release tag on this commit yet: `upstream.lock` pins the commit, and `feeds.lock` pins the
package feeds as they were at its commit time, a combination his CI has not built. His
range was reviewed before the bump (293 tree commits, filtered to what our build compiles:
his own patches read diff by diff, OpenWrt's package bumps by their commit lists; and the
NSS feed from `a8e0e5cc` to `57c0fa18f`): no rejects; one adjusted in our overlay (999-997,
see 984 below). Most checks below ran on DEV-c36db-b2: the release's sources without the
watchdog change, 990 and the review fixes; each section names its build. b2: `verify-v2` 170 / 170 (new: his tree still provides the json-c fixes and
libffi our tree patches 0010 and 0011 carried, the ECM and mac80211 patch fingerprints, the
TX TID mask, the 984 cache in every mode and drained under `ce_lock`, the 2048-byte RX
buffer length in every memory profile).

**His tree under v2.1.0.**
- **Wi-Fi driver:**
  - his fix for the TX completion status offset (244a), which was behind the host-mode
    `tx completion mismatch` flood (#48 logs);
  - a per-CE-pipe RX cache for NSS mode (999-997). It does what our 984 did, so 984 is now a
    two-hunk delta on top of it: the cache in host mode too, and drained under `ce_lock`,
    which the RX replenish timer also takes;
  - a 1024-entry RXDMA ring on the QCN6122 (999-9901);
  - the 256 MB RX buffer length back at 2048 bytes (999-990, the bug our 965 fixed at the
    call sites);
  - mac80211 locking fixes.
- **NSS:** firmware empty-buffer payloads on whole pages (nss-drv 0149): the pool's pages
  leave `SUnreclaim`, an accounting shift rather than freed memory (see Memory below).
- **CPU:** scaled by schedutil between 1008 and 1296 MHz at the same fixed voltage, instead
  of pinned at 1008 by the `performance` governor. `soc_id` 447 is in his clock patch's list.
- **OpenWrt main of 2026-10-21 and 2026-10-26:**
  - the json-c fixes and libffi (our former tree patches 0010 and 0011);
  - five dnsmasq CVEs and the musl `regcomp` CVE;
  - hostapd fixes, among them apsta and `start_disabled`, which matter for a WISP uplink;
  - per-port host FDB tracking in DSA;
  - `kmod-nf-log6` removed (an empty package since kernel 5.13);
  - procd now kills an instance's leftover processes when it exits.
- **Our patches:** tree patch 0008 refreshed and reworked (#48 below); our ath11k patches and
  kernel patches 0918 and 0959e apply without fuzz. His 999-972 applies with fuzz in our
  build, which leaves his mesh patches out; it is listed in `tools/mac80211-fuzz-reviewed.txt`.
- **Config:** `CONFIG_KERNEL_DEBUG_INFO=y`. His merge made an unset option really mean no
  debug information; we keep it for decoding oopses from the build tree (the image is
  stripped either way).

**#52 (routed UDP into a Wi-Fi client asserts the firmware in host mode).** Reproduced on
v2.0.2 with the reporter's setup: a 5 GHz station uplink, Wi-Fi in host mode, YouTube over QUIC on a
client; same assert, same PC. Only UDP routed into a Wi-Fi client triggers it, over the
station or the wired WAN; TCP, traffic to wired clients, and NSS Wi-Fi mode do not.

- **The cause:** ECM marks every UDP connection uni-directional and, for packets of the
  reply direction, copies an uninitialised QoS tag into `skb->priority`. In host mode ath11k
  hands the priority to the firmware as the frame's TID, and a TID above 7 asserts it. An
  nft counter after ECM, up to the assert: 369 packets of such a flow carried a priority, 349 of
them one above 7;
  `echo 0 > /proc/sys/net/ecm/unidir_accel_en` stops it on v2.0.2.
- **The fix:** ECM gives both directions' tags a value (9001); ath11k keeps a data frame's
  TID in 0-7 (988); mac80211 gives the 802.3 TX queue a defined value (989).
- **On b1** (the same fixes, host mode with the station):

| Run | Packets | Asserts | Priority set |
|---|---|---|---|
| UDP down to the 5 GHz client, 20 Mbit/s, 120 s | 240,005, no loss | 0 | 0 |
| UDP down to the 2.4 GHz client, 20 Mbit/s, 60 s | 119,999, no loss | 0 | 0 |
| YouTube over QUIC, 5 GHz client, twice | - | 0 | - |
| wired WAN to the 5 GHz client, 20 Mbit/s, 60 s | 120,004, no loss | 0 | - |

  v2.0.2 asserted within seconds in each. Wired NAT stayed offloaded: 941 Mbit/s, flows in ECM.
- **On b2**, host mode chosen with `wifi_offload_sta='0'`: UDP 20 Mbit/s for 45 s, 90,005
  packets, no assert.
- **NSS Wi-Fi mode** does not take that path: on v2.0.2, without the fix, routed UDP into a
  client on either band did not assert, with ECM offloading the flows. On b2 with the station
  on NSS (default ECM settings): 180,008 UDP packets to the 5 GHz client and 120,012 to the
  2.4 GHz client, and YouTube over QUIC; no assert.

**#53 (a radio stops receiving after a client sends fragments).** A v2.0.2 AP's 2.4 GHz
radio received nothing more from 42.8 hours of uptime (its first REO command failure, -105,
in the kernel log) and ran out of memory by 6.6 days, when it was looked at. Read on that box:
`REO2FW_DEST_RING`, a ring towards the firmware that nothing drains (its tail stays 0), was
full with 63 entries, all 802.11 fragments from one station; behind it the whole REO block
had stopped (`RXDMA2REO_CMD_RING` backed up, REO commands failing with -105, queue
descriptors of departed stations piling up).

- **Reproduced on the bench:** a client fragmenting at 256 bytes (a USB adapter whose
  driver fragments in software, HT off so frames are not aggregated) wedges the radio in
  seconds with 1000-byte pings; the ring dump matches the AP's.
- **The cause:** on IPQ5018 and QCN6122 the REO takes the fragment destination from
  `REO1_MISC_CTL` (offset 0x5d8, the WCN6750 layout these chips share), not from the IPQ8074
  field in `GEN_ENABLE` that ath11k writes. Both radios read `0x000c0000` at boot: 6, the
  firmware ring. A first fix that changed only `GEN_ENABLE` still wedged.
- **The fix (990):** write the destination into `MISC_CTL`. On the 2.4 GHz radio with NSS
  offload, on DEV-c36db-b2's modules plus 990 and bench debug patches (a register knob, ring
  dumps); the release image's own runs are under "The release on NAND" below:

| Run | Result |
|---|---|
| 2000 pings of 1000 B; sizes 200-1472 B; 500 bridged to a wired host; 200 of 3000 B | 1999 / 2000; 0 % at every size; 500 / 500; 199 / 200 |
| TCP upload, 30 s, fragmented | 11.4 Mbit/s |
| 10 reconnects with fragmented traffic | all clean |
| 30 min: 1000 fragmented pings a minute, an upload every 3 min, a reconnect every 5 | 29,984 / 30,000; 1.54 million fragments reassembled into 228,581 frames; `REO2FW_DEST_RING` empty, RX descriptors and `SUnreclaim` flat |
| the field set back to 6 on the same boot | wedged again within 100 pings; only a reboot recovers |

  In host mode (`wifi_offload='0'`) the fragments go to the host's REO exception ring and the
  radio no longer wedges, but ath11k's host reassembly loses most fragmented frames: by run,
  1-100 % of pings lost (all of the 3000-byte ones), the delivered ones up to seconds late, a
  fragmented TCP upload did not finish. 5 GHz: the same register value at boot (6) and after
  the fix (7), read with the bench knob; no 5 GHz client that fragments was available. Which
  client fragmented on the reporter's AP is not known.

**#48 (a station on the NSS path).** On v2.0.2, and on this base, an NSS station sends
full-size frames. On v2.0.2 unless the build is named:

| Station | Result |
|---|---|
| 5 GHz station, HE AP (MT7981) | pings of 200-1472 bytes both ways without loss; upload at its 50 Mbit/s cap; HE-MCS 9-11 |
| 2.4 GHz station, the same AP | pings without loss at every size; upload at its 30 Mbit/s cap |
| 2.4 GHz station, HT-only AP | 10 / 10 associations good; upload 53.2 Mbit/s, download 48.8; host mode on v2.0.1 47.5 up |
| the same, added at runtime after a boot without a station | every size without loss, MCS 7, upload 51.2 Mbit/s |
| v2.1.0 (before the review fixes), 5 GHz station, HE AP | the NAND runs below: 50 Mbit/s through the station, wired NAT offloaded |
| v2.1.0, 2.4 GHz station, HE AP (HE-MCS 7-8) | don't-fragment pings of 200-1472 bytes from a wired client through it: 0 % loss; upload at its 30 Mbit/s cap, no retransmission |
| v2.1.0, 2.4 GHz station, HT-only AP (an RT3070 USB adapter, MCS 4-7) | pings of 200-1472 bytes as above: 0-5 % loss at the small sizes, none from 800 bytes up; upload 22.4 Mbit/s, download 7.5. The same with `wifi_offload_sta='0'` (host path), same hour: upload 10.9, download 8.9 |

The failures first reproduced on v2.0.2 came from the test AP: a QCA9377 card whose radio is
shared with Bluetooth, which was playing audio; with Bluetooth off it never failed. The
v2.0.0 runs that led to 0008 used the same card, Bluetooth state not recorded. So tree patch
0008 now leaves a station on the NSS path; `nss.general.wifi_offload_sta='0'` is the opt-out,
checked across a reboot on b2 (`nss-status` asked for the reboot first, then reported host
mode with the reason, and the boot log names it). Untested: a VHT-only 5 GHz AP, like the
reporter's (no such AP on the bench: the test PC's QCA9377 may not transmit on 5 GHz), and an A/B
of NSS against host mode under interference. An upgrade from v2.0.1 or v2.0.2 moves a
configured station to the NSS path without asking.

**C4, same rig, same hour** (NSS, no station, 5 GHz AP on channel 36, iperf3 20 s, Mbit/s):

| Build | 5 GHz up / down | 2.4 GHz up / down |
|---|---|---|
| b2 | 215, 207 / 326, 325 | 33.7, 34.0 / 59.0, 59.2 |
| v2.0.2 | 225, 206 / 325, 326 | 33.5, 33.1 / 58.6, 58.3 |

Both are below the earlier v2.0.2 figures (245-274 up): the AP shared its channel with the
upstream AP that day. The CPU clock made no difference (pinned at 1008 or 1296: 204-210 up,
CPU 95 % idle).

**Memory.** After the same runs: b2 36.3 MB available, 23.3 MB `SUnreclaim` (about 6 min of
uptime); v2.0.2 34.2 MB and 45.1 MB (61 min). The `SUnreclaim` drop is nss-drv 0149.

**1296 MHz.** DEV-c36db-b2 with the station on NSS, 6.3 hours. Two `gzip | gunzip | sha256sum`
loops kept both cores busy and checked every result; clock, four thermal zones and
`MemAvailable` were logged every 10 s:

| Phase | Clock | Peak CPU / NSS °C | Checksum runs | Mismatches |
|---|---|---|---|---|
| 20 min | pinned at 1008 | 58 / 59 | 385 | 0 |
| 2 h | 1008 / 1296 toggled, about 366,500 transitions | 58 / 59 | 1,398 | 0 |
| 4 h | pinned at 1296 | 59 / 60 | 4,946 | 0 |

No reset, oops, firmware assert, lockup or RCU stall; 32-35 MB available throughout. The
CPU throttles at 100 °C. The checksum loop is mostly memory-bound (6 % more runs at 1296), so
the clock was measured separately on the release: a CPU-bound `awk` loop takes 54.4-55.0 s
pinned at 1008 MHz and 43.6-43.9 s at 1296, 24-25 % faster. Limits: CPU load only (no NSS or
Wi-Fi traffic in the pinned phase), a night-time room, one unit; the base-bump review's
plan for it (72 hours, 20 cold and 20 warm boots, NSS and Wi-Fi load at 1296) was not run.
1296 MHz is above the IPQ5018's rated 1008 at the same voltage. Holding the rated clock is
one setting, in the README.

**Driver reload with NSS Wi-Fi offload (C9, C10).** A client last joined after such a reload
on the 10.09 base; on b22 the watchdog's reload after a manual unload (C10) brought both
radios back, and no client was tried. Unloading and loading ath11k as the watchdog does (`wifi down`, `rmmod`, `modprobe`,
`wifi up`), with offload on and a station on the 5 GHz radio: both radios come back and the
station associates (the 5 GHz AP waits for it), but no client or station completes a 4-way
handshake on either radio (`4WAY_HANDSHAKE_TIMEOUT` on the station; "4-Way Handshake failed" on a client of
the 2.4 GHz AP). NSS drops the 5 GHz radio's received frames as REO "null queue" (386 in a
few minutes). The same on a fresh boot, and on v2.0.2 with `wifi_offload_sta='1'`, so it
predates this base. Without a station (APs only, on the release before the review fixes):
the same, both APs up, a client's handshake on the 2.4 GHz AP failing every time
("4-Way Handshake failed", reason 15) and the 5 GHz AP not joined. An ath11k reset afterwards
does not help; a reboot does. Host mode
reloads cleanly: everything back in 64 s, a 50 Mbit/s download through the station. On
v2.0.0 to v2.0.2 the watchdog took such a reload for a recovery whenever the radios looked
healthy afterwards; from v2.1.0 it reboots instead once ath11k has run with offload in that
boot (`tools/test-watchdog.sh`: 46 / 46 with the review fixes, among them new NSS scenarios).

**Checks from the release review.** An adversarial review of the v2.1.0 changes
(`evidence/2026-10-28-v2.1.0-review/REVIEW.md`) raised these, checked on the release before
its fixes:
- **A station whose uplink AP is gone, with the watchdog acting:** 9 minutes of a station
  scanning for a missing AP (dry run): no incident. While it is unconnected, OpenWrt keeps the
  AP on that radio down too, and a radio with nothing up has no in-use survey entry for the
  freeze check to read.
- **An `skb->priority` above 7 with NSS Wi-Fi offload** (988 covers host mode only): an nft
  rule setting priority 9 on UDP routed into the 5 GHz client, ECM's front end stopped so that
  every packet took the slow path: 62,518 packets, no loss, no assert.
- **Host-mode memory under traffic** (the review asked for a soak of the host fragment path):
  see the last rows of the release table below. Host Wi-Fi mode costs about 20 MB of
  available memory under sustained Wi-Fi traffic, fragments or not; NSS mode stays at 40-42 MB.
- **Firmware-crash recovery time:** bimodal, 8.4-10.5 s or 32.6-34.6 s. In the slow runs the
  5 GHz test client kept an association that carried nothing until hostapd dropped it for
  inactivity (default settings), then rejoined at once. It is not tied to a second client or
  to fragments, and it predates 990: six asserts alternating between the radios, same rig and
  hour, took 32.6 s once on the build without 990 (f7f55a3) and twice on the release.

**The release on NAND.** First a v2.1.0 build without the watchdog change (the release's
sources otherwise, `verify-v2` 170 / 170), installed through the RAM installer from v2.0.2 with
settings kept: all 47 configuration files byte-identical, 200 packages (`kmod-nf-log6` gone),
NSS offload on with the station, both APs, no kernel warning, 42.5 MB available at 78 s.
On it, with the station on the NSS path unless noted:

| Check | Result |
|---|---|
| #52, UDP 20 Mbit/s for 60 s into a client | 2.4 GHz and 5 GHz: 125,000 packets each, no loss, no assert; the same in host mode (`wifi_offload_sta='0'`, after a reboot) |
| C9, hw-restart and assert on each radio | 4 / 4 in place in 10.5-14.6 s: station, client and 50 Mbit/s through the station back, same boot, no warning; the watchdog logs them as recovered by the kernel |
| C9 in host mode | driver reload: everything back in 64 s; assert (5 GHz) and hw-restart (2.4 GHz) in about 10 s |
| C4, client to a wired host on the LAN | 188 / 313 Mbit/s on 5 GHz (the station shares the radio), 40 / 57 on 2.4 GHz |
| Wired client to the uplink through the station | offloaded by ECM, CPU 95 % idle at the 50 Mbit/s test cap |
| A client's MAC moves from Wi-Fi to a LAN port and back (his DSA host FDB change) | traffic within 1 s each way, the bridge follows, no switch error |
| Reboots | 2, everything up within about 63 s |

Then a build with everything but the #53 fix (990), `verify-v2` 170 / 170, installed from
its assets the same way: 47 / 47 configuration files byte-identical, NSS with the station,
both APs, no warning. UDP 20 Mbit/s for 30 s into the 5 GHz client: no loss, no assert; an
assert on 5 GHz recovered in place in 8.4 s. The watchdog's new step, end to end: with
offload on, ath11k unloaded by hand; the watchdog detected the missing radios, did not
reload, logged "REBOOTING: ... (a driver reload does not recover NSS Wi-Fi offload)" and
rebooted; after it everything was back (NSS, station, both APs, 237 / 323 Mbit/s on 5 GHz).
Its incident file gives the health as "healthy" there: no health check runs when the reload
is skipped, as with `reload '0'`.

Then a build that adds 990 and nothing else to that image (2678d15, before the review fixes;
the watchdog byte-identical), `verify-v2` 171 / 171, installed from its assets the same way:
47 / 47 configuration files byte-identical, NSS with the station, both APs, no warning,
41 MB available.

| Check | Result |
|---|---|
| #53, a client fragmenting at 256 bytes on 2.4 GHz | the fragment register holds 7; 2000 / 2000 pings of 1000 B, 0-2 % loss at 300-1472 B, 500 / 500 bridged to a wired host, 200 / 200 of 3000 B, a 10.5 Mbit/s upload, 3 reconnects; 157,459 fragments reassembled into 23,205 frames, `REO2FW_DEST_RING` empty |
| #52, UDP 20 Mbit/s for 60 s into a client | 2.4 GHz and 5 GHz: 125,000 packets each, no loss, no assert; the same on 5 GHz in host mode |
| C9, assert on 5 GHz | in place in 8.5 s |
| C9, assert or hw-restart on 2.4 GHz (restarts both radios) | in place in 8.4-8.6 s in 3 runs, 32.6-34.6 s in 5: the 5 GHz client kept an association that carried nothing until hostapd's inactivity check dropped it, and it rejoined at once (see "Checks from the release review": this predates 990) |
| C4, client to a wired host | 234 / 322 Mbit/s on 5 GHz, 36.5 / 58.4 on 2.4 GHz |
| Reboot | everything up at 85 s |
| Host mode | the fragment register holds 0, fragments reach the exception ring, no stall; fragmented frames arrive late or not at all (1-100 % loss by run); memory settles at 34 MB |
| Back to NSS, reboot | everything up, no warning |

Then the release itself: that build plus the review fixes (806a013: 991, the guard in 990,
the `wifi_offload_sta` spellings, the watchdog's offload decision before ath11k loads and its
incident text), `verify-v2` 174 / 174, installed the same way: 47 / 47 configuration files
byte-identical, NSS with the station, both APs, no warning, 41 MB available, the watchdog
byte-identical to the source.

| Check | Result |
|---|---|
| #53, a client fragmenting at 256 bytes on 2.4 GHz | the fragment register holds 7; 2000 pings of 1000 B: 1.7 % lost, 500 bridged to a wired host: 2 %, 200 of 3000 B: 8 % (the same client unfragmented lost 1.8-2.4 % that hour); an 11.0 Mbit/s upload, 3 reconnects; 153,148 fragments reassembled into 22,466 frames, `REO2FW_DEST_RING` empty |
| #53, 30 minutes (the release's own modules): 1000 fragmented pings a minute, an upload every 3 minutes, a reconnect every 5 | about 2 % of pings lost each minute, as unfragmented; 1,505,072 fragments into 221,522 frames, none out of order or invalid; `REO2FW_DEST_RING` empty, RX descriptors flat, no REO command failure; uploads 10.8-11.2 Mbit/s; reconnects 1 s; 40-42 MB available, `SUnreclaim` 21.9-22.4 MB |
| #52, UDP 20 Mbit/s for 60 s into a client | 2.4 GHz and 5 GHz: 125,006 packets each, no loss, no assert; the same on 5 GHz in host mode |
| C9, asserts and a hw-restart on both radios (10 events) | all in place, same boot, no warning: 8.4-10.5 s, or 32.6-34.6 s in 4 (see "Checks from the release review") |
| C4, client to a wired host | 208 / 310 Mbit/s on 5 GHz, 45.8 / 58.6 on 2.4 GHz |
| The watchdog, end to end | ath11k unloaded by hand with offload on: detected 60 s later, no reload, a reboot; the incident file gives the health as "not checked (no driver reload with NSS Wi-Fi offload)"; after the reboot everything up |
| `wifi_offload_sta='off'` with the station | `nss-status` asked for a reboot (its message still names the value `0`); after it, host mode with the station, the boot log names the reason |
| Host mode, 30 minutes of the #53 soak | no stall; pings about 2 % lost at that rate, uploads 7.4-8.5 Mbit/s; available memory fell from 43 MB to 5-10 MB at the first upload and stayed there (once 0.6 MB, at the end of an upload, with 19 MB free); 12 MB came back when the client left, 20 MB after a Wi-Fi restart and dropping the page cache |
| Host mode, the same traffic unfragmented then fragmented, 10 minutes each, fresh boot | unfragmented: 42.6 MB available before, 20-26 MB once the first upload ran (22.4 Mbit/s); then fragmented: 17-20 MB. Most of the drop is host-mode Wi-Fi traffic itself, not fragments |
| Back to NSS, reboot | everything up, no warning, 40.6 MB available; 47 / 47 configuration files as before the tests |

## v2.0.2

v2.0.1 moved to his `ipq50xx-2026.10.19`, plus the json-c fixes for #50. The checks ran on
v2.0.2-local.b2, built from the release's sources (it differs only in its stamp and
repository address). `verify-v2` 156 / 156 (two new: tree patches 0010 and 0011). Each
number below was measured against v2.0.1 on the same bench in the same hour.

**His 10.19 under v2.** Same kernel (6.18.55, the same kernel package version) and NSS
firmware (12.5); qca8k fixes and the kmod-sched split; ECM rebuilds a multicast flow of a
tag_8021q bridge on a membership change; libjson-c 0.19-r2. Tree patch 0008 refreshed: his
nss-tools moved the lines around it, ours unchanged, and his nss-tools tests pass with it
(nss-status 64 / 64). Our eleven ath11k patches and our kernel patches 0918 and 0959e apply
without fuzz.

- **Wi-Fi driver.** His merge of OpenWrt main adds IPQ9574 support (ath11k 953) before his
  NSS series, which moves the context of three of his patches (068, 207, 999-233); they apply
  with fuzz, as OpenWrt applies them. The ath11k source the series produces, compared with
  v2.0.1's: the IPQ9574 additions, and three hunks of his 237-006 that each land one ops
  struct early (no fuzz reported), so the IPQ9574 ops gain a line the QCA6390 ops lose (no
  board of his uses either with NSS); the IPQ5018 and QCN6122 parameters and `ipq5018_ops`
  are byte-identical. The three are listed by sha256 in `tools/mac80211-fuzz-reviewed.txt`.
- **C7.** `lib/firmware` is byte-identical to v2.0.1's (41 files: ath11k firmware, both
  radios' board data, NSS firmware), though `ipq-wifi` and `ath11k-firmware` were repackaged.
- **libffi.** His CI built 10.19 with a packages feed from after libffi moved to OpenWrt's
  core tree (the commit its feeds buildinfo records, which `feeds.lock` pins), and his tree
  predates the move. b1 stopped there: `i2c-tools` builds the target python3, whose `_ctypes`
  needs `ffi.h`. Tree patch 0011 carries OpenWrt's package.

**Install.** From v2.0.1 through the RAM installer, settings kept: every configuration file
byte-identical afterwards (46 in the backup), 201 packages, libjson-c 0.19-r3, NSS offload
on with Wi-Fi offloaded (wifili), both APs, no kernel warning, 44.8 MB available at 72 s.

**#50.** `rpcd` data size, LuCI logins through uhttpd's JSON-RPC, each session destroyed:

| | start | after 80 logins |
|---|---|---|
| v2.0.1 | 704 kB | 14,812 kB (+1.4 MB per 8, never freed) |
| v2.0.2 | 520 kB | 540 kB (20 kB of warm-up in the first 24 logins, then flat) |

64 logins over `ubus` on v2.0.2: 540 kB throughout. Empty sessions (no ACL parsing) were flat
on both.

| Check | v2.0.1 | v2.0.2 |
|---|---|---|
| C3 wired NAT, 4 streams, up / down | 941 / 941 Mbit/s, CPU 90-92 % idle | 941 / 941 Mbit/s, CPU 92-94 % idle, flows in ECM |
| C4 5 GHz, NSS offload, up / down | 270 / 307 | 245-274 / 308-312 (three runs) |
| C4 2.4 GHz, NSS offload, up / down | 37 / 51 | 48 / 57 |

**Smoke:** `kmod-tun` from the build's signed index alone installs, loads and uninstalls;
2 reboots clean (both APs within about 62 s, no warning, 43 MB available). Not re-run for
v2.0.2: crash recovery (C9), power cuts, VLAN / PPPoE / QinQ, IPv6, host Wi-Fi mode and mesh,
the station and rekey tests of v2.0.1, regulatory, NFC, buttons and LEDs. The multicast path
his ECM change touches was not tested.

## v2.0.1

v2.0.0 plus three Wi-Fi fixes, built fresh: `verify-v2` 154 / 154 (eight new checks: the
three patches, the image's scripts and defaults, and a source check that IPQ5018's RX
descriptor table has every 802.11 header function the RX path calls). Installed on NAND as an
update from v2.0.0 through the RAM installer, settings kept: every configuration file
byte-identical afterwards, 201 packages, NSS offload on, both APs, no warning, 42 MB available.
Also v2.0.1 -> v2.0.0 -> v2.0.1, same result.

**Host Wi-Fi mode (#47).** v2.0.0 reset the board whenever a station associated in host mode;
VALIDATION had not run host mode on the 10.15-2 base. v2.0.1, `nss.general.wifi_offload='0'`:
a client retrying across the reboot (a reboot loop on v2.0.0) associates on 5 GHz and on
2.4 GHz (MCS 7), no oops. 802.11s mesh in host mode, open mesh on 5 GHz with an MT7981 router
as the peer: peer link established at -49 dBm, 20 / 20 pings and 10 / 10 at 1400 bytes. C4 in
host mode, first time on this base: 186 / 294 Mbit/s on 5 GHz, 36 / 58 on 2.4 GHz. 5 GHz
uploads are below v1.14 plain's 273 Mbit/s (b18 on the 10.09 base: 257).

**PTK rekey (#49).** Bench 5 GHz AP with `wpa_ptk_rekey=15`, 60 s TCP download to the client:

| Mode | v2.0.0 | v2.0.1 (default `wpa_deny_ptk0_rekey=1`) |
|---|---|---|
| NSS offload | 16 s below 5 Mbit/s, 232 Mbit/s, a deauthentication after each failed rekey | 1 s, 322 Mbit/s: 4 rekeys, 4 immediate reconnects |
| host | crashed (with 987 alone: 31 s, 122 Mbit/s) | 0 s, 267 Mbit/s |

As a station of an AP rekeying every 20 s (90 s upload): no failed handshake and no EAPOL-Key
timeout on the AP; each rekey costs about 5 s (22 s of 90 below 1 Mbit/s, v2.0.0 21 s with the
AP timing out and deauthenticating the station).

**Station interface (#48).** Upstream AP on 2.4 GHz, the bench's station on radio0 in the WAN
zone. Added without a reboot, so on the NSS path: `nss-status` warns that a reboot is needed,
and the bug shows (upload 0.16 Mbit/s; forwarded pings of 1000 bytes 80 % lost, 1400 bytes
90 %). After a reboot Wi-Fi is on the host path (logged with the reason): upload 47.5 Mbit/s,
download 40.9, pings up to 1472 bytes without loss. `nss.general.wifi_offload_sta='1'` keeps
the NSS path. Host mode with a station logs `tx completion mismatch` lines from his TX
accounting patch; on this 256 MB build that counter only feeds the message.

**C4, NSS offload:** 297 / 345 and 294 / 348 Mbit/s on 5 GHz (pass); 2.4 GHz download 58
(pass), upload 20-24 (below 90 %). The 2.4 GHz upload varies by boot on both releases: v2.0.0
gave 29-38 Mbit/s right after a flash and 22-25 after a plain reboot, v2.0.1 20-28 over two
boots; the client then cannot send UDP faster than about 22 Mbit/s, and the bench receives
all of it. Host mode gives 25-43 in the same hour.

**Smoke:** wired NAT 941 / 941 Mbit/s, offloaded (ECM, CPU 87 % idle); `kmod-tun` from the
build's signed index installs and loads; 2 reboots clean. Not re-run for v2.0.1: crash
recovery (C9), power cuts, VLAN / PPPoE / QinQ.

## On ipq50xx-2026.10.15-2 (b22, v2.0.0)

His 10.15 release under v2: mac80211 backports 7.2 with his ath11k series in
`patches/nss` and `patches/nss-extra`, multi-PD for the QCN6122 with his own user-PD
respawn (his 976), NSS firmware 12.5 for the 256 MB group, kernel 6.18.55, and a
reworked wifi-scripts that keeps `/etc/board.json` in tmpfs. What v2 dropped as his,
and what it still carries, is in the [README](docs/what-this-port-adds.md).

**First boot (b22).** NSS firmware `NSS.FW.12.5-210-MP.R`. Both radios keep their
device paths (`soc@0/c000000.wifi`, `soc@0/b00a040.wifi`), so saved configurations
still match. The watchdog arms with `respawn=1` (his `ath11k_ahb` has no
`respawn_userpds` parameter and always respawns), Q6 crash dumps are disabled by our
policy, no kernel warning, 42 MB available at 2.5 min.

**C3 wired (b22)**, 4 streams each way, Mbit/s, every flow offloaded (ECM
`accel_mode=2`), nothing from the WAN on the LAN:

| Path | Up / down |
|---|---|
| QinQ (`wan.20.30`), twice | 929 / 935, 927 / 936 |
| IPv6 over QinQ, routed | 915 / 923 |
| WAN VLAN (`wan.20`) | 930 / 937 |
| Untagged WAN, NAT44 | 933 / 937 |
| PPPoE on `wan.20` | 926 / 934 |

**C9 crash recovery (b22)**, NSS offload:
- A station on 2.4 GHz pinging the router, a hw-restart every 75 s: 11 of 11 in place.
  With a client profile that reconnects on its own, 8 of 8 rejoined: after 1.9-5.6 s,
  and once after 22.9 s, when the client received the AP's deauthentication (reason 7)
  before it noticed the restart. The radios come back in 1-2 s now, so a client does
  not always see the restart as a lost beacon. rc1 took about 6 s.
- A 5 GHz assert, a 5 GHz hw-restart and a 2.4 GHz assert, each with a station: in
  place, the station kept its link.
- A 5 GHz AP on DFS channel 52 (HE80, after the 60 s CAC), assert and hw-restart:
  5260 MHz stayed available, the AP kept carrier and channel to +120 s.
- About 16 events: no board reset, no kernel warning, no "UserPD stop wait timed
  out"; the watchdog recorded each root-PD crash as recovered by the kernel's respawn.

**C10 (b22).** `wifi down` and a radio disabled in UCI: "taken down on purpose",
nothing done. `rmmod ath11k_ahb ath11k` by hand: detected (`q6wcss=offline`), ath11k
reloaded, both radios back, same boot; no client was tried after it (from v2.1.0 the watchdog
reboots here with NSS offload: see [v2.1.0](#v210)).

**C11 (b22).** Idle, both radios up, no clients: MemAvailable 42 / 42 / 42 MB at
5 / 15 / 25 min, SUnreclaim 35 MB. Then 100 minutes of TCP both ways at 50 Mbit/s each,
5 GHz client to the wired client (34.9 GB each way, all delivered): MemAvailable stayed at
40 MB and SUnreclaim at 36 MB from the first sample to the last, and 5 min after the client
left; no warning, no OOM, same boot. rc1 settled at 34-36 MB after client traffic.

**Packages and closed issues (b22).** `kmod-tun`, `kmod-inet-diag`,
`kmod-nft-tproxy`, `kmod-nft-queue` and `kmod-nfnetlink-queue` install from the
build's repository and load (#37); AmneziaWG installs and its module loads on
demand (#39). #23: station and AP RX counters follow 100 pings on both bands. #34:
above. #18: a slow 5 GHz receiver (HT20) under 2 and 8 TCP streams and 900 Mbit/s of
UDP, then Wi-Fi to WAN both ways: no stall, no OOM, no warning; MemAvailable fell to
19.5 MB under that load and came back. #11: `vlan_filtering` on, a reboot with it on
and off again, the host path kept. #7: the wired-to-Wi-Fi roam carries downstream
unicast from the first packet. #24: `frame_mode=1` set by hand comes up as 2 (his
nss-tools sets it where it loads ath11k) and clients associate. #21: as before (986).

**On the v2.0.0 build.** `verify-v2` 146 / 146. The bench was taken back to stock 2.0.28
with `revert.py` (b22's RAM installer; the setup wizard back), then v2.0.0 installed
from stock with the reworked xiaomi-openwrt-install: the plain selection (`standard`)
picked the v2 images of a v2 tag, and the installer's settings applied on the first
boot (SSID, WPA2 key and country BR on both radios, both APs up, the root password set,
`wpa_pairwise_update_count=8` on both APs; NFC at its default, `clear`). Then:
- C2: 2 reboots and 2 power cuts, each back with both APs on their channels, the
  settings kept, `/etc/board.json` valid through its link to the tmpfs copy, no
  warning, 41-42 MB available; after a power cut UBIFS replays its journal ("recovery
  needed", "recovery completed" 0.2 s later).
- C9: two 2.4 GHz hw-restarts with a station (back after 4.9 and 4.5 s, no failed
  handshake) and a 5 GHz assert with a station (in place, the link kept), same boot, no
  warning.
- C4: 5 GHz 273.6 / 323.7 Mbit/s, 2.4 GHz 39.0 / 57.5 Mbit/s (channel 6, the test
  client's Bluetooth connected), 3 / 3 hashes on both bands: pass against v1.14-nss.

## C1: install, upgrade and rollback

| Path | Result | Build |
|---|---|---|
| v1.14-nss -> v2 through the RAM installer, keeping a v1.x config (VLANs, the v1.x NSS knobs and disabled services that the migration handles) | pass | b5, b10, rc1-a |
| v2 -> v2, keeping settings | pass | b10, and every candidate since (b12 -> b16) |
| v2 -> v1.14-nss (rollback), with a v1.x config | pass: v1.14-nss boots with it, both APs, NSS and ECM loaded, no warnings | b16 |
| offline RAM installer from a release cache (`install.py nss-v2 --offline`) | pass | b9 |
| v2 -> stock 2.0.28 with `xiaomi-openwrt-install` (`revert.py`, wired) | pass: stock written and read back, setup wizard back (`inited=0`) | rc1 (twice) |
| stock 2.0.28 -> v2 with `xiaomi-openwrt-install` (`install.py nss-v2`, wired, `--root-password`, `--wifi-ssid`/`--wifi-key`/`--wifi-country`) | rc1 and b21: pass, the installer's first-boot settings applied (SSID, WPA2 key and country on both radios, both APs up, root password set, `wpa_pairwise_update_count=8` on both APs). The first rc1 build: installed, but both radios came up off with OpenWrt's defaults, because the first-boot script ran before ath11k had loaded (fixed by `01-rd03v2-wireless`) | rc1, b21, rc1 (b19 sources) |
| stock 2.0.28 -> v2 over Wi-Fi (`install.py nss-v2 --transport wifi`, the test client joining the factory network, then the RAM installer's, then the permanent one) | pass: final verification over the permanent Wi-Fi, the same first-boot settings applied as on the wired install | rc1 (b21 sources) |
| kuncy7's `ipq50xx-2026.10.09` image -> v2, keeping its config (hostname, root password, Wi-Fi settings, a static DHCP host) | pass: all kept, migration marker set, NSS and ECM up, offload on, no warnings | rc1-a |

## C13: upgrade from a realistic v1.x install (b16)

On v1.14-nss, on top of a bench config with VLANs and the v1.x NSS settings:
PPPoE on a WAN VLAN (`wan.20`) next to the DHCP WAN, a guest SSID on its own
bridge, DHCP pool and firewall zone, the NFC tag sharing the guest network, an
SQM (cake) queue on the WAN, and an AmneziaWG interface with a peer. Then the
RAM-installer upgrade to v2, keeping that configuration. After the first boot:

| | Result |
|---|---|
| migration (`rd03v2.v2.migrated`), NSS and ECM loaded, NSS Wi-Fi offload | pass |
| both APs and the guest SSID, guest bridge with its address, its zone | pass |
| PPPoE on `wan.20` | pass: the session comes up (on v1.14-nss it does not, #44) |
| NFC tag | pass: holds the guest network, in sync with the config |
| `apk add sqm-scripts luci-app-sqm kmod-amneziawg amneziawg-tools luci-proto-amneziawg` | pass, from our repository and OpenWrt's feeds |
| SQM | pass: the carried queue starts cake on the WAN |
| AmneziaWG | pass after `/etc/init.d/network restart` (netifd only learns a newly installed protocol on a restart): `awg0` up with its address and peer |
| kernel warnings | none |

A sysupgrade does not keep installed packages; what carries over is the
configuration, and the packages are added again from v2's repositories.

## C3: wired

NAT44 through the NSS firmware, 4 streams each way, wired LAN client to a WAN
host: 941 Mbit/s up, 941 Mbit/s down, all flows accelerated (NSS counters),
no frames leaked to the LAN (b9). PPPoE on a WAN VLAN was measured on kuncy7's
image itself (933 / 930 Mbit/s) and runs on b16 in C13.

QinQ (a VLAN on a WAN VLAN, `wan.20.30`), 4 streams each way to a host on that VLAN:
936 up, 936 down Mbit/s NAT44 (twice) and 923 / 923 routed IPv6, all
flows offloaded, `[20][30]` on the wire, nothing on the LAN (b18 + 0959e, ECM without
0053). Without 0959e the same test moves no data in either direction, on the host path
as well as offloaded: the switch accepted 1522-byte frames, an MTU-sized QinQ frame is
1526, and `RxBadPktBytes` on the CPU and WAN ports took every one. With 0959e but ECM
release 2 (0053) QinQ runs on the host path at 124 / 177. On the 0959e image a
single WAN VLAN gives 939 / 939, PPPoE on a WAN VLAN 934 / 934 and the
untagged WAN 941 / 941, all offloaded.

b19 (0959e, ECM release 3, and the memory changes below), same rig: QinQ 936 / 936 (twice), IPv6 over QinQ 923 / 922, single WAN VLAN
939 / 938, PPPoE on a WAN VLAN 934 / 934, untagged WAN NAT 941 / 940, every flow
accelerated, nothing from the WAN on the LAN.

## C4: Wi-Fi

One session per band: association, iperf3 both ways, three 32 MiB downloads
checked by sha256. Pass means at least 90 % of v1.14's rate in the same mode
and 3/3 hashes.

| Build, mode | 5 GHz up / down | 2.4 GHz up / down | v1.14 reference (5 / 2.4 GHz) |
|---|---|---|---|
| v2.0.1, NSS offload | 297 / 345, 294 / 348 | 24 / 58, 20 / 58 (channel 6, Bluetooth off; the upload varies by boot, see [v2.0.1](#v201)) | 288 / 345, 29 / 45 (v1.14-nss) |
| v2.0.1, host | 186 / 294 | 36 / 58 (channel 6, Bluetooth off) | 273 / 236, 32 / 48 (v1.14 plain) |
| rc1 (b19 sources), NSS offload | 287 / 338 | 32 / 55 (channel 6) | 288 / 345, 29 / 45 (v1.14-nss) |
| rc1, NSS offload | 298 / 349 | 44 / 58 (channel 6) | 288 / 345, 29 / 45 (v1.14-nss) |
| rc1 (b21 sources), NSS offload | 287 / 346, 290 / 338 | 50 / 60 (channel 6, Bluetooth off); 25 / 37 with it streaming audio | 288 / 345, 29 / 45 (v1.14-nss) |
| b21, NSS offload | 292 / 346, 302 / 350 | not comparable: 33 / 35, 7 / 28 with the test client's Bluetooth streaming audio | 288 / 345, 29 / 45 (v1.14-nss) |
| b19, NSS offload | 286 / 337 | 39 / 56 (channel 6) | 288 / 345, 29 / 45 (v1.14-nss) |
| b18, NSS offload | 278 / 320 | 46 / 58 (channel 6) | 288 / 345, 29 / 45 (v1.14-nss) |
| b18, host | 257 / 294 | 29 / 36 (channel 6, daytime) | 273 / 236, 32 / 48 (v1.14 plain) |
| rc1-a, NSS offload | 296 / 334 | see below | as below |
| b16, NSS offload | 296 / 335 | 50 / 57 | 288 / 345, 29 / 45 (v1.14-nss) |
| b9, NSS offload | 294 / 349 | 36 / 53 | as above |
| b9, host | 284 / 315 | 36 / 47 | v1.14 plain |

(Mbit/s; the 2.4 GHz AP runs 20 MHz, on channel 1 up to b16 and on channel 6 from b18
on, and the client is 1x1.)

2.4 GHz rates depend on the channel's load and on the test client's Bluetooth (its
Wi-Fi and Bluetooth share one chip). With channel 1 57 % busy with other networks,
v1.14-nss carried 0-2 Mbit/s on 2.4 GHz and rc1-a failed its 2.4 GHz sessions the same
way; with the client streaming audio over Bluetooth every build dropped. The 2.4 GHz
numbers above are from quiet hours with Bluetooth off unless the row says otherwise.

## C5: signal and noise floor

v1.x adds +31 dB (2.4 GHz) / +24 dB (5 GHz) to every signal it reports (patch 952); v2
does not, so every v1.x reading is that much higher. On rc1 (NSS and host Wi-Fi modes,
client about 1 m away, TX power of both ends stepped down to 10 dBm and up again):

- **Same receiver, two paths.** For the same client and frame rate, the station signal and
  the signal hostapd gets with the client's probe, auth and assoc frames agree within 2 dB
  (2.4 GHz: -27.5 against -27..-29 dBm; 5 GHz: -28 against -28..-30 dBm), the same in both
  modes. Scan results come from the same firmware event as those frames. The ACK signal
  (host mode) reads -25 dBm on 2.4 GHz.
- **Reciprocity.** With both ends at 10 dBm, the router reads the client's 80 MHz frames at
  -50..-53 dBm and the client reads the router's at -52..-53 (5 GHz): the router reads 0 to
  2.5 dB higher, which its two receive chains account for. On 2.4 GHz the router reads
  -35..-36 in every run, the client -25 in one run and -44..-45 in two: the client card's
  2.4 GHz readings jump by about 20 dB (its Bluetooth, on the same chip, was in use), so
  it cannot check 2.4 GHz closer than that.
- **Physics.** The router reads the client at -27.5 dBm on 2.4 GHz while the client sends
  15-17 dBm (from the drop when it is capped at 10 dBm): 42-45 dB of path, against 40 dB of
  free space at 1 m. v1.x would show +3.5 dBm, a path of 11-14 dB, which antennas about 1 m
  apart cannot have.
- **Neighbour networks.** The router's scan reads 5 GHz access points 3.5-12.5 dB above the
  client card (median 8.5 and 9 in two runs): its two chains and better antennas, not 24 dB
  low.
- **Noise floor.** The survey reads -98/-96 dBm (2.4 GHz) and -91 dBm (5 GHz), next to the
  firmware's own channel noise floor (-96, -92) and Xiaomi's firmware (-96, -91). Without
  952's noise-floor half the 5 GHz survey would read -111 dBm.

The raw values are the same in both Wi-Fi modes: the firmware's `rssi_comb` plus -95 (the
firmware does not offer DB2DBM).

## C9: recovery from Q6 firmware crashes

Two events, each on either radio: a firmware assert, which takes the Q6 root
PD down and both radios with it, and a hw-restart, the reset ath11k asks for
itself. After each, the client joins the radio's band again and fetches a
hashed payload, then both bands carry an iperf3 session and three 32 MiB
downloads checked by sha256; the boot must not change and the kernel must log
no warning. b18, 2.4 GHz AP on channel 6:

| Mode | Event | Result | Client back with a verified payload after |
|---|---|---|---|
| NSS offload (default) | hw-restart, 2.4 GHz x5, 5 GHz x5 | 10 / 10, in place | 6-18 s |
| NSS offload | assert, 2.4 GHz x3, 5 GHz x3 | 6 / 6, in place | 7-18 s |
| NSS offload | driver reload x5 | 5 / 5 (a first run lost one 2.4 GHz session to a missed authentication ACK; the radio was fine right after); on his 10.09 base: on 10.19 and later the handshake fails after it, see [v2.1.0](#v210) | |
| host | hw-restart, 2.4 GHz x5, 5 GHz x5 | 10 / 10, in place | 3-7 s |
| host | assert, 2.4 GHz x3, 5 GHz x3 | 6 / 6, in place | 3-5 s |
| host | driver reload x5 | 5 / 5 | |

The radios themselves are back 1-2 s after the event; the rest is the client
being disconnected (so that it rejoins with fresh keys, 960) and joining
again. No driver reload and no reboot is involved: ath11k_ahb spawns the user
PDs again on the restarted root PD (975), and with NSS offload the ring
pointers of the previous firmware are cleared (979, upstream f51e4b3b5574) and
the NSS VAP nodes and peers released before the NSS teardown (980, 981). A
fatal the root raises while it is being restarted for a hw-restart is
absorbed by that restart (983).

rc1 (b19 sources), NSS offload: a 2.4 GHz hw-restart recovered in place with the
client back in 6.1 s and a 5 GHz assert in 5.9 s, same boot, no warning; C4 passed on
both bands afterwards.

b19 (with the memory changes, the NSS 256 MiB profile among them), NSS offload,
same campaign: hw-restart 10 / 10 and assert 6 / 6 in place, client back with a
verified payload in 6-8 s, driver reload 5 / 5, no kernel warning.

5 GHz AP on a DFS channel (52 at 80 MHz, country BR), after the 60 s CAC, NSS
offload. rc1 (b19 sources), assert: the radios recovered in place, but 5260 MHz
went from "available" to "usable" within 5 s, and 60-70 s after the crash the AP
lost its carrier and channel for good, hostapd still reporting it enabled
(kuncy7/openwrt-nss-edma#28: ath11k applies its regulatory domain again after a
restart, and cfg80211 then forgets the CAC). b21, with tree patch 0006: assert
and hw-restart, 5260 MHz stayed available and the AP kept carrier and channel
to +120 s both times; rc1 (b21 sources) and rc1, assert, the same.

A station attached through the event and passing traffic from the first second
(the test client on 2.4 GHz, pinging the router 5 times a second; a 2.4 GHz
hw-restart every 75 s; NSS offload): the station was back after about
6 s each time. Without `wpa_pairwise_update_count=8` 7 of 22 rejoins failed the
4-way handshake and backed off 10 s (#25: NSS holds the radio's RX for a few
seconds after the restart, then delivers it at once); with it, 0 of 22, so b21
sets it on every AP interface (`97-rd03v2-four-way-retries`).

**The board reset twice** in those runs, both on the first rc1 build (b19
sources) and both among the 15 restarts without that setting that had traffic
afterwards (45 had traffic afterwards in all: 29 on that build, 8 on b21, 4 on
each of the two later rc1 builds): 23-24 s after the restart the
station's pings stopped, the board stopped answering on the wired LAN too, and
it rebooted a minute later (UBIFS recovery on the next boot, so not a clean
reboot; no watchdog decision on record). Both came in the first hour after the
first install from stock; none came in the 43 restarts with traffic since, with
or without the setting, after reboots or not. The cause is not known: there is
no console on this unit and no pstore in this kernel, and the log streamed to
the test host for the later runs caught no reset. The last 4 ran on rc1 itself,
installed from stock: in place, the station back after about 6.3 s each time, same
boot, no warning. The reset also left `/etc/board.json` empty, which kept the radios
down on every boot after it; b21 generates it again at boot (`81_rd03v2_board_json`).

## Memory (b19)

MemAvailable with both radios up, NSS offload, idle, at 5 / 15 / 25 min after boot:

| Image | MemAvailable |
|---|---|
| v1.14-nss | 35.4 / 34.5 / 33.8 MB |
| b18 (before) | 20.7 / 17.3 / 21.1 MB (12.6 MB in one 40 min sample) |
| b19 | 41.9 / 41.7 / 41.9 MB |

Where it went before b19: 6-18 MB of free pages parked on the per-CPU
lists (10 MiB per CPU allowed with `min_free_kbytes` 16384; uncounted in MemFree and
MemAvailable, so kswapd evicted page cache), and 6-8.5 MB more held by the Wi-Fi stack than
on v1.14, growing with uptime: long-lived ring buffers pinning shared 32 KiB page-frag
chunks (v1.x's skb recycler avoided it), host TX arrays NSS never uses, TX pools sized for
8192 per radio. b19 caps the per-CPU lists, turns on kuncy7's optional NSS 256 MiB ath11k
profile and gives each CE RX pipe its own page-frag cache (984). Reserved memory in the
device tree is identical to v1.14 and was not a cause.

Under use, b19: the first Wi-Fi client session takes about 6 MB of buffers, then MemAvailable
stays at 34-36 MB over eight more sessions on both bands; eight in-place recoveries without
traffic moved it by 0.5 MB, and a driver reload gives the buffers back (40-42 MB after).

## C10: the watchdog against user actions (NSS mode, b16)

| Action | Expected | Result |
|---|---|---|
| `wifi down` for 4 min | "taken down on purpose", nothing done | pass |
| one radio disabled in UCI for 4 min | the same, for that radio | pass |
| `rmmod ath11k_ahb ath11k` by hand | detected, ath11k reloaded, recovered, no reboot | pass, same boot (from v2.1.0, with NSS offload: a reboot) |
| a fourth incident within an hour | reboot (its budget is three recoveries an hour) | pass |

**After a channel change** (rc1 (b21 sources)): OpenWrt applies a new
channel with a CSA, and ath11k left the channel in use on the old one; the
survey then showed the old channel in use with frozen counters, the watchdog
reported "survey freeze" 2-3 minutes later and, past 10 minutes of uptime,
reloaded ath11k (seen after 5 GHz 52 -> 36 and 2.4 GHz 1 -> 6 and 6 -> 11; the
reload itself recovered). rc1 with 985: after 2.4 GHz 1 -> 6 and 5 GHz 36 -> 52
(an assert there) -> 36, the channel in use followed each switch, its counters
moved, and the watchdog did nothing in 21 minutes of uptime.

The watchdog's own scenario suite (43 scenarios, the router's BusyBox through
qemu and the host's) runs in every build. The release candidate ships
`inplace` unset, which now means off in both Wi-Fi modes: an incident without
a crash goes straight to the driver reload, which recovered every time (from v2.1.0, with
NSS offload, a reboot instead); the
ath11k reset needs `uci set rd03v2-watchdog.main.inplace=1`.

## C8, C14: NFC tap, buttons and LEDs, by hand (rc1)

On rc1 installed from stock; each step checked on the router as well (its log,
LED state in sysfs, the boot id):

| Check | Result |
|---|---|
| LEDs: both off, blue, yellow, both, blue dim, yellow dim, blue blinking, driven through sysfs | pass, each as expected |
| NFC `wifi` mode: an Android phone taps the tag | pass: it offered the network and joined it, no password typed (WPA2 4-way completed in the AP's log) |
| NFC `clear` mode: the same tap | pass: the phone reports an empty tag |
| mesh button, short press | pass: registered as `wps`; no WPS configured, nothing changes |
| reset button, short press | pass: reboots, back with both APs and no warning |
| reset pressed during the early boot blink | pass: failsafe (yellow blinking 50/50 ms, read-only root, lan2 at 192.168.1.1, root without a password) |
| reset held until yellow blinks (5 s) | pass: factory reset; back with OpenWrt's defaults (both APs off, no root password, NFC `clear`) |

## C12: packages

From our repository, signed with our key, on the image of the same build:
WireGuard and AmneziaWG (tools, LuCI protocols) installed and carried traffic
(WireGuard, 4 streams between the router itself and a PC: 109 / 300 Mbit/s up / down), the SQM
LuCI page and its NSS qdisc script installed, and an `apk upgrade` simulation
kept every pinned package of his tree (b9).

AmneziaWG on v2.0.0 (#39), installed from the published repository with
`apk add kmod-amneziawg amneziawg-tools luci-proto-amneziawg` (11 packages):

| Check | Result |
|---|---|
| AWG 2.0 tunnel (S3/S4, H ranges, I1) to `amneziawg-go` on a PC, after `/etc/init.d/network restart` | handshake; a LAN client through it at 49 / 31 Mbit/s down / up, CPU saturated |
| Ordinary WAN NAT with the tunnel up | 941 / 938 Mbit/s, CPU 95 % idle: still offloaded |
| Reboot with the tunnel configured | up at about 28 s uptime, handshake, LAN ping through it |
| LuCI "Load configuration…" (headless browser, staged with Save, then reverted) | keys, address, DNS, every AWG 2.0 field and the peer staged; Route Allowed IPs left off |
| Full tunnel (`0.0.0.0/0`, `route_allowed_ips`) | default route on the tunnel, LAN traffic enters it, the endpoint stays on the WAN, handshake holds |
| Full tunnel taken down | no IPv4 default route left: the tunnel's route had replaced the WAN's (both metric 0). With `network.wan.metric=10` both stay and the WAN takes over |
| Peer changed, then a network reload | not applied until the interface restarts |
| `apk del` of the three packages | all 11 removed; package list and `/etc/config` identical to before |

WireGuard on v2.0.0 (#45), with `apk add luci-proto-wireguard` from the published repository
(11 packages, installed while OpenWrt's feeds answered 503: our repository carries the
userspace too): handshake after `/etc/init.d/network restart`, a LAN client through it at
36 / 67 Mbit/s up / down (host path, CPU-bound), removed cleanly.

## C15: hardening

`apk` refuses a package whose authenticated contents were changed, one signed
with an unknown key, and an index that is incomplete or does not match (8
checks, b9).

## Closed-issue regression pass (rc1)

Every closed GitHub issue, re-checked against v2 on the bench. Passing or not
applicable to v2's stack: #3, #5, #7 (roam, downstream unicast immediate), #8,
#9, #10, #11 (vlan_filtering on/off and a reboot with it on, host path kept;
reserved-VID guard in 0959d), #12, #15, #22, #23, #25, #26, #34 (GB channel 149,
kept through a hw-restart and an assert), #37 (kmods from our repository). #18
(slow receiver on 5 GHz under full WAN load, NSS and host): no stall, no OOM,
memory recovered. Three findings:

- **#21**: 802.11s mesh does not come up with NSS offload (not built on this
  256 MB board) and takes that radio's AP down while configured; patch 986 now
  logs the cause and the remedy, and mesh works in host mode. A regression from
  v1.11's NSS mesh. See Known issues in the README.
- **#24**: fixed on rc1 by our patch 995 (ethernet `frame_mode` under NSS): set
  to 1, the driver forced 2 and a client associated. On 10.15-2 his nss-tools sets
  `frame_mode=2` wherever it loads ath11k, 995 is gone, and the same check passes
  (b22).
- **#36** (ECM/mwan3 IPv6 stall) was not reproduced on the bench; v2's ECM has
  no FIB-rule notifier, so the full mwan3 + PPPoE rig would be needed to settle it.

#1 (LAN<->LAN) was not run (one wired client; it would bridge the WAN to the
upstream LAN).

## Not carried over from v1.x checks

C7: the calibration payloads the firmware
loads are byte-identical in v1.x's board files, kuncy7's tree and his image, so
no RF comparison was needed. C11: the 72-hour soaks were not run.
