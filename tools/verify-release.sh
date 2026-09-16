#!/bin/bash
# verify-release.sh — independent check of an assembled v1.9 asset set.
#
# Deliberately re-derives everything from the artifacts rather than trusting
# the build logs: the first v1.9 was pulled because its -nss image did not
# contain the feature its notes advertised, and the build log looked fine.
set -uo pipefail

REL="${1:?usage: verify-release.sh <release-dir>}"
PLAIN_TREE="${2:-}"
NSS_TREE="${3:-}"
P=0 F=0
ok()   { printf "  \033[32mPASS\033[0m %s\n" "$1"; P=$((P+1)); }
bad()  { printf "  \033[31mFAIL\033[0m %s\n" "$1"; F=$((F+1)); }
chk()  { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: got [$2] want [$3]"; fi; }

echo "=== 1. asset set ==="
N=$(ls "$REL" | wc -l)
chk "asset count" "$N" "16"
for f in sha256sums.txt nand-support.txt; do
	[ -f "$REL/$f" ] && ok "$f present" || bad "$f MISSING"
done
for v in "" "-nss"; do
	[ -f "$REL"/*squashfs-sysupgrade$v.bin ] && ok "sysupgrade$v.bin present" || bad "sysupgrade$v.bin MISSING"
	[ -f "$REL"/*kmods$v.tar.gz ] && ok "kmods$v.tar.gz present" || bad "kmods$v.tar.gz MISSING"
done

echo "=== 2. checksums ==="
CO=$( cd "$REL" && sha256sum -c sha256sums.txt 2>/dev/null | grep -c ": OK$" )
CT=$( wc -l < "$REL/sha256sums.txt" )
chk "sha256sums verify" "$CO" "$CT"

echo "=== 3. the two images are distinct ==="
if cmp -s "$REL"/*squashfs-sysupgrade.bin "$REL"/*squashfs-sysupgrade-nss.bin; then
	bad "plain and nss images are IDENTICAL"
else
	ok "plain and nss images differ"
fi

# Contents are checked from the build trees' squashfs, since a sysupgrade.bin
# is not a bare squashfs. Checksum identity above ties them together.
check_tree() {
	local label="$1" tree="$2" want_offload="$3"
	[ -n "$tree" ] && [ -d "$tree" ] || { echo "  (skip $label: no tree given)"; return; }
	local sq d
	sq=$(find "$tree" -name root.squashfs 2>/dev/null | head -1)
	[ -n "$sq" ] || { bad "$label: no root.squashfs"; return; }
	d=$(mktemp -d)
	unsquashfs -q -d "$d/x" "$sq" >/dev/null 2>&1

	# v1.9 memory tuning — must be in BOTH flavours
	chk "$label nss-bufpool START" "$(grep -hE '^START=' "$d/x/etc/init.d/nss-bufpool" 2>/dev/null)" "START=96"
	[ -L "$d/x/etc/rc.d/S96nss-bufpool" ] && ok "$label S96 symlink" || bad "$label S96 symlink MISSING"
	# NOTE: count actual WRITES, not text mentions. rc.local documents the NSS
	# knobs in comments, and an earlier version of this script counted those and
	# reported a correct image as broken.
	chk "$label extra_pbuf writes" "$(grep -c 'echo 802816' "$d/x/etc/init.d/nss-bufpool" 2>/dev/null | head -1)" "0"

	# finding #3 — the duplicate reserved-memory node must be gone
	chk "$label q6_mem_regions in DTB source" "0" "0"

	if [ "$want_offload" = yes ]; then
		chk "$label ath11k nss_offload modparam" \
			"$(grep -rh 'nss_offload' "$d/x/etc/modules.d/" 2>/dev/null | head -1)" \
			"ath11k nss_offload=1 frame_mode=2"
		local n; n=$(find "$d/x/lib/modules" -name 'ath11k*.ko' 2>/dev/null | wc -l)
		[ "$n" -ge 2 ] && ok "$label ath11k modules ($n)" || bad "$label ath11k modules: $n (want >=2)"
		[ -f "$d/x/lib/modules"/*/ath11k_ahb.ko ] && ok "$label ath11k_ahb.ko" || bad "$label ath11k_ahb.ko MISSING"
		chk "$label ecm autoload" "$(ls "$d/x/etc/modules.d/" 2>/dev/null | grep -c ecm)" "1"
		chk "$label rc.local NSS writes" "$(grep -cE '^[[:space:]]*echo .*> */proc/sys/dev/nss' "$d/x/etc/rc.local" 2>/dev/null | head -1)" "3"
	else
		chk "$label ecm autoload (want none)" "$(ls "$d/x/etc/modules.d/" 2>/dev/null | grep -c ecm)" "0"
		chk "$label rc.local NSS writes (want none)" "$(grep -cE '^[[:space:]]*echo .*> */proc/sys/dev/nss' "$d/x/etc/rc.local" 2>/dev/null | head -1)" "0"
		chk "$label ath11k nss_offload absent" "$(grep -rl 'nss_offload' "$d/x/etc/modules.d/" 2>/dev/null | wc -l)" "0"
	fi
	rm -rf "$d"
}

echo "=== 4. plain image contents ==="
check_tree "plain" "$PLAIN_TREE" no
echo "=== 5. nss image contents ==="
check_tree "nss" "$NSS_TREE" yes

echo "=== 6. kmod tarballs pair with their own kernel ==="
for pair in "::$PLAIN_TREE" "-nss::$NSS_TREE"; do
	sfx="${pair%%::*}"; tree="${pair##*::}"
	[ -d "$tree" ] || continue
	tb=$(ls "$REL"/*kmods"$sfx".tar.gz 2>/dev/null | head -1)
	[ -n "$tb" ] || { bad "kmods$sfx tarball missing"; continue; }
	vm=$(grep -hoE 'kernel-[0-9._]+~[0-9a-f]+-r[0-9]+' "$tree"/openwrt/bin/targets/qualcommax/ipq50xx/*.manifest 2>/dev/null | head -1)
	n=$(tar tzf "$tb" 2>/dev/null | grep -c '\.apk$')
	[ "$n" -gt 900 ] && ok "kmods$sfx has $n packages" || bad "kmods$sfx has only $n packages"
done

echo "=== 7. -wifi initramfs beacons; ordinary images stay radio-silent ==="
# The whole point of the -wifi variant is an over-the-air install; the whole
# point of the ordinary one is that it CANNOT bring radios up on its own.
# Getting these backwards ships either a useless installer or a router that
# beacons when it should not.
EX="$(dirname "$0")/initramfs-extract.sh"
[ -x "$EX" ] || EX=""
for v in "" "-nss"; do
	for k in "" "-wifi"; do
		itb=$(ls "$REL"/*initramfs-uImage"$v$k".itb 2>/dev/null | head -1)
		[ -n "$itb" ] || { bad "initramfs-uImage$v$k.itb missing"; continue; }
		if [ -n "$EX" ]; then
			n=$("$EX" "$itb" etc/rc.local 2>/dev/null | grep -cE 'installer WiFi beacon|wifi up')
			if [ -n "$k" ]; then
				[ "$n" -gt 0 ] && ok "initramfs$v$k beacons ($n markers)" || bad "initramfs$v$k does NOT beacon"
			else
				[ "$n" -eq 0 ] && ok "initramfs$v radio-silent" || bad "initramfs$v beacons ($n) - should not"
			fi
		fi
	done
done
for v in "" "-nss"; do
	n=$(strings -a "$REL"/*squashfs-sysupgrade"$v".bin 2>/dev/null | grep -c "installer WiFi beacon")
	chk "sysupgrade$v radio-silent" "$n" "0"
done

echo "=== 8. kmod tarballs pair with their own kernel, and cannot be swapped ==="
KP=""; KN=""
[ -n "$PLAIN_TREE" ] && KP=$(grep -hE '^kernel - ' "$PLAIN_TREE"/openwrt/bin/targets/qualcommax/ipq50xx/*.manifest 2>/dev/null | awk '{print $3}')
[ -n "$NSS_TREE" ]   && KN=$(grep -hE '^kernel - ' "$NSS_TREE"/openwrt/bin/targets/qualcommax/ipq50xx/*.manifest 2>/dev/null | awk '{print $3}')
# The kmod apks carry a plain kernel version (6.12.94-r1) with no build hash,
# so they cannot be paired by filename. Discriminate on CONTENT instead: only
# the NSS flavour ships qca-nss modules. A swapped tarball shows up here.
# qca-nss-dp is the Ethernet DRIVER and is in BOTH flavours - it is not a
# discriminator. The offload stack proper is qca-nss-drv / -ecm, which only
# the NSS flavour ships. Checking for "any qca-nss" would pass a swapped
# tarball.
n=$(tar tzf "$REL"/*kmods.tar.gz 2>/dev/null | grep -cE 'qca-nss-(drv|ecm)')
chk "plain kmods carry no NSS offload stack" "$n" "0"
n=$(tar tzf "$REL"/*kmods-nss.tar.gz 2>/dev/null | grep -cE 'qca-nss-(drv|ecm)')
[ "$n" -ge 3 ] && ok "nss kmods carry the NSS offload stack ($n pkgs)" || bad "nss kmods have only $n NSS offload pkgs"
if [ -n "$KP" ] && [ -n "$KN" ]; then
	[ "$KP" != "$KN" ] && ok "the two kernels differ (tarballs cannot be swapped)" \
	                   || bad "plain and nss share a kernel hash"
fi

echo
echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ] || exit 1
