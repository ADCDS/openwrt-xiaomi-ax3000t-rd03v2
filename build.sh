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
#
# Cutting a release is this script twice (once plain, once NSS=1, both KMODS=1)
# into two separate directories, then, over each finished tree:
#   ./tools/wifi-initramfs.sh <tree>   # adds the beaconing -wifi initramfs pair
#   ./tools/mkrelease.sh               # assembles + verifies the asset set
# tools/wifi-initramfs.sh re-runs only the image step, so it does not touch the
# kernel config and the tree's single kmod set still pairs with both passes.
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

	# 0600-6 (DSCPREMARK) makes xt_DSCP.c call
	# nf_conntrack_dscpremark_ext_set_dscp_rule_valid(), so on the NSS kernel
	# xt_DSCP.ko gains a symbol dependency on nf_conntrack.ko - but xt_DSCP
	# ships inside kmod-ipt-ipopt, whose DEPENDS only carries kmod-ipt-core.
	# The normal NSS build never selects that package so nothing noticed;
	# KMODS=1 builds it and OpenWrt's dependency check fails the whole
	# package/kernel/linux build ("missing dependencies ... nf_conntrack.ko").
	# Left unfixed it would also mean a hand-installed kmod-ipt-ipopt cannot
	# load on an NSS image. Declaring the dep is what the same file already
	# does for other conntrack-using ipt modules.
	anchor 1 '^define KernelPackage/ipt-ipopt$' package/kernel/linux/modules/netfilter.mk
	sed -i '/^define KernelPackage\/ipt-ipopt$/,/^endef$/ s#\$(call AddDepends/ipt)#$(call AddDepends/ipt,+kmod-nf-conntrack)#' \
		package/kernel/linux/modules/netfilter.mk

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
	# ecm feature tests: ask "is it in the image?", not "did we package it?".
	#
	# qca-nss-ecm switches ~17 optional features on by testing whether some kmod
	# is enabled at all:
	#
	#     ifneq ($(CONFIG_PACKAGE_kmod-qca-mcs),)
	#     ECM_MAKE_OPTS+=ECM_MULTICAST_ENABLE=y
	#
	# `m` satisfies that test. So KMODS=1, which sets every kmod to `m`, compiles
	# ecm with multicast, MAP-T, IPsec, bonding, macvlan, VXLAN, OVS, MSCS,
	# L2TPv2, GRE, SIT, IPIP6 and rawip support that this port has never built,
	# never shipped and never measured. Two of them cannot even compile:
	#   - MAP-T does "#include <nat46-core.h>", which nat46 never installs into
	#     staging;
	#   - multicast does "#include <mc_ecm.h>" from qca-mcs, which does not build
	#     against the 6.12 bridge at all (mc_osdep.h calls br_pass_frame_up()).
	# kmod-qca-nss-ecm is in DEVICE_PACKAGES, so both are hard failures that stop
	# the entire NSS build rather than IGNORE_ERRORS skips.
	#
	# ecm links against these at build time, so the test it means to make is "is
	# this in the image" - which is `y`. Rewrite each test to say that. On a
	# build without ALL_KMODS this is a no-op (packages are y or unset), which is
	# exactly the point: the ecm module stays the one that was measured on
	# hardware, with pppoe/pptp/ppp and the NSS front end on and the rest off.
	#
	# Two things that look like fixes and are not:
	#   - "# CONFIG_PACKAGE_kmod-nat46 is not set" in .config. kmod-qca-nss-drv-
	#     map-t declares "+kmod-nat46"; a leading '+' in DEPENDS is a kconfig
	#     `select`, so ALL_KMODS re-selects nat46 and `make defconfig` undoes the
	#     exclusion one line later, silently. (This is what fad4e1b tried.)
	#   - excluding macvlan/ipsec/vxlan/bonding/... from the kmod set. It would
	#     work, and it would cost users those modules in the release tarball to
	#     work around a build flag.
	ECM_MK=feeds/nss_packages/qca-nss-ecm/Makefile
	n=$(grep -c '\$(CONFIG_PACKAGE_kmod-' "$ECM_MK")
	[ "$n" -ge 10 ] || { echo "ERROR: only $n kmod feature tests in $ECM_MK (want >=10) — has it been rewritten upstream?" >&2; exit 1; }
	sed -i 's#\$(CONFIG_PACKAGE_kmod-\([a-zA-Z0-9_.-]*\))#$(filter y,$(CONFIG_PACKAGE_kmod-\1))#g' "$ECM_MK"
	m=$(grep -c 'filter y,\$(CONFIG_PACKAGE_kmod-' "$ECM_MK")
	[ "$m" = "$n" ] || { echo "ERROR: rewrote $m of $n ecm feature tests" >&2; exit 1; }

	# ...and the same problem again in kmod-qca-nss-ecm's DEPENDS, where it is
	# silent instead of loud. Nine of its dependencies are optional
	# co-installation hints of the form
	#
	#     +PACKAGE_kmod-nat46:kmod-nat46
	#
	# i.e. "if nat46 is selected at all, pull it in too". Under ALL_KMODS they
	# are all selected - at `m`. A package cannot be built into the image while
	# depending on a module, so kconfig quietly DEMOTES kmod-qca-nss-ecm from y
	# to m even though ipq50xx.mk names it in DEVICE_PACKAGES. The build then
	# succeeds and produces an NSS image with no connection manager in it: no
	# acceleration at all, nothing in the log to say why, and the module sitting
	# in the kmod tarball looking like it belongs there.
	#
	# The hints are redundant here - this port names what it wants in
	# DEVICE_PACKAGES - and four of them (qca-mcs, bonding, vxlan, nat46) point
	# at features the rewrite above just compiled out. Drop them all; the real
	# dependencies (+ethtool, +kmod-nf-conntrack, the NSS_DRV_* options) stay.
	#
	# Done in python because they are backslash continuations: deleting the last
	# few lines of the list leaves the previous one ending in '\', which swallows
	# the TITLE: that follows and corrupts the package metadata.
	python3 - "$ECM_MK" <<'PYEOF'
import re, sys
path = sys.argv[1]
src = open(path).read()
m = re.search(r'(define KernelPackage/qca-nss-ecm\n)(.*?)(\nendef)', src, re.S)
if not m:
    sys.exit("ERROR: qca-nss-ecm KernelPackage block not found in " + path)
lines = m.group(2).split('\n')
keep = [l for l in lines if not re.search(r'\+PACKAGE_kmod-[A-Za-z0-9_-]+:kmod-', l)]
dropped = len(lines) - len(keep)
if dropped == 0:
    sys.exit("ERROR: no optional co-install deps found in kmod-qca-nss-ecm - "
             "has the feed changed?")
# Whatever is now last in DEPENDS must not end in a backslash. A real
# continuation is followed by another dependency, which starts with + or @.
for i, l in enumerate(keep):
    if l.rstrip().endswith('\\') and (
            i + 1 == len(keep) or not keep[i + 1].lstrip().startswith(('+', '@'))):
        keep[i] = l.rstrip()[:-1].rstrip()
open(path, 'w').write(src[:m.start(2)] + '\n'.join(keep) + src[m.end(2):])
print("    dropped %d optional co-install deps from kmod-qca-nss-ecm" % dropped)
PYEOF

	mkdir -p feeds/nss_packages/qca-nss-drv/patches
	cp ../nss/feed-patches/qca-nss-drv/*.patch feeds/nss_packages/qca-nss-drv/patches/
	# ecm DSA-conduit awareness: map a DSA user port (or a bridge master over one)
	# to its CPU conduit netdev so the fast path resolves an accelerable
	# interface. Without it the tag_8021q-tagged WAN<->LAN frames are exceptioned
	# at L2 and the flow never offloads. See docs/nss-offload.md.
	mkdir -p feeds/nss_packages/qca-nss-ecm/patches
	cp ../nss/feed-patches/qca-nss-ecm/*.patch feeds/nss_packages/qca-nss-ecm/patches/
	# The clients' sub-Makefiles gate -DBONDING_SUPPORT on the kernel's
	# CONFIG_BONDING, but what it guards is QSDK's *patched* bonding
	# (bond_get_id(), struct bond_cb), which mainline does not have. Harmless
	# until KMODS=1 selects kmod-bonding; then kmod-qca-nss-drv-pppoe, which is
	# in DEVICE_PACKAGES, stops compiling and takes the build with it.
	mkdir -p feeds/nss_packages/qca-nss-clients/patches
	cp ../nss/feed-patches/qca-nss-clients/*.patch feeds/nss_packages/qca-nss-clients/patches/
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
	# nat46 used to be excluded here, on the NSS build, to stop qca-nss-ecm
	# compiling its MAP-T path. It does not work (kconfig re-selects it) and it
	# is not needed: the ecm feature tests are rewritten in the NSS block above.
	# kmod-nat46 is built as a module on both flavours, as it always was on the
	# default one.
	#
	# qca-nss-clients is the one place ALL_KMODS cannot simply be reinterpreted.
	# It is a single source tree producing ~30 client modules, one per selected
	# subpackage, and most of them do not compile against mainline 6.12 - the
	# QSDK APIs are missing (nss_qdisc wants TCA_NSSBF_*, tun6rd wants
	# ipip6_update_offload_stats(), map-t wants nat46-core.h, ...). Selecting
	# them all makes the package fail, and because kmod-qca-nss-drv-pppoe comes
	# from this same package and IS in DEVICE_PACKAGES, IGNORE_ERRORS cannot skip
	# it: the whole NSS build stops.
	#
	# Turning the flags off is not enough here, unlike ecm: each subpackage's
	# FILES names a .ko, so a selected-but-not-built subpackage fails at
	# packaging instead. They have to be deselected outright.
	#
	# So build exactly the client the image uses. That is also what every NSS
	# release before this one shipped - nothing is lost from the kmod tarball,
	# because none of these modules has ever built here.
	if [ "$WITH_NSS" = "1" ]; then
		CLIENTS=feeds/nss_packages/qca-nss-clients/Makefile
		[ -f "$CLIENTS" ] || { echo "ERROR: $CLIENTS not found" >&2; exit 1; }
		# Derived from the feed, not hardcoded: the list moves with the feed.
		NSS_CLIENT_DROP=$(grep -o '^define KernelPackage/[a-zA-Z0-9_-]*' "$CLIENTS" \
			| sed 's#.*/##' | sort -u | grep -vx 'qca-nss-drv-pppoe')
		n=$(echo "$NSS_CLIENT_DROP" | wc -l)
		[ "$n" -ge 10 ] || { echo "ERROR: found only $n qca-nss-clients subpackages (want >=10)" >&2; exit 1; }
		for p in $NSS_CLIENT_DROP; do
			echo "# CONFIG_PACKAGE_kmod-$p is not set"
		done >> .config
	fi
fi

make defconfig

# A kconfig `select` beats "is not set" — that is exactly how the old nat46
# exclusion was silently undone — so confirm the deselection above survived
# rather than trusting it. Cheap, and the alternative is a build that fails an
# hour later for a reason that looks unrelated.
if [ -n "${NSS_CLIENT_DROP:-}" ]; then
	back=""
	for p in $NSS_CLIENT_DROP; do
		grep -q "^CONFIG_PACKAGE_kmod-$p=" .config && back="$back $p"
	done
	[ -z "$back" ] || { echo "ERROR: kconfig re-selected qca-nss-clients subpackages:$back" >&2; exit 1; }
	grep -q '^CONFIG_PACKAGE_kmod-qca-nss-drv-pppoe=y$' .config \
		|| { echo "ERROR: kmod-qca-nss-drv-pppoe is not in the image — PPPoE offload would be missing" >&2; exit 1; }
fi

# The NSS packages ipq50xx.mk puts in DEVICE_PACKAGES must be IN the image, not
# merely packaged. kconfig demotes a y package to m rather than failing when a
# dependency is only a module, so "it built" is not evidence: an NSS image
# without kmod-qca-nss-ecm boots fine, accelerates nothing, and says nothing.
# See the DEPENDS rewrite above for how that happened. Check every one.
if [ "$WITH_NSS" = "1" ]; then
	for p in kmod-qca-nss-drv kmod-qca-nss-ecm kmod-qca-nss-drv-pppoe nss-firmware-ipq50xx; do
		grep -q "^CONFIG_PACKAGE_$p=y\$" .config || {
			echo "ERROR: $p is '$(grep -m1 "^CONFIG_PACKAGE_$p=" .config || echo unset)', not y." >&2
			echo "       It is in DEVICE_PACKAGES, so this image would ship without it." >&2
			exit 1
		}
	done
fi


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
echo
echo "Both radios are disabled in this image. For an installer that beacons while"
echo "running from RAM (cable-free flashing), add the -wifi initramfs pair with:"
echo "  ./tools/wifi-initramfs.sh $(pwd)"
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
