# Experimental RD03v2 NSS Wi-Fi: integration and hardware results

This opt-in build adds the qosmio ath11k NSS series to this repository's
smallbuffers package, plus three fixes needed on an IPQ5018/QCN6122 RD03v2.
It completed a full image build and a local wired-to-5GHz hardware test.
It is not a claim of production readiness or a WAN benchmark.

## Reproduce the build

Use a fresh checkout on a Linux filesystem (including WSL2), with the normal
OpenWrt build prerequisites plus Python 3. The donor is intentionally pinned:

```sh
git clone https://github.com/qosmio/openwrt-ipq.git ../wifi-nss-donor
git -C ../wifi-nss-donor checkout 92a2d104145c8d265851c4b388a41bd8e9c21cd9
NSS=1 WIFI_NSS_DONOR="$(realpath ../wifi-nss-donor)" JOBS=2 bash build.sh
```

The donor must be clean. Without `WIFI_NSS_DONOR`, ath11k NSS remains disabled.
`PREPARE_ONLY=1` stops after configuration. The integration retains SMALLBUFFERS,
selects NSS firmware 12.5 and the LOW NSS memory profile, and assigns radio
priorities 0/1 to the board's `wifi`/`wifi1` labels. It tracks memory-profile
configuration changes in the NSS driver's package stamp. Mesh and generic
mac80211 redirect remain disabled. The existing firmware memory mode is retained.

Four donor patch overrides preserve the device's small-buffer definitions and
rebase surrounding contexts; original patch authorship is retained. The donor
series itself is fetched from the pinned source, not re-attributed here.
Optional LibreSpeed feed links are excluded in this mode because their virtual
providers caused a Kconfig cycle in the tested feed set. This does not delete
feed sources. `wifi-nss-feeds-lock.txt` records feed revisions after preparation;
the base build's moving feeds mean a later build need not be byte-identical.

To audit the complete backports patch sequence without compiling or flashing:

```sh
sh tools/check-wifi-nss-port.sh "$HOME/rd03v2-wifi-patch-audit"
```

Use a new output directory. Inspect `patches.log` for offsets/fuzz. Patch
application alone is not ABI or runtime validation. Installation still requires
the [RAM-initramfs pivot](no-uart-reflash.md); this feature does not change the
board's flash procedure. Do not mix kernel modules from different builds.

## Fixes and evidence

### QCN6122 register addressing

The hybrid QMI mapping sets `ab->mem` but did not retain `resp.bar_addr` in
`ab->mem_pa`, which the NSS ring setup consumes. QCN6122 also lacked the HIF
window-offset callback. Preserve the BAR and use the existing AHB window
translation, whose first DP window differs from the PCI implementation's third
window. On the tested board the BAR is `0x81e00000`, length 2 MiB.

Before this correction, joining a 5GHz peer triggered an NSS firmware crash.
After it, peer join and router-to-peer TCP completed. That alone did not repair
accelerated bridging; the two subsequent fixes address separate failures.

### ECM tag_8021q metadata on bridged connections

Patch 0027 supplies DSA VLAN metadata only for routed connections. A wired LAN
port bridged to a Wi-Fi NSS interface has `is_routed=0`, so it misses that step.
Apply the same guarded lookup to bridged IPv4 and IPv6 ported rules. The existing
helper still declines non-DSA, non-tag_8021q and VLAN-aware-bridge cases; existing
VLAN fields remain protected by per-side NOT_CONFIGURED checks.

Before this correction, new iperf3 control connections stalled with ECM enabled
but completed with the IPv4 ECM frontend stopped. Afterwards, wired-to-Wi-Fi
TCP reached 838.89 Mbit/s in an intermediate run with NSS packet/hash-hit
counters increasing. IPv6 was compiled but was not runtime-tested.

### Receive pause on the switch-facing GMAC

The PHY-less MAC2 starts with RX flow control disabled although the AN8855 CPU
port sends pause frames. In a controlled Wi-Fi-to-wired run, TCP throughput was
116.06 Mbit/s and both TCP retransmissions and the LAN port's FlowControlDrop
counter increased by exactly 464. Temporarily enabling only GMAC RX pause raised
throughput to 767.89 Mbit/s with zero retransmissions or additional drops.

The permanent patch invokes the existing HAL callback at the end of netdev open,
after HAL/data-plane startup, including NSS takeover. It is restricted to the
RD03v2 compatible, MAC2 and no attached PHY; TX pause is unchanged. A read-only
register check after boot confirmed flow-control value `0x4` without the temporary
write module, and the value remained `0x4` after traffic.

## Final installed-image test

Hardware: one RD03v2, 256 MB RAM, IPQ5018 + QCN6122 + AN8855. A wired WSL2 host
and one 5GHz client shared the default VLAN-unaware LAN bridge. The client's
iperf3 server was used for one TCP stream, 10 seconds per direction:

```sh
iperf3 -c <wifi-client> -t 10 -J       # wired -> Wi-Fi
iperf3 -c <wifi-client> -t 10 -R -J    # Wi-Fi -> wired
```

| Direction | Receiver throughput | TCP retransmissions |
| --- | ---: | ---: |
| Wi-Fi -> wired | 808.89 Mbit/s | 0 |
| Wired -> Wi-Fi | 765.32 Mbit/s | 2 |

After both tests, the LAN port FlowControlDrop counter was zero. During upload,
NSS IPv4 reported 739,755 TX packets and 739,757 hash hits; the ECM frontend was
enabled. MemAvailable after testing was 31,272 KiB. The inspected final kernel
log had no OOM, fatal/assert or firmware-crash matches. Squashfs boot, installed
module hash, and persistent 5GHz enablement were checked.

Tested inputs: device base `1fd77be79514d3180c87e5e5a262de0546f1b0c5`, OpenWrt
`25ee12629edcc38feffbd06255dd47840cd7af7e`, Linux 6.12.94, backports 6.18.26,
NSS firmware 12.5, and the donor commit above. Historical Build09 hashes:

```text
sysupgrade  84f7dec818789c84be16770cba440d2ec80868073b9391148c737b2f89328a05
qca-nss-dp  647b6c0d0c262e5e6addc74a4cbd4a7882054d4700c8c4b83ab97c3cd6a5e77c
```

These identify the tested artifacts, not expected hashes of a future rebuild.
The source integration was consolidated after the hardware test; no new speed
claim is inferred from that cleanup.

Contribution checks: the complete backports patch audit passed from fresh
downloads; all resulting ath11k C/header files matched the installed build's
prepared sources byte-for-byte. Generated mac80211 Makefile/ath.mk and radio DTS
also matched. Both ECM hunks and the NSS-DP hunk reverse-applied at zero fuzz
against the tested build. Shell/Python syntax checks and the existing AN8855
divergence guard passed (23 expected differing functions). The final installed
configuration passed the integration checker. The cleaned build wrapper itself
has not undergone another full image rebuild.

Not covered: WAN/NAT, runtime IPv6 acceleration, long-duration or many-client
load, guest isolation, VLAN-aware bridges, mesh and recovery under NSS Wi-Fi
load. The original stock/NSS-without-Wi-Fi whole-router hang is not proven to
have the same cause as the QCN6122 NSS peer-join crash diagnosed here.
