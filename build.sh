#!/usr/bin/env bash
# Build OpenWrt for the Xiaomi Mi Router AX3000T v2 (RD03v2):
#   IPQ5018 SoC + Airoha AN8855 switch + QCN6122 5 GHz radio.
#
# Reproduces the port by overlaying ./files/ onto a pristine
# openwrt/openwrt checkout at commit 25ee126.
#
# Optional QCA NSS hardware offload (experimental, ~900 Mbps NAT routing):
#   NSS=1 ./build.sh
# layers ./nss/ on top — see docs/nss-offload.md. The default build is
# pure mainline and does NOT pull the QCA NSS feeds/patches.
set -e

cd "$(dirname "$0")"

WITH_NSS="${NSS:-0}"

if [ -e openwrt ]; then
	echo "ERROR: ./openwrt already exists — remove it first." >&2
	exit 1
fi

git clone https://github.com/openwrt/openwrt
cd openwrt
# 25ee126 = "uboot-tools: update to v2026.07"
git checkout 25ee12629edcc38feffbd06255dd47840cd7af7e

# Overlay the device-support files (path-preserving)
cp -a ../files/. .

# ---- optional: QCA NSS hardware offload (NSS=1) ----
if [ "$WITH_NSS" = "1" ]; then
	echo ">>> NSS=1: layering QCA NSS hardware offload (experimental)"
	# extra feeds: qosmio nss-packages (qca-nss-drv/ecm/...) + sqm-scripts-nss
	cat ../nss/feeds.conf.append >> feeds.conf.default
	# overlay NSS files: kernel patches, reserved-mem + NSS-node dtsi,
	# skb_recycler, conntrack DSCP-remark, the tag_8021q an8855 driver, the
	# gateway board.d (WAN->eth0 conduit) + rc.local redirect, and ecm autoload
	cp -a ../nss/overlay/. .
	# pull the NSS dtsi into the device DTS
	sed -i '/#include "ipq5018-qcn6122.dtsi"/a #include "ipq5018-nss.dtsi"' \
		target/linux/qualcommax/dts/ipq5018-mi-router-ax3000t-v2.dts
	# add the NSS packages to the AX3000T device (before smallbuffers, same line)
	sed -i 's#DEVICE_PACKAGES := kmod-ath11k-smallbuffers #DEVICE_PACKAGES := kmod-qca-nss-drv kmod-qca-nss-ecm kmod-qca-nss-drv-bridge-mgr nss-firmware-ipq50xx kmod-ath11k-smallbuffers #' \
		target/linux/qualcommax/image/ipq50xx.mk
	# NSS kernel config symbols (skb_recycler, conntrack DSCP-remark ext)
	cat ../nss/config.append >> target/linux/qualcommax/config-6.12
fi

# ---- optional: private profile overlay (PROFILE=/path/to/profile) ----
# Bakes a private, secret-bearing profile into the image as custom rootfs files
# (OpenWrt copies ./files/ into the rootfs). Intended for a personal, pre-
# configured build: the profile's files/etc/config/{network,wireless,firewall,
# dhcp} hold the gateway topology, WiFi PSK and PPPoE creds, so a *clean* flash
# boots fully configured (SSH at 192.168.1.1, WAN + WiFi up) with no serial
# needed. The profile lives OUTSIDE this repo (e.g. a private git repo) and is
# never committed here — only its path is passed in:
#   PROFILE=~/ax3000t-profile NSS=1 ./build.sh
if [ -n "$PROFILE" ]; then
	[ -d "$PROFILE/files" ] || { echo "ERROR: PROFILE=$PROFILE has no files/ dir." >&2; exit 1; }
	echo ">>> PROFILE=$PROFILE: baking private profile config into the image"
	mkdir -p files
	cp -a "$PROFILE"/files/. files/
	# Normalize modes: git does not record directory modes (nor anything
	# beyond the exec bit), so a fresh clone inherits the cloner's umask. A
	# group-writable /etc/dropbear makes dropbear reject the whole dir
	# ("must be owned by user or root, and not writable by group or others")
	# and locks SSH out of a fresh flash. The image preserves these modes.
	find files -type d -exec chmod 755 {} +
	find files -type f -exec chmod 644 {} +
	[ -f files/etc/dropbear/authorized_keys ] && chmod 600 files/etc/dropbear/authorized_keys
fi

./scripts/feeds update -a
./scripts/feeds install -a

# The IPQ5018 NSS core-boot fix: mainline 6.12 leaves the UBI32 core's GCC
# resets de-asserted, so the stock driver's core_reset is a no-op and the core
# never boots. This patch pulses the reset and re-orders the boot-config write.
if [ "$WITH_NSS" = "1" ]; then
	mkdir -p feeds/nss_packages/qca-nss-drv/patches
	cp ../nss/feed-patches/qca-nss-drv/*.patch feeds/nss_packages/qca-nss-drv/patches/
	# ecm DSA-conduit awareness: map a DSA user port (or a bridge master over one)
	# to its CPU conduit netdev so the fast path resolves an accelerable
	# interface. Without it the tag_8021q-tagged WAN<->LAN frames are exceptioned
	# at L2 and the flow never offloads. See docs/nss-offload.md.
	mkdir -p feeds/nss_packages/qca-nss-ecm/patches
	cp ../nss/feed-patches/qca-nss-ecm/*.patch feeds/nss_packages/qca-nss-ecm/patches/
fi

# Seed config: qualcommax/ipq50xx, AX3000T v2 profile, plus initramfs
# (the initramfs uImage.itb is what you TFTP/serial-boot first).
# WiFi RAM: the device uses kmod-ath11k-smallbuffers (see files/ overlay) so
# the two radios fit comfortably in 256 MB — no zram/memory-mode hacks needed.
cat > .config <<'EOF'
CONFIG_TARGET_qualcommax=y
CONFIG_TARGET_qualcommax_ipq50xx=y
CONFIG_TARGET_qualcommax_ipq50xx_DEVICE_xiaomi_mi-router-ax3000t-v2=y
CONFIG_TARGET_ROOTFS_INITRAMFS=y
EOF

make defconfig
make -j"$(nproc)"

echo
echo "Build complete. Images are in:"
echo "  $(pwd)/bin/targets/qualcommax/ipq50xx/"
echo "  - *-initramfs-uImage.itb      (RAM-boot image, flash-safe first test)"
echo "  - *-squashfs-factory.ubi      (initial NAND install)"
echo "  - *-squashfs-sysupgrade.bin   (upgrades from OpenWrt)"
if [ "$WITH_NSS" = "1" ]; then
	echo
	echo "NSS hardware offload build. After first boot the NSS core boots and"
	echo "qca-nss-drv/dp + ecm autoload; see docs/nss-offload.md."
fi
