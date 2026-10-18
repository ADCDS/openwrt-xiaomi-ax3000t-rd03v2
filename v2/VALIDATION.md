# v2 validation

What v2.0.0 was tested on before release, and what it was not. Everything
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
[On ipq50xx-2026.10.15-2](#on-ipq50xx-20261015-2-b22-v200).

Each result names the build it ran on. The test builds (`v2.0.0-local.bN`) come
from the same tree as the release, built with `v2/build.sh`; a release build
differs from its test build only in its version stamp and repository address.

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
| b22 | his `ipq50xx-2026.10.15-2`: 16 of our patches dropped as his (see [the README](README.md#already-in-his-tree-not-carried)), our 10 ath11k patches in `patches/nss-extra` |
| v2.0.0 | the release: b22's sources without `81_rd03v2_board_json` (his `/etc/board.json` is in tmpfs), built fresh |

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
| C4 | Wi-Fi, both modes, both bands | pass (b9, b16, b19, rc1 each build); 2.4 GHz needs the test client's Bluetooth off, see below | b9-rc1 | pass: 274 / 324 on 5 GHz, 39 / 58 on 2.4 GHz (v2.0.0); 276 / 341 on 5 GHz (b22) |
| C5 | Signal and noise floor in dBm | pass on 5 GHz (within 3 dB); 2.4 GHz within about 10 dB; v1.x reads 24-31 dB high | rc1 | noise floor -96 / -91 dBm (b22); otherwise not re-run: same ath11k conversion and patches |
| C6 | Regulatory: GB, US, DE, both Wi-Fi modes | pass | b9 | GB channel 149 at 23 dBm, kept through two recoveries (b22, #34); US and DE not re-run |
| C7 | Board data | byte-identical to v1.x and kuncy7 | - | board data and Wi-Fi firmware byte-identical to rc1's (b22) |
| C8 | NFC tag | pass, including a phone tap in both modes | b9, rc1 | the tag holds the configured network, in sync (b22); the phone tap not repeated |
| C9 | Recovery from Q6 firmware crashes, both Wi-Fi modes | pass, in place; a DFS AP stays up (b21, rc1); **2 board resets in 45 recoveries with a station passing traffic, cause not found** | b18-rc1 | pass, in place, about 20 events with no reset and no warning; a DFS AP stays up (b22, v2.0.0) |
| C10 | Watchdog against user actions | pass | b16 | pass (b22) |
| C11 | Memory | 42 MB available idle, 34-36 MB in use, no drift; a multi-day soak not run | b19 | 42 MB available idle at 5 / 15 / 25 min; 100 min of Wi-Fi traffic: flat at 40 MB (b22) |
| C12 | Packages from our repository, tunnels, SQM | pass | b9 | kmods and AmneziaWG from the build's repository (b22) |
| C13 | Upgrade from a realistic v1.x install | pass | b16 | not re-run; the migration's assumptions checked against his nss-tools |
| C14 | Buttons and LEDs | pass: both LEDs, both buttons, reboot, failsafe, factory reset | b9, rc1 | not re-run (no hardware or device tree change) |
| C15 | Package signature failures | pass, 8 checks | b9 | not re-run (same signing) |

## On ipq50xx-2026.10.15-2 (b22, v2.0.0)

His 10.15 release under v2: mac80211 backports 7.2 with his ath11k series in
`patches/nss` and `patches/nss-extra`, multi-PD for the QCN6122 with his own user-PD
respawn (his 976), NSS firmware 12.5 for the 256 MB group, kernel 6.18.55, and a
reworked wifi-scripts that keeps `/etc/board.json` in tmpfs. What v2 dropped as his,
and what it still carries, is in the [README](README.md#what-v2-adds-to-his-release).

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
reloaded, both radios back, same boot.

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
| NSS offload | driver reload x5 | 5 / 5 (a first run lost one 2.4 GHz session to a missed authentication ACK; the radio was fine right after) | |
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
| `rmmod ath11k_ahb ath11k` by hand | detected, ath11k reloaded, recovered, no reboot | pass, same boot |
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
a crash goes straight to the driver reload, which recovered every time; the
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
(WireGuard, 4 streams: 109 / 300 Mbit/s up / down on the LAN tunnel), the SQM
LuCI page and its NSS qdisc script installed, and an `apk upgrade` simulation
kept every pinned package of his tree (b9).

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
