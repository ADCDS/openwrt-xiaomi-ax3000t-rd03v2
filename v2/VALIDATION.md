# v2 validation

What the v2 release candidate was tested on before release, and what it was
not. Everything here ran on one Xiaomi AX3000T (RD03v2, 256 MB), installed on
NAND, with:

- a wired client on a LAN port (1 GbE), the WAN port on an upstream LAN with
  internet access, and a PPPoE server on a WAN VLAN;
- one Wi-Fi client (a 1x1 QCA9377 card, about 1 m away) that joins the bench AP
  on each band;
- references measured on the same bench: v1.14 and v1.14-nss of this port
  ("B"), and kuncy7's `ipq50xx-2026.10.09` image as he publishes it ("K").

The test builds come from the same sources as the release candidate, built
from a clean tree; the release candidate differs from the last one (b19) only
in its version stamp and its repository address. Each result names the build
it ran on; "rc1-a" is the first build of the release candidate (b16 plus the
watchdog default), superseded before publication by the NSS in-place fix.

**Not tested:** a multi-day soak (the longest single runs were hours), more
than one unit of the hardware, and RF performance beyond throughput at one
distance. The reset button, the LEDs and an NFC tap with a phone are checked by
hand, separately (C8, C14).

## Summary

| | Check | Result | Build |
|---|---|---|---|
| C1 | Install, upgrade and rollback paths | see below | b5-rc1-a |
| C2 | Reboots, half of them power cuts | pass: 20 / 20 (b9), 4 / 4 (rc1-a) | b9, rc1-a |
| C3 | Wired through NSS: NAT, WAN VLAN, PPPoE on a WAN VLAN, QinQ, IPv6 over QinQ | pass, all offloaded, 923-941 Mbit/s | b9, b19 |
| C4 | Wi-Fi, both modes, both bands | pass (b9, b16, b19, rc1); see below for 2.4 GHz in the daytime | b9-rc1 |
| C5 | Signal and noise floor in dBm | pass on 5 GHz (within 3 dB); 2.4 GHz within about 10 dB; v1.x reads 24-31 dB high | rc1 |
| C6 | Regulatory: GB, US, DE, both Wi-Fi modes | pass | b9 |
| C7 | Board data | byte-identical to v1.x and kuncy7 | - |
| C8 | NFC tag | pass; phone tap by hand | b9 |
| C9 | Recovery from Q6 firmware crashes, both Wi-Fi modes | pass, in place | b18, b19, rc1 |
| C10 | Watchdog against user actions | pass | b16 |
| C11 | Memory | 42 MB available idle, 34-36 MB in use, no drift; a multi-day soak not run | b19 |
| C12 | Packages from our repository, tunnels, SQM | pass | b9 |
| C13 | Upgrade from a realistic v1.x install | pass | b16 |
| C14 | Buttons and LEDs | registered; physical check by hand | b9 |
| C15 | Package signature failures | pass, 8 checks | b9 |

## C1: install, upgrade and rollback

| Path | Result | Build |
|---|---|---|
| v1.14-nss -> v2 through the RAM installer, keeping a v1.x config (VLANs, the v1.x NSS knobs and disabled services that the migration handles) | pass | b5, b10d6, rc1-a |
| v2 -> v2, keeping settings | pass | b10d2, and every candidate since (b12 -> b16) |
| v2 -> v1.14-nss (rollback), with a v1.x config | pass: v1.14-nss boots with it, both APs, NSS and ECM loaded, no warnings | b16 |
| offline RAM installer from a release cache (`install.py nss-v2 --offline`) | pass | b9 |
| stock firmware -> v2 with `xiaomi-openwrt-install`, wired and over Wi-Fi | not run on the bench for this candidate | - |
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
image itself (933 / 930 Mbit/s, the gate) and runs on b16 in C13.

QinQ (a VLAN on a WAN VLAN, `wan.20.30`), 4 streams each way to a host on that VLAN:
936 up, 936 down Mbit/s NAT44 (twice) and 923 / 923 routed IPv6, all
flows offloaded, `[20][30]` on the wire, nothing on the LAN (rc1 + 0959e, ECM without
0053). On rc1 as built the same test moves no data in either direction, on the host path
as well as offloaded: the switch accepted 1522-byte frames, an MTU-sized QinQ frame is
1526, and `RxBadPktBytes` on the CPU and WAN ports took every one. With 0959e but rc1's
ECM (0053) QinQ runs on the host path at 124 / 177. On the 0959e image a
single WAN VLAN gives 939 / 939, PPPoE on a WAN VLAN 934 / 934 and the
untagged WAN 941 / 941, all offloaded.

b19 (the release candidate's sources: 0959e, ECM release 3, and the memory changes
below), same rig: QinQ 936 / 936 (twice), IPv6 over QinQ 923 / 922, single WAN VLAN
939 / 938, PPPoE on a WAN VLAN 934 / 934, untagged WAN NAT 941 / 940, every flow
accelerated, nothing from the WAN on the LAN.

## C4: Wi-Fi

One session per band: association, iperf3 both ways, three 32 MiB downloads
checked by sha256. Pass means at least 90 % of v1.14's rate in the same mode
and 3/3 hashes.

| Build, mode | 5 GHz up / down | 2.4 GHz up / down | v1.14 reference (5 / 2.4 GHz) |
|---|---|---|---|
| rc1, NSS offload | 287 / 338 | 32 / 55 (channel 6) | 288 / 345, 29 / 45 (v1.14-nss) |
| b19, NSS offload | 286 / 337 | 39 / 56 (channel 6) | 288 / 345, 29 / 45 (v1.14-nss) |
| b18 (an earlier rc1 build), NSS offload | 278 / 320 | 46 / 58 (channel 6) | 288 / 345, 29 / 45 (v1.14-nss) |
| b18, host | 257 / 294 | 29 / 36 (channel 6, daytime) | 273 / 236, 32 / 48 (v1.14 plain) |
| rc1-a, NSS offload | 296 / 334 | see below | as below |
| b16, NSS offload | 296 / 335 | 50 / 57 | 288 / 345, 29 / 45 (v1.14-nss) |
| b9, NSS offload | 294 / 349 | 36 / 53 | as above |
| b9, host | 284 / 315 | 36 / 47 | v1.14 plain |

(Mbit/s; the 2.4 GHz AP runs 20 MHz on channel 1, shared with a strong home
network, and the client is 1x1.)

**2.4 GHz on the morning of 2026-10-15.** On rc1-a the 2.4 GHz sessions failed:
the AP sometimes did not answer the client's authentication, and when it did,
the link carried 1-35 Mbit/s and a 32 MiB download timed out. The channel was
57 % busy with almost none of it the bench's own traffic. v1.14-nss, installed
for the comparison and measured right then on the same channel, carried 0-2
Mbit/s on 2.4 GHz (its 5 GHz: 284 / 323 Mbit/s, 3 / 3 hashes), so this is the
radio environment at that hour, not v2; b16, with the same Wi-Fi code as rc1-a,
had passed 2.4 GHz at 05:00. The 2.4 GHz numbers are to be measured again at
a quiet hour.

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
  2.4 GHz readings jump by about 20 dB (a Bluetooth headset was connected to it), so it
  cannot check 2.4 GHz closer than that.
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
no warning. b18 (the release candidate's sources), 2.4 GHz AP on channel 6:

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

The release candidate itself (rc1, built from b19's sources), on the bench
NAND, NSS offload: a 2.4 GHz hw-restart recovered in place with the client
back in 6.1 s and a 5 GHz assert in 5.9 s, same boot, no warning; C4 passed on
both bands afterwards.

b19 (with the memory changes, the NSS 256 MiB profile among them), NSS offload,
same campaign: hw-restart 10 / 10 and assert 6 / 6 in place, client back with a
verified payload in 6-8 s, driver reload 5 / 5, no kernel warning.

How it got there (all on the bench):
- b16, NSS offload, without 979-981: radios back beaconing, but no client
  completed a 4-way handshake, and a client's attempt faulted the IPQ5018 PD
  (NOC error). v1.x had met the same with its NSS stack and fixed it with the
  same patches; kuncy7's ipq50xx-2026.10.12 carries them too.
- b16, host mode, before 979: a third hw-restart in one boot left the 2.4 GHz
  radio deaf. Not seen on b18 (10 / 10).
- b17, NSS, before 983: one 5 GHz hw-restart in three raised a root fatal
  during the planned root restart, which the remoteproc crash handler then
  restarted a second time under the spawned PD; the 5 GHz radio was lost.

## Memory (b19)

MemAvailable with both radios up, NSS offload, idle, at 5 / 15 / 25 min after boot:

| Image | MemAvailable |
|---|---|
| v1.14-nss | 35.4 / 34.5 / 33.8 MB |
| rc1 (before) | 20.7 / 17.3 / 21.1 MB (12.6 MB in one 40 min sample) |
| b19 | 41.9 / 41.7 / 41.9 MB |

Where it went on rc1 (the memory deep dive): 6-18 MB of free pages parked on the per-CPU
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
| a fourth incident within an hour | reboot (its budget is three recoveries an hour) | pass (seen when C10 first ran right after the C9 asserts) |

The watchdog's own scenario suite (43 scenarios, the router's BusyBox through
qemu and the host's) runs in every build. The release candidate ships
`inplace` unset, which now means off in both Wi-Fi modes: an incident without
a crash goes straight to the driver reload, which recovered every time; the
ath11k reset needs `uci set rd03v2-watchdog.main.inplace=1`.

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

## Not carried over from v1.x checks

C7: the calibration payloads the firmware
loads are byte-identical in v1.x's board files, kuncy7's tree and his image, so
no RF comparison was needed. C11: the 72-hour soaks were not run.
