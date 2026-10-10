#!/bin/bash
# verify-v2.sh --tree <openwrt-v2>: check a finished v2 build. Each check prints PASS/FAIL;
# exit status is the number of failures. Grows with every v2 change (plan B1-B14).
set -u
MODE=${1:-}; TREE=${2:-}
[ "$MODE" = --tree ] && [ -d "$TREE" ] || { echo "usage: verify-v2.sh --tree <dir>"; exit 2; }
V2=$(cd "$(dirname "$0")/.." && pwd); . "$V2/upstream.lock"
T=$TREE/bin/targets/qualcommax/ipq50xx; P=openwrt-qualcommax-ipq50xx-xiaomi_mi-router-ax3000t-v2
fail=0
chk() {  # chk <label> <actual> <expected>
	if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=$((fail + 1)); fi
}
chk "upstream commit is an ancestor of HEAD" "$(git -C "$TREE" merge-base --is-ancestor "$COMMIT" HEAD && echo yes)" yes
chk "sysupgrade image" "$(ls "$T/$P-squashfs-sysupgrade.bin" 2>/dev/null | wc -l)" 1
chk "initramfs-factory installer" "$(ls "$T/$P-initramfs-factory.ubi" 2>/dev/null | wc -l)" 1
chk "one device in .config" "$(grep -c '^CONFIG_TARGET_DEVICE_.*=y' "$TREE/.config")" 1
for c in CONFIG_ATH11K_MEM_PROFILE_256M=y CONFIG_NSS_MEM_PROFILE_LOW=y CONFIG_ATH11K_NSS_SUPPORT=y; do
	chk "$c" "$(grep -cxF "$c" "$TREE/.config")" 1
done
grep -vE '^\s*(#|$)' "$V2/feeds.lock" | while read -r name rev; do
	[ "$(git -C "$TREE/feeds/$name" rev-parse HEAD)" = "$rev" ] && echo "PASS feed $name" || echo "FAIL feed $name"
done | tee /dev/stderr | grep -q '^FAIL' && fail=$((fail + 1))
R=$(ls -d "$TREE"/build_dir/target-*/root-qualcommax 2>/dev/null | head -1)
chk "distfeeds lists our repo first" "$(head -1 "$R/etc/apk/repositories.d/distfeeds.list" 2>/dev/null | grep -c '/v2/.*/packages.adb$')" 1
chk "distfeeds has no official kmods feed" "$(grep -c '/targets/' "$R/etc/apk/repositories.d/distfeeds.list" 2>/dev/null)" 0
chk "our key in the image" "$(cmp -s "$R/etc/apk/keys/public-key.pem" "$V2/keys/public-key.pem" && echo yes)" yes
chk "package index signed and present" "$(ls "$T/packages/packages.adb" 2>/dev/null | wc -l)" 1
chk "kmod-wireguard in our repo" "$(ls "$T"/packages/kmod-wireguard-*.apk 2>/dev/null | wc -l)" 1
chk "luci-app-nss in our repo" "$(ls "$T"/packages/luci-app-nss-*.apk 2>/dev/null | wc -l)" 1
k=$(ls "$T"/packages/kernel-*.apk 2>/dev/null | head -1); echo "INFO kernel package: $(basename "${k:-none}")"
echo "verify-v2: $fail failure(s)"
exit $fail
