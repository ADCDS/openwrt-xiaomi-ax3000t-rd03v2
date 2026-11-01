# Packages

The image lists our repository first, then OpenWrt's snapshot feeds `base`, `luci`,
`packages`, `routing`, `telephony` and `video`. The official kmods feed is left out, because
its kernel is not ours. Kernel modules come from our repository, which is built with the
image and signed with our key. A kmod installs only on the image of the same build, since
it depends on `kernel=<version>~<vermagic>` exactly. That is also why a module missing from a
release cannot be added to its repository later: building it changes the kernel
configuration, and with it vermagic.

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
