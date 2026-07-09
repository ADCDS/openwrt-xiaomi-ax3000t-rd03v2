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
