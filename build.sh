#!/usr/bin/env bash
# Build OpenWrt for the Xiaomi Mi Router AX3000T v2 (RD03v2):
#   IPQ5018 SoC + Airoha AN8855 switch + QCN6122 5 GHz radio.
#
# Reproduces the port by overlaying ./files/ onto a pristine
# openwrt/openwrt checkout at commit 25ee126.
set -e

cd "$(dirname "$0")"

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

./scripts/feeds update -a
./scripts/feeds install -a

# Seed config: qualcommax/ipq50xx, AX3000T v2 profile, plus initramfs
# (the initramfs uImage.itb is what you TFTP/serial-boot first).
# zram-swap/kmod-zram are pinned explicitly: this 256 MB board is tight
# with two ath11k radios, so compressed swap is a required safety net.
# (The device's DEVICE_PACKAGES also lists them, but pinning here avoids
#  the CONFIG_DEFAULT-vs-CONFIG_PACKAGE defconfig quirk on a fresh tree.)
cat > .config <<'EOF'
CONFIG_TARGET_qualcommax=y
CONFIG_TARGET_qualcommax_ipq50xx=y
CONFIG_TARGET_qualcommax_ipq50xx_DEVICE_xiaomi_mi-router-ax3000t-v2=y
CONFIG_TARGET_ROOTFS_INITRAMFS=y
CONFIG_PACKAGE_zram-swap=y
CONFIG_PACKAGE_kmod-zram=y
EOF

make defconfig
make -j"$(nproc)"

echo
echo "Build complete. Images are in:"
echo "  $(pwd)/bin/targets/qualcommax/ipq50xx/"
echo "  - *-initramfs-uImage.itb      (RAM-boot image, flash-safe first test)"
echo "  - *-squashfs-factory.ubi      (initial NAND install)"
echo "  - *-squashfs-sysupgrade.bin   (upgrades from OpenWrt)"
