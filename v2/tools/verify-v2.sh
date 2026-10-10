#!/bin/bash
# verify-v2.sh --tree <openwrt-v2>: check a finished v2 build. Each check prints PASS/FAIL;
# exit status is the number of failures. Grows with every v2 change (plan B1-B14).
#
# The image contents are checked in the sysupgrade image itself (its root squashfs), not in
# a staging directory of the tree: that is what gets flashed.
set -u
MODE=${1:-}; TREE=${2:-}
[ "$MODE" = --tree ] && [ -d "$TREE" ] || { echo "usage: verify-v2.sh --tree <dir>"; exit 2; }
TREE=$(cd "$TREE" && pwd)
V2=$(cd "$(dirname "$0")/.." && pwd); . "$V2/upstream.lock"
T=$TREE/bin/targets/qualcommax/ipq50xx; P=openwrt-qualcommax-ipq50xx-xiaomi_mi-router-ax3000t-v2
OV=$V2/overlay
fail=0
chk() {  # chk <label> <actual> <expected>
	if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=$((fail + 1)); fi
}
yes_() { "$@" >/dev/null 2>&1 && echo yes || echo no; }  # yes_ <command>: yes/no for chk
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

echo "=== provenance"
chk "upstream commit is an ancestor of HEAD" "$(yes_ git -C "$TREE" merge-base --is-ancestor "$COMMIT" HEAD)" yes
applied=$(git -C "$TREE" log --format=%s "$COMMIT..HEAD")
for p in "$V2"/tree-patches/*.patch; do
	[ -e "$p" ] || continue
	# the Subject header, unfolded (format-patch wraps a long one onto indented lines)
	s=$(awk '/^Subject: / { s = $0; f = 1; next } f && /^[ \t]/ { s = s $0; next } f { exit } END { print s }' "$p" |
		sed 's/^Subject: \[PATCH[^]]*\] //')
	chk "tree patch applied: $s" "$(grep -cxF "$s" <<<"$applied")" 1
done
grep -vE '^\s*(#|$)' "$V2/feeds.lock" | while read -r name rev; do
	[ "$(git -C "$TREE/feeds/$name" rev-parse HEAD 2>/dev/null)" = "$rev" ] && echo "PASS feed $name" || echo "FAIL feed $name"
done > "$W/feeds"; cat "$W/feeds"; fail=$((fail + $(grep -c '^FAIL' "$W/feeds")))

echo "=== configuration"
chk "one device in .config" "$(grep -c '^CONFIG_TARGET_DEVICE_.*=y' "$TREE/.config")" 1
for c in CONFIG_ATH11K_MEM_PROFILE_256M=y CONFIG_NSS_MEM_PROFILE_LOW=y CONFIG_ATH11K_NSS_SUPPORT=y \
	CONFIG_NSS_FIRMWARE_VERSION_12_2=y; do
	chk "$c" "$(grep -cxF "$c" "$TREE/.config")" 1
done
LX=$(ls -d "$TREE"/build_dir/target-*/linux-qualcommax_ipq50xx/linux-[0-9]* 2>/dev/null | head -1)
KC=$LX/.config
if [ -f "$KC" ]; then
	# his debug aids (tree patch 0001 reverts them); DEVMEM is also forced off by OpenWrt's
	# KERNEL_DEVMEM, so that one only documents the result
	chk "kernel: no serial sysrq" "$(grep -c '^CONFIG_MAGIC_SYSRQ_SERIAL=y' "$KC")" 0
	chk "kernel: default sysrq mask" "$(grep -c '^CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=0x1b6' "$KC")" 0
	chk "kernel: no /dev/mem" "$(grep -c '^CONFIG_DEVMEM=y' "$KC")" 0
	for c in CONFIG_I2C_QUP=y CONFIG_I2C_CHARDEV=y CONFIG_QCOM_SMP2P=y CONFIG_QCOM_Q6V5_WCSS_SEC=y; do
		chk "kernel: $c" "$(grep -cxF "$c" "$KC")" 1
	done
else
	echo "FAIL kernel config not found"; fail=$((fail + 1))
fi

echo "=== images"
chk "sysupgrade image" "$(ls "$T/$P-squashfs-sysupgrade.bin" 2>/dev/null | wc -l)" 1
chk "initramfs-factory installer" "$(ls "$T/$P-initramfs-factory.ubi" 2>/dev/null | wc -l)" 1

echo "=== image contents (root squashfs of the sysupgrade image)"
X=$W/root
# unsquashfs exits 2 as a normal user (it cannot create /dev/console); check what it extracted
tar -xOf "$T/$P-squashfs-sysupgrade.bin" --wildcards 'sysupgrade-*/root' > "$W/root.sqfs" 2>/dev/null &&
	{ unsquashfs -q -d "$X" "$W/root.sqfs" >/dev/null 2>&1 || :; }
if [ -f "$X/etc/rd03v2-release" ] && [ -f "$X/lib/apk/db/installed" ]; then
	. /dev/stdin <<<"$(grep -E '^RD03V2_[A-Z_]+=' "$X/etc/rd03v2-release" 2>/dev/null)"
	# The installed packages, from the image's own apk database ("name - version", as a
	# manifest): with per-device rootfs, the target's .manifest covers only the shared root.
	M=$W/manifest.txt
	awk '/^P:/ { n = substr($0, 3) } /^V:/ { print n " - " substr($0, 3) }' "$X/lib/apk/db/installed" | LC_ALL=C sort > "$M"
	echo "INFO $(wc -l < "$M") packages installed"
	grep -vE '^\s*(#|$)' "$V2/config/image-must-have.txt" | while read -r n; do
		case "$n" in
		'!'*) [ "$(grep -c "^${n#!} - " "$M")" = 0 ] && echo "PASS image lacks ${n#!}" || echo "FAIL image has ${n#!}" ;;
		*) [ "$(grep -c "^$n - " "$M")" = 1 ] && echo "PASS image has $n" || echo "FAIL image lacks $n" ;;
		esac
	done > "$W/must-have"; cat "$W/must-have"; fail=$((fail + $(grep -c '^FAIL' "$W/must-have")))
	chk "release stamp: base" "${RD03V2_BASE:-}" "kuncy7/openwrt-nss-edma $RELEASE $COMMIT"
	D=$X/etc/apk/repositories.d/distfeeds.list
	{
		echo "${RD03V2_REPO:-<no repo in the stamp>}"
		for f in base luci packages routing telephony video; do
			echo "https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/$f/packages.adb"
		done
	} > "$W/distfeeds"
	chk "distfeeds: our repo, then the snapshot userspace feeds" "$(yes_ cmp "$W/distfeeds" "$D")" yes
	n=0; for k in "$X"/etc/apk/keys/*; do cmp -s "$k" "$V2/keys/public-key.pem" && n=$((n + 1)); done
	chk "our key in /etc/apk/keys" "$n" 1
	chk "no AmneziaWG files in the image" "$(find "$X" -iname '*amnezia*' | wc -l)" 0
	# NFC (tree patch 0002 + shared.list), as tools/verify-release.sh checks it on v1.x
	chk "nfc tool" "$(yes_ test -x "$X/usr/sbin/nfc")" yes
	chk "nfc syntax" "$(yes_ sh -n "$X/usr/sbin/nfc")" yes
	chk "S99nfc symlink" "$(yes_ test -L "$X/etc/rc.d/S99nfc")" yes
	chk "i2ctransfer" "$(yes_ test -x "$X/usr/sbin/i2ctransfer")" yes
	chk "nfc default mode" "$(grep -hE '^[[:space:]]*option mode' "$X/etc/config/nfc" 2>/dev/null)" "	option mode 'clear'"
	# tree patch 0003: every PPPoE session made again once the NSS PPPoE manager is resident
	chk "nss-dwmac-up re-dials every PPPoE interface (0003)" \
		"$(grep -cF '@.interface[@.proto="pppoe" && @.up=true]' "$X/usr/sbin/nss-dwmac-up" 2>/dev/null)" 1
	# B10/B11 first-boot scripts
	for u in 00-rd03v2-migrate-v1x 95-rd03v2-apk-pins; do
		chk "uci-defaults $u" "$(yes_ sh -n "$X/etc/uci-defaults/$u")" yes
	done
	chk "apk pins match build.sh's copies" \
		"$(sed -n "s/^PINS='\(.*\)'\$/\1/p" "$X/etc/uci-defaults/95-rd03v2-apk-pins" 2>/dev/null)" \
		"$(sed -n "s/^PINS='\(.*\)'\$/\1/p" "$OV/target/linux/qualcommax/ipq50xx/base-files/etc/uci-defaults/95-rd03v2-apk-pins")"
	# every file of the overlay that lands in base-files is in the image, unchanged
	for f in $(cd "$OV/target/linux/qualcommax/ipq50xx/base-files" 2>/dev/null && find . -type f | sed 's#^\./##'); do
		chk "overlay file /$f" "$(yes_ cmp "$OV/target/linux/qualcommax/ipq50xx/base-files/$f" "$X/$f")" yes
	done
	# the Wi-Fi watchdog (B9): its --check scenarios, with this image's uci and jsonfilter
	# (the image's copy is the overlay's, checked above), and dry run on by default
	chk "watchdog ships in dry run" "$(grep -cE "^[[:space:]]*option dryrun '1'" "$X/etc/config/rd03v2-watchdog" 2>/dev/null)" 1
	"$V2/tools/test-watchdog.sh" --env host --rootfs "$X" > "$W/watchdog-tests" 2>&1
	chk "watchdog --check scenarios" "$(tail -1 "$W/watchdog-tests" | grep -cE '^ *[0-9]+ passed, 0 failed$')" 1
	# UK 5.8 GHz band (964): its one-entry table compiles to immediates, the "GB" compare
	# (0x4247) and the low half of 5725000 kHz (0x5b48)
	od=$(ls "$TREE"/staging_dir/toolchain-*/bin/*-linux-musl-objdump 2>/dev/null | head -1)
	ko=$(find "$X/lib/modules" -name ath11k.ko 2>/dev/null | head -1)
	if [ -n "$od" ] && [ -n "$ko" ]; then
		chk "ath11k.ko adds GB 5725-5850 MHz (964)" \
			"$("$od" -d "$ko" | grep -oE 'mov[[:space:]]+w[0-9]+, #0x(4247|5b48)\b' | grep -oE '0x[0-9a-f]+$' | sort -u | xargs)" \
			"0x4247 0x5b48"
	else
		echo "FAIL ath11k.ko or the tree's objdump not found"; fail=$((fail + 1))
	fi
else
	echo "FAIL cannot unpack the root squashfs of the sysupgrade image"; fail=$((fail + 1))
fi

echo "=== device tree"
dtb=$(ls "$TREE"/build_dir/target-*/linux-qualcommax_ipq50xx/image-ipq5018-mi-router-ax3000t-v2.dtb 2>/dev/null | head -1)
if [ -n "$dtb" ]; then
	chk "DTB i2c@78b7000 (NFC) status" "$(fdtget -t s "$dtb" /soc@0/i2c@78b7000 status 2>&1)" okay
	chk "DTB i2c@78b7000 clock-frequency" "$(fdtget -t u "$dtb" /soc@0/i2c@78b7000 clock-frequency 2>&1)" 100000
	chk "DTB i2c@78b7000 dmas" "$(fdtget -t x "$dtb" /soc@0/i2c@78b7000 dmas 2>&1 | awk '{print $2, $4}')" "8 9"
	chk "DTB i2c@78b7000 dma-names" "$(fdtget -t s "$dtb" /soc@0/i2c@78b7000 dma-names 2>&1 | tr '\0' ' ' | xargs)" "tx rx"
else
	echo "FAIL DTB not found in the tree"; fail=$((fail + 1))
fi

echo "=== our patches in the prepared sources"
# One fingerprint per patch: its longest added line, which must be in the patched source.
fp() {  # fp <patch> <source dir>
	local l
	l=$(grep -E '^\+[^+]' "$1" | cut -c2- | awk '{ if (length($0) > length(best)) best = $0 } END { print best }')
	[ -n "$l" ] && grep -rqF -- "$l" "$2" && echo yes || echo no
}
BP=$(ls -d "$TREE"/build_dir/target-*/linux-qualcommax_ipq50xx/backports-[0-9]* 2>/dev/null | head -1)
if [ -z "$BP" ]; then
	# His CI config sets AUTOREMOVE, which deletes package build directories after compiling.
	# Re-apply the series instead, strictly; that it went into the build shows in the shipped
	# ath11k.ko (the 964 immediates above), since a patch that fails stops the build.
	if "$V2/tools/check-mac80211-series.sh" "$TREE" "$W/mac80211" > "$W/mac80211.log" 2>&1; then
		BP=$W/mac80211/src
		echo "INFO mac80211: build directory removed (AUTOREMOVE); $(tail -1 "$W/mac80211.log" | cut -d';' -f1)"
	else
		echo "FAIL mac80211 series does not apply without fuzz:"; sed 's/^/    /' "$W/mac80211.log"
		fail=$((fail + 1))
	fi
fi
for p in "$OV"/package/kernel/mac80211/patches/nss/ath11k/*.patch; do
	[ -e "$p" ] || continue
	chk "mac80211 $(basename "$p")" "$([ -n "$BP" ] && fp "$p" "$BP/drivers/net/wireless/ath/ath11k" || echo no)" yes
done
for p in "$OV"/target/linux/qualcommax/patches-6.18/*.patch; do
	[ -e "$p" ] || continue
	chk "kernel $(basename "$p")" "$([ -n "$LX" ] && fp "$p" "$LX/drivers" || echo no)" yes
done

echo "=== package repository"
chk "package index" "$(ls "$T/packages/packages.adb" 2>/dev/null | wc -l)" 1
# the image trusts only our key (checked above), so the index must verify against it; apk 3
# reads --keys-dir relative to its root, so both paths are absolute
chk "package index signed with our key" \
	"$("$TREE/staging_dir/host/bin/apk" verify --keys-dir "$V2/keys" "$T/packages/packages.adb" 2>&1 | sed 's/.*: //')" OK
for n in kmod-wireguard luci-app-nss kmod-amneziawg amneziawg-tools luci-proto-amneziawg; do
	chk "repo has $n" "$(ls "$T/packages/$n"-[0-9]*.apk 2>/dev/null | wc -l)" 1
done
# the pinned packages, in exactly the image's versions
for n in $(sed -n "s/^PINS='\(.*\)'\$/\1/p" "$OV/target/linux/qualcommax/ipq50xx/base-files/etc/uci-defaults/95-rd03v2-apk-pins"); do
	v=$(sed -n "s/^$n - //p" "${M:-/dev/null}")
	chk "repo has pinned $n $v" "$(ls "$T/packages/$n-$v.apk" 2>/dev/null | wc -l)" 1
done
k=$(ls "$T"/packages/kernel-*.apk 2>/dev/null | head -1); echo "INFO kernel package: $(basename "${k:-none}")"
echo "verify-v2: $fail failure(s)"
exit $fail
