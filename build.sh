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
#
# Optional full installable kernel-module set (for the release kmod tarball):
#   KMODS=1 ./build.sh
# builds every kmod the target can build (~1100 packages) as `m` — packaged
# into bin/targets/.../packages/, NOT installed into the image. It does not
# change the image's package set, but it DOES change the kernel vermagic (a
# kmod at `m` still contributes its Kernel-Config symbols), so kmods only
# install on an image from the SAME build run. Release images must therefore
# be built with KMODS=1 too. Expect a multi-hour build.
set -e

cd "$(dirname "$0")"

WITH_NSS="${NSS:-0}"
WITH_KMODS="${KMODS:-0}"

# Fail before doing anything if the AN8855 driver has silently diverged between
# the two builds, or if an NSS patch stopped applying cleanly. Takes ~1s and
# needs only patch/awk/diff. Set SKIP_DIVERGENCE_CHECK=1 to bypass.
if [ "${SKIP_DIVERGENCE_CHECK:-0}" != "1" ] && [ -x tools/check-nss-divergence.sh ]; then
	echo ">>> checking AN8855 driver divergence"
	if ! ./tools/check-nss-divergence.sh; then
		echo "ERROR: divergence check failed - refusing to build." >&2
		echo "       See tools/check-nss-divergence.sh, or SKIP_DIVERGENCE_CHECK=1 to override." >&2
		exit 1
	fi
fi

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
	# Defined up here because the DEVICE_PACKAGES sed below needs it too: sed
	# exits 0 when it matches nothing, so an unanchored substitution whose
	# anchor has drifted silently produces a build that is missing what the sed
	# was supposed to add. That is how the NSS dtsi include was lost once.
	anchor() {  # anchor <count-expected> <pattern> <file>
		local n; n=$(grep -c -- "$2" "$3")
		[ "$n" = "$1" ] || { echo "ERROR: anchor '$2' matched $n times (want $1) in $3" >&2; exit 1; }
	}
	# extra feeds: qosmio nss-packages (qca-nss-drv/ecm/...) + sqm-scripts-nss
	cat ../nss/feeds.conf.append >> feeds.conf.default
	# overlay NSS files: kernel patches, reserved-mem + NSS-node dtsi,
	# skb_recycler, conntrack DSCP-remark, the tag_8021q an8855 driver, the
	# gateway board.d (WAN->eth0 conduit) + rc.local redirect, and ecm autoload
	cp -a ../nss/overlay/. .
	# pull the NSS dtsi into the device DTS
	sed -i '/#include "ipq5018-qcn6122.dtsi"/a #include "ipq5018-nss.dtsi"' \
		target/linux/qualcommax/dts/ipq5018-mi-router-ax3000t-v2.dts
	# add the NSS packages to the AX3000T device (before smallbuffers, same line).
	# kmod-qca-nss-drv-pppoe is REQUIRED for PPPoE WAN offload: it registers the
	# PPPoE session with the NSS core; without it ecm never accelerates any flow
	# over a pppoe wan (ipv4_create_requests stays 0). Do NOT add
	# kmod-qca-nss-drv-bridge-mgr: it is @ipq807x/60xx-only (never builds here)
	# yet kconfig still force-selects its +kmod-bonding dep, which breaks ecm.
	#
	# The anchor matters: this substitution keys on kmod-ath11k-smallbuffers
	# being the FIRST entry of DEVICE_PACKAGES. Insert anything ahead of it in
	# ipq50xx.mk and the pattern stops matching, sed still exits 0, and the NSS
	# build quietly ships without the four packages that make offload work.
	# Add new packages to the .config heredoc below instead of to that line.
	anchor 1 'DEVICE_PACKAGES := kmod-ath11k-smallbuffers ' \
		target/linux/qualcommax/image/ipq50xx.mk
	sed -i 's#DEVICE_PACKAGES := kmod-ath11k-smallbuffers #DEVICE_PACKAGES := kmod-qca-nss-drv kmod-qca-nss-ecm kmod-qca-nss-drv-pppoe nss-firmware-ipq50xx kmod-ath11k-smallbuffers #' \
		target/linux/qualcommax/image/ipq50xx.mk
	# NSS kernel config symbols (skb_recycler, conntrack DSCP-remark ext)
	cat ../nss/config.append >> target/linux/qualcommax/config-6.12

	# board.d + rc.local NSS deltas. These files used to be shadowed by full
	# copies under nss/overlay/ (a fix to files/ never reached the NSS build);
	# they are now single-source in files/ and their small NSS-only deltas are
	# applied here. anchor() (defined at the top of this block) fails the build
	# loudly if an anchor is missing or ambiguous.
	# Gateway topology: move the WAN onto the eth0 (1G) CPU port so WAN<->LAN
	# routing crosses two CPU ports, which NSS offload requires.
	NET=target/linux/qualcommax/ipq50xx/base-files/etc/board.d/02_network
	anchor 1 'ucidef_set_interfaces_lan_wan "lan2 lan3 lan4" "wan"' "$NET"
	sed -i '/ucidef_set_interfaces_lan_wan "lan2 lan3 lan4" "wan"/i\		# NSS offload gateway: user ports default to eth1 (2.5G CPU port); the\
		# WAN is moved to eth0 (1G CPU port) so WAN<->LAN routing is offloaded\
		# across the two CPU ports by the NSS firmware. See docs/nss-offload.md.' "$NET"
	sed -i '/ucidef_set_interfaces_lan_wan "lan2 lan3 lan4" "wan"/a\		ucidef_set_network_device_conduit "wan" "eth0"' "$NET"
	# NSS data-plane runtime knobs, prepended so rc.local's boot-flag block still
	# runs after them. See docs/nss-offload.md.
	RCL=target/linux/qualcommax/ipq50xx/base-files/etc/rc.local
	anchor 1 "U-Boot's dual-boot failsafe" "$RCL"
	sed -i '1i\
# NSS hardware offload runtime knobs. rc.local runs late in boot, after the\
# qca-nss modules are autoloaded, so the /proc/sys/dev/nss tree exists here.\
#  - general/redirect: hand exception/accelerated traffic to the NSS data plane\
#  - ipv{4,6}cfg/*_accel_mode: enable the connection-manager fast path\
echo 1 > /proc/sys/dev/nss/general/redirect 2>/dev/null\
echo 1 > /proc/sys/dev/nss/ipv4cfg/ipv4_accel_mode 2>/dev/null\
echo 1 > /proc/sys/dev/nss/ipv6cfg/ipv6_accel_mode 2>/dev/null\
' "$RCL"
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
	# scripts (shebang) — init.d services, /usr/bin helpers — must stay executable
	grep -rlIZ '^#!' files 2>/dev/null | xargs -0 -r chmod 755
	[ -f files/etc/dropbear/authorized_keys ] && chmod 600 files/etc/dropbear/authorized_keys
fi

./scripts/feeds update -a
./scripts/feeds install -a

# The IPQ5018 NSS core-boot fix: mainline 6.12 leaves the UBI32 core's GCC
# resets de-asserted, so the stock driver's core_reset is a no-op and the core
# never boots. This patch pulses the reset and re-orders the boot-config write.
if [ "$WITH_NSS" = "1" ]; then
	# qca-nss-drv-pppoe declares +kmod-bonding (QSDK boilerplate for LAG over
	# PPPoE). Selecting kmod-bonding flips ECM_INTERFACE_BOND_ENABLE=y and the
	# ecm bond notifier does not compile against mainline (struct bond_cb is a
	# QSDK-patched-bonding API). We don't use bonding - strip the dep.
	sed -i '/^define KernelPackage\/qca-nss-drv-pppoe$/,/^endef/{/+kmod-bonding/d}' \
		feeds/nss_packages/qca-nss-clients/Makefile
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
# Full hostapd, not wpad-basic: multi-AP households run 802.11k/v
# (rrm_*/bss_transition) in the wireless config, and wpad-basic rejects
# those options - hostapd then refuses the whole BSS and the radios
# silently never come up.
CONFIG_PACKAGE_wpad-mbedtls=y
# CONFIG_PACKAGE_wpad-basic-mbedtls is not set
# LuCI over plain HTTP (uhttpd). `luci` is a collection that `select`s
# luci-light + luci-app-package-manager, so this one symbol pulls the whole
# set - no companion needed. Deliberately NOT luci-ssl: that adds px5g, which
# generates a self-signed cert on first boot (slow on this SoC) for a warning
# every browser shows anyway. ~2 MB installed, ~0.6 MB in the image.
CONFIG_PACKAGE_luci=y
# Commonly wanted and tiny; asked for in #12. Everything else is installable
# from the release kmod tarball (KMODS=1) without rebuilding the kernel.
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_kmod-inet-diag=y
CONFIG_PACKAGE_kmod-nft-tproxy=y
EOF

# NSS firmware MUST match the driver ABI. The nss feed branch (NSS-12.5-K6.x)
# builds qca-nss-drv against the 12.5 firmware interface, but `make defconfig`
# resolves the nss-firmware version choice to its default, 11.4. With the 11.4
# blob loaded the NSS core "boots successfully" yet never answers phys_if
# messages: every DSA conduit open returns a silent EAGAIN and ALL switch
# ports (LAN and WAN) come up dead — the LAN-killing failure looks completely
# unrelated to a firmware-version default. Pin 12.5 explicitly.
if [ "$WITH_NSS" = "1" ]; then
	cat >> .config <<'EOF'
# CONFIG_NSS_FIRMWARE_VERSION_11_4 is not set
CONFIG_NSS_FIRMWARE_VERSION_12_5=y
EOF
fi

# ---- optional: full installable kmod set (KMODS=1) ----
# ALL_KMODS flips every kmod-* package to `m`: compiled and packaged, but not
# installed (package/Makefile builds the install list from package-y only).
# ALL_KMODS alone is right - CONFIG_ALL and CONFIG_ALL_NONSHARED *select* it,
# not the reverse, and would drag in userspace packages too.
#
# It is NOT image-neutral. package-metadata.pl collects Kernel-Config symbols
# from any package that is not 'n', so `m` kmods land in the kernel config,
# and .vermagic is an md5 over the sorted '=[ym]' set. The `kernel` package
# version therefore changes, and every kmod hard-depends on it exactly - which
# is why kmods from a KMODS=1 tree will not install on an image built without
# it. Build release images and their kmod tarball in the same run.
if [ "$WITH_KMODS" = "1" ]; then
	cat >> .config <<'EOF'
CONFIG_ALL_KMODS=y
EOF
fi

make defconfig

# With ~1100 extra modules in play, one broken out-of-tree module must not take
# the whole build down. IGNORE_ERRORS="n m" is what OpenWrt's own buildbot uses
# for image builds: it tolerates failures only in subdirs whose packages are
# all n/m, never in one that goes INTO the image. Do NOT add "y" - that would
# silently ship a firmware missing wpad-mbedtls or ath11k. BUILD_LOG=1 puts
# each failure in logs/<subdir>/error.txt instead of a multi-hour scrollback.
MAKE_ARGS=()
if [ "$WITH_KMODS" = "1" ]; then
	MAKE_ARGS+=(IGNORE_ERRORS="n m" BUILD_LOG=1)
fi
make -j"$(nproc)" "${MAKE_ARGS[@]}"

if [ "$WITH_KMODS" = "1" ] && [ -d logs ]; then
	errs=$(find logs -name error.txt 2>/dev/null | wc -l)
	if [ "$errs" != "0" ]; then
		echo
		echo ">>> $errs log(s) with build failures, SKIPPED (IGNORE_ERRORS):"
		# Print the failing package, not the log's directory - "logs/package"
		# tells you nothing, and this list goes into the release notes.
		grep -h 'failed to build' $(find logs -name error.txt) 2>/dev/null \
			| sed 's/^ *ERROR: /    /' | sort -u
		echo "    Their modules are absent from the kmod tarball. List them in the release notes."
	fi
fi

echo
echo "Build complete. Images are in:"
echo "  $(pwd)/bin/targets/qualcommax/ipq50xx/"
echo "  - *-initramfs-uImage.itb      (RAM-boot image; REQUIRED for every flash — you run sysupgrade from it)"
echo "  - *-squashfs-sysupgrade.bin   (the NAND image; flash with sysupgrade RUN FROM the initramfs, not in place — see README step 4)"
echo "  - *-squashfs-factory.ubi      (whole-UBI image; not used on this locked device — install via the initramfs path)"
if [ "$WITH_NSS" = "1" ]; then
	echo
	echo "NSS hardware offload build. After first boot the NSS core boots and"
	echo "qca-nss-drv/dp + ecm autoload; see docs/nss-offload.md."
fi
if [ "$WITH_KMODS" = "1" ]; then
	echo
	echo "KMODS=1: installable kernel modules ($(ls bin/targets/qualcommax/ipq50xx/packages/kmod-*.apk 2>/dev/null | wc -l) packages) are in:"
	echo "  $(pwd)/bin/targets/qualcommax/ipq50xx/packages/  (per-target dir)"
	echo "  $(pwd)/staging_dir/packages/qualcommax/          (flat signed repo — what tools/mkrelease.sh ships)"
	echo "They install ONLY on the image from THIS build (kernel vermagic + signing key)."
fi
