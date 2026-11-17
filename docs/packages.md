# Packages

The image lists our repository first, then OpenWrt's snapshot feeds `base`, `luci`,
`packages`, `routing`, `telephony` and `video`. The official kmods feed is left out, because
its kernel is not ours. Kernel modules come from our repository, which is built with the
image and signed with our key. A kmod installs only on the image of the same build, since
it depends on `kernel=<version>~<vermagic>` exactly. That is also why a module missing from a
release cannot be added to its repository later: building it changes the kernel
configuration, and with it vermagic.

From v2.1.4 the repository holds every kernel module package the target can build (about
1250), as OpenWrt's own builds do; before, it held the ones someone had asked for. Left out:
`kmod-ipt-rtpengine`, which does not build, and the NSS client modules for MAP-T, mirroring and
Wi-Fi mesh management. The NSS driver and ECM in the image are built without IPsec, MAP-T and
6rd support, as before, whichever modules are in the repository, so `kmod-ipsec`, `kmod-nat46`
and `kmod-sit` should work on the CPU without offload; none of the three was tried, and IPsec
next to ECM in particular is untested. The modules were built, not
each one tried: only the ones named in [VALIDATION](../VALIDATION.md) were loaded on a router.

pppd plugins (`ppp-mod-*`) load only into the pppd they were built for: pppd reads them from
`/usr/lib/pppd/<its version>/`. Our repository carries the image's own builds of
`ppp-mod-pppol2tp` and `ppp-mod-pptp` (and `xl2tpd`), but `apk` installs the highest
version on offer, which is OpenWrt's snapshot build while its ppp has the same version
(on v2.1.2: the snapshot's 2.5.4-r6, the image's pppd 2.5.4-r2). Should the snapshot's ppp
move to a newer version, its plugins would not load into the image's pppd until
`apk upgrade ppp` brings pppd along.

Userspace comes from OpenWrt's snapshot feeds and drifts with them. That is the point: it
is maintained there. The exception is the packages kuncy7's tree changes without a version
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

`dnsmasq-full` (nftset, DNSSEC, conntrack) installs from OpenWrt's snapshot feed from v2.1.4:
`apk del dnsmasq`, then `apk add dnsmasq-full`. It needs `kmod-nf-conntrack-netlink`, which the
repository has from v2.1.4, and a `ujail` that lets a service keep capabilities when it drops to
its own user, which v2.1.4's procd has (a one-line backport of procd 0d3c5dc1bb). On v2.0.0 to
v2.1.3 don't install the snapshot's `dnsmasq-full` or lift the `dnsmasq` pin: since November
2026 those packages fail to start there (`setting capabilities failed`), after their init
script has pointed the router's own resolver at 127.0.0.1.
