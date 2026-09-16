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
selects NSS firmware 12.5 and the MEDIUM NSS memory profile (the existing NSS
build's; `WIFI_NSS_MEM_PROFILE=LOW` selects LOW, which caps accelerated
connections at 512 per IP family — note stock RD03v2 runs exactly that 512, so
the cap alone is not the argument for MEDIUM; see the rationale in
`tools/integrate-wifi-nss.py`), and assigns radio
priorities 0/1 to the board's `wifi`/`wifi1` labels. It tracks memory-profile
configuration changes in the NSS driver's package stamp. Mesh and generic
mac80211 redirect remain disabled. The existing firmware memory mode is retained.

Four donor patch overrides preserve the device's small-buffer definitions and
rebase surrounding contexts; original patch authorship is retained. Two RD03v2
patches follow the series: `999-998` moves the NSS teardown in firmware-crash
recovery after the interrupt quiesce added by `953` (the donor hunk lands before
it) and clears freed tx-descriptor addresses so a failed re-setup cannot free
them twice; `999-999` is the QCN6122 register fix below. `999-996` keeps
`sta_state` from returning with `conf_mutex` held, and the other
`999-999-rd03v2-*` patches are described under "Crash recovery with offload on"
and "ECM VLAN tags for Wi-Fi over a VLAN-aware bridge". The donor
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

### ECM VLAN tags for Wi-Fi over a VLAN-aware bridge

With `vlan_filtering=1` on br-lan, accelerated flows between a Wi-Fi VAP and
anything else stalled once ECM pushed the rule, and passed with the IPv4 ECM
frontend stopped. The AN8855 CPU port is a tagged member of every bridge VLAN,
but the rules did not say so:

- Bridged DSA port <-> VAP: the 0027 helper declines VLAN-aware bridges, and the
  NSS frontend never reads ECM's bridge VLAN filter data, so the rule had no VLAN.
  The NSS forwarded the switch's tagged frames to the VAP with a 4-byte-shifted
  Ethernet header. A BCM43455 and an RT3070 client received 0 of about 9000 UDP
  frames. A QCA9377 client received them only because its shifted destination
  address happened to be multicast.
- Routed VAP <-> WAN over br-lan.N: the stock VLAN branch put the br-lan.N VID
  on the Wi-Fi side, which never carries it.

Patch 0029 takes the port's bridge VLAN from `ci->vlan_filter` for a tag_8021q
DSA port on a VLAN-aware bridge. It uses that VLAN only when the flow and return
directions recorded the same VID for the port, and refuses acceleration
otherwise. It also drops the tag on a side whose innermost interface is an
untagged, non-DSA bridge member. The bench layout was VLAN 1
untagged on lan2-4, VLAN 20 tagged on lan3, and the `rd03v2-iot` SSID on
VLAN 20. With that layout, every flow below was accelerated (`accel_mode=2`):

| Path | tiny BCM43455 5 GHz | syd RT3070 2.4 GHz | hal QCA9377 5 GHz |
| --- | ---: | ---: | ---: |
| Bridged UDP wired -> Wi-Fi, 500 pps | 3818/3818 | 3607/3824 | 3829/3829 (VLAN 20) |
| Bridged TCP up / down | 84.9 / 86.8 Mbit/s | 8.6 / 8.9 Mbit/s | 70.0 / 223 Mbit/s |
| Routed TCP to WAN, up / down | 85.2 / 86.9 Mbit/s | 8.5 / 9.4 Mbit/s | 70.6 / 201 Mbit/s |

On the wire, Wi-Fi -> wired frames left VLAN 1 untagged and VLAN 20 tagged.
Without VLAN filtering, results were unchanged: UDP 3822/3822, 3671/3827 and
3811/3811, with TCP accelerated. The kernel logged no WARN.

After the direction-consistency check was added, the same image was re-run in
all three layouts. Every flow was again accelerated with full 5 GHz UDP
delivery:

- bridged VLAN: TCP down tiny 87.1, hal 250 Mbit/s;
- routed WAN: tiny 86.7, hal 240 Mbit/s;
- no VLAN filtering: tiny 87.0, hal 246 Mbit/s.

The kernel logged no `vlan_filter_add_fail` and no WARN.

Still not accelerated (these stay on the slow path and are delivered):

- non-ported and multicast rules (not changed);
- routed flows between two VLANs of the same bridge, refused by
  `ecm_db_connection_add_vlan_filter()`;
- bridged flows to a host that uses one MAC on several VLANs of the bridge
  (`v4_ported_vlan_filter_add_fail`).

On the same VLAN-aware bridge no client got past the WPA handshake before ECM
was involved. With NSS offload hostapd receives EAPOL on a packet socket, and
M2 of the 4-way handshake reached the bridge addressed to the AP, kept its PVID
tag and was passed up on `br-lan.<vid>`, where hostapd does not listen: every
handshake timed out (reason 15) on every SSID.
`999-999-rd03v2-nss-vlan-eapol-to-pae-group` re-addresses EAPOL frames for the
AP to the 802.1X PAE group address, which the bridge passes up on the ingress
port. `999-999-rd03v2-reo-update-queue-noncoherent-free` fixes the donor's REO
update-queue cleanup, which freed `dma_alloc_noncoherent()` descriptors with
`kfree()` and hit a slab WARNING on `rmmod` after a firmware crash.

### Receive pause on the switch-facing GMAC (all builds)

The PHY-less MAC2 starts with RX flow control disabled although the AN8855 CPU
port sends pause frames. In a controlled Wi-Fi-to-wired run, TCP throughput was
116.06 Mbit/s and both TCP retransmissions and the LAN port's FlowControlDrop
counter increased by exactly 464. Temporarily enabling only GMAC RX pause raised
throughput to 767.89 Mbit/s with zero retransmissions or additional drops.

The patch (`files/package/kernel/qca-nss-dp/patches/0002-rd03v2-switch-rx-pause.patch`)
is part of every build: default, plain NSS and NSS Wi-Fi. RX pause defaults on
and is applied through the existing HAL callback at the end of netdev open, after
HAL/data-plane startup, including NSS takeover. It is restricted to the RD03v2
compatible, MAC2 and no attached PHY; TX pause is refused. A read-only
register check after boot confirmed flow-control value `0x4` without the temporary
write module, and the value remained `0x4` after traffic.

A later A/B bench on the NSS Wi-Fi image toggled pause with `ethtool` over three
15-second 5GHz-to-wired TCP runs per setting, to two different wired hosts. The
Wi-Fi link limited throughput to about 50 Mbit/s either way. With pause off the
AN8855 CPU port dropped 110-188 frames per run and TCP retransmitted 111-217
times. With pause on there were no switch drops and 14-42 retransmissions.
One slow port does delay other ports: a 5 Mbit/s 2.4GHz-to-wired UDP stream into
an idle 1 Gbit port lost 47-48 % with pause on while a 5GHz flow flooded a
10 Mbit port. With pause off it lost 53 %, and the switch also dropped about 70k
frames. The switch's shared buffer causes that blocking with or without pause;
pause did not make it worse.

A second A/B on the same image emulated a plain-NSS build: NSS Wi-Fi offload
was off (`nss_offload=0`, no `wifili` activity), so Wi-Fi traffic took the
host path while wired traffic stayed on the NSS data plane. It covered one path
only: three 15-second 5GHz-to-wired TCP runs per setting to the `lan3` host, at
32-45 Mbit/s received (the runs to the WAN host failed to connect). The switch
sent no pause frames in any run: `eth1`'s `rx_pause` counter did not move with
pause on or off, while it rose by 442-848 per pause-on run in the A/B above.
The `eth1` CPU port (p05) dropped nothing either. Pause was never asserted, so
this run shows neither a benefit nor a cost. TCP retransmitted 34-41 times per
run with pause off and 12-28 with it on; with no pause frames on the wire that
difference is Wi-Fi noise and cannot be attributed to pause.

Routed wired WAN-to-LAN TCP on the same image ran at 882-939 Mbit/s received
(per setting, three one-stream and two four-stream runs; wired only, so the
Wi-Fi offload setting plays no part). In the gateway layout the WAN port
`lan2` reaches the NSS data plane through `eth0`, and the routed stream leaves
through `eth1` into p05 towards the `lan3` host. That is the direction RX pause
throttles. Even so the switch sent no pause frames (`eth1` `rx_pause` flat in
every run) and p05 dropped nothing: 1 Gbit in to 1 Gbit out did not congest
the CPU port. This run therefore shows neither a benefit nor a cost either.
`lan2` counted 52-2,601 RxDrop in four of the ten runs, two in each mode, while
pause stayed idle. Its CPU port (p04, `eth0`) counters were not captured.

The default build was measured on two images with the same A/B (Wi-Fi to and
from the `lan3` host, TCP, all three clients, `ethtool` toggling pause). The
switch did send pause frames there: 36-42 per pause-on round on the first image
and 10 on the second, with no switch drops. With pause off the CPU port (p05)
dropped 18 frames in one of two rounds on the first image and 22 on the
second. Throughput was within Wi-Fi noise either way.

**Pending bench confirmation:** a real plain-NSS build has not been measured.
The plain-NSS emulation above never triggered pause and covered only Wi-Fi to
the `lan3` host. Still open on the plain-NSS host path are Wi-Fi to `lan2` and
the slow-port blocking test, and wired 2-to-1 fan-in into one 1 Gbit port has
not been run on any image. The patch ships in that build too because the
mechanism (a PHY-less GMAC ignoring the switch's pause frames) does not depend
on the data path. If it shows a regression, it can be switched off without a
rebuild.

#### Turning RX pause off

At runtime, until the next reboot or `qca-nss-dp` reload:

```sh
ethtool -A eth1 rx off     # rx on restores the default
ethtool -a eth1            # RX: off
dmesg | grep 'rx pause'    # eth1: rx pause off (flow control 0x0)
```

The setting survives eth1 going down and up again, including NSS takeover,
because every open re-applies the stored value. To keep it off across reboots,
use a hotplug script of its own:

```sh
cat > /etc/hotplug.d/iface/99-rd03v2-rx-pause <<'EOF'
# RD03v2: do not honour AN8855 pause frames on the switch conduit
[ "$ACTION" = ifup ] && ethtool -A eth1 rx off 2>/dev/null
EOF
echo /etc/hotplug.d/iface/99-rd03v2-rx-pause >> /etc/sysupgrade.conf
```

The `sysupgrade.conf` entry only puts the file into a settings backup made on
the installed system. On this board sysupgrade runs only from the RAM
initramfs, which has neither the file nor the entry, so a sysupgrade started
there without `-f` does not keep it (`sysupgrade -n` in the README keeps
nothing at all). To carry it over, follow `docs/no-uart-reflash.md`: run
`sysupgrade -b /tmp/config-backup.tar.gz` on the installed system, copy the
backup off the box, and flash from the initramfs with
`sysupgrade -f /tmp/config-backup.tar.gz <image>`.

Do not put it in `/etc/rc.local`. This image ships its own `rc.local`: it
re-arms the U-Boot boot flags and, on `-nss` images, writes the NSS runtime
knobs (`general/redirect`, `ipv4_accel_mode`, `ipv6_accel_mode`). It is also
listed in `/lib/upgrade/keep.d/base-files-essential`, so `sysupgrade -b` puts
it in every backup, edited or not, and `sysupgrade -f` restores the old image's
copy over the new image's. Only `sysupgrade -u -b` leaves it out, and only
while it still matches `/rom/etc/rc.local`. An edited `rc.local` is therefore
restored by every upgrade that restores a backup, and it hides any change a new
release makes to that file.

That restore applies to an unedited `rc.local` too. After a default to `-nss`
upgrade with a restored backup, the NSS runtime knobs are not written (their
effect on acceleration has not been measured; the driver already defaults both
accel modes to 1). When switching between default and `-nss` images, back up
with `sysupgrade -u -b` while `rc.local` is unedited, or after the restore run
`cp /rom/etc/rc.local /etc/rc.local` and reboot.

Nothing ships by default to turn pause off. `ethtool` is in every image: NSS
builds get it through `qca-nss-ecm` and `build.sh` adds it to the default build.

### Crash recovery with offload on

Without the two patches below, in-place recovery with `nss_offload=1`
(`simulate_fw_crash hw-restart`, or a firmware crash) leaves the radio dead: a
Q6 NOC error on IPQ5018, a radio that stops passing traffic on QCN6122. With
both, root-PD asserts and hw-restarts recover in place on the bench.

| Patch (`experimental/wifi-nss/patch-overrides/ath11k/`) | Change |
| --- | --- |
| `999-999-rd03v2-nss-recovery-1-clear-stale-lmac-srng-pointers` | Zero the shared rdp/wrp ring-pointer buffers in `ath11k_hal_srng_clear()` and the LMAC slots at ring setup (upstream fix by Kyle Farnung, Fixes 32be3ca4cf78b). |
| `999-999-rd03v2-nss-recovery-2-release-vdevs-on-restart` | Before the NSS teardown, in unload order: NSS peer deletes for the stations, VAP down, AP self peer, AP_VLAN ext vdevs, VAP delete. Runs from `ath11k_core_halt()` on hw-restart and from `reconfigure_on_crash` on the crash path. An AP_VLAN ext vdev that no 4addr station ever joined is released later, when mac80211 re-adds it. Also fixes a `spin_lock_bh`/`spin_unlock` mismatch. |

The first is confirmed by a hardware A/B with offload on (2026-09-13, through
a temporary switch and diagnostic prints since removed): with the clear off,
the firmware was handed the RXDMA buffer ring with a stale NSS-written head
pointer (198) over a zeroed ring, and the Q6 raised a NOC error 0.6 s after
recovery; with it on, 14/14 hw-restarts and every root-PD assert recovered. It
also changes offload-off recovery: the host now fills the whole refill ring,
where it used to fill about half.

Two bench candidates were dropped: tearing NSS down before the hw-restart
power cycle (never shown to help) and recovering by `device_reprobe()` (the AP
interface was not recreated).

Bench checks for these patches:
- Firmware-crash path of `nss-recovery-2` without a root PD assert: run
  `echo stop > /sys/class/remoteproc/remoteproc2/state`, wait, `echo start`,
  then the same on `remoteproc1`. Expect NSS deallocate/allocate pairs, no hung
  task on `conf_mutex`, and `successfully recovered`.
- Every recovery trial with offload on: `dmesg | grep -E 'COREDUMP|NSS-FW logbuffer|coredump finished|peer delete failed|failed to free nss'`
  must stay empty; an NSS core fault takes the whole router down.

### ath11k crash-recovery fixes in both builds

Nine patches in `files/` reach both builds:
- `955` removes a one-shot WARN seen when a station is deleted while the
  firmware is dead or wedged; `956` removes the regulatory `-22` line printed
  on recoveries.
- `957` keeps `ath11k_ahb_power_up()` from booting silently on top of a user PD
  power reference that is already held: one a failed `rproc_shutdown()` kept
  on hw-restart, one kept on remove before a module reload or re-probe, or one
  taken through remoteproc sysfs. It drops the reference first and fails with
  `-EBUSY` and an error if it cannot. It does not recover a user PD whose stop
  keeps failing (for example after a root PD assert): the hw-restart, a reload
  and a sysfs stop/start still fail then, now with an error instead of a
  silent wait.
- `958` frees the RX monitor rings every crash recovery allocated again
  (104 KiB of DMA memory leaked per root-PD assert).
- `959` and `961` fix the unwind of a crash recovery that fails because the
  firmware crashed again: `959` keeps the registered `ieee80211_hw`, `961`
  keeps the HAL that the next restart reuses (restarting pd-1 afterwards
  oopsed in `ath11k_core_restart`).
- `960` makes stations reconnect after a firmware restart, whose CCMP packet
  numbers start again from zero (a BCM43455 client stayed deaf otherwise).
- `962` keeps a recovery that follows a failed one from disabling the
  interrupts a second time (`disable_irq()` nests), which left the data path
  interrupts (IPQ5018) or the CE interrupts (QCN6122) off after it.
- `963` keeps WMI sends blocked until a crash recovery has set its rings up
  again; a send in that window read a cleared ring and panicked.

Bench checks for these patches:
- `955`: the WARN is one-shot, so check for `sta_info.c:1559` only in a boot
  where it has not fired yet.
- `957`: grep for `failed to shut down remote processor`,
  `already holds .* power reference` and `cannot drop the power reference`
  after assert and hw-restart trials. A forced reload-failure scenario is
  still needed with 957 in the image.

Status:
- With 950-963 in the stack, donor patches `199-003` (a `core.c` and a
  `mac.c` hunk) and `203` (`wmi.h`) apply with fuzz 1-2; the RD03v2 overrides
  apply without fuzz.
- The default-build replay applies 955-963 cleanly.
- `ath11k.ko` and `ath11k_ahb.ko` build without warnings (`-Werror`) with the
  NSS package's kbuild flags. The default-build ath11k sources also compile
  against that configuration.

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

Not covered: WAN/NAT **at line rate** (the routed-to-WAN row above is a
functional check at ~85 Mbit/s, limited by the test client, not a throughput
benchmark - nothing here establishes a NAT ceiling), runtime IPv6 acceleration,
long-duration or many-client
load, guest isolation, mesh and recovery under NSS Wi-Fi load (VLAN-aware
bridges: see patch 0029 above). The original stock/NSS-without-Wi-Fi whole-router hang is not proven to
have the same cause as the QCN6122 NSS peer-join crash diagnosed here.
