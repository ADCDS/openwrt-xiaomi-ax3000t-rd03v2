#!/bin/bash
# mkrelease-v2.sh <tree>: assemble the asset set of a v2 release from one finished build tree
# (v2/build.sh with TAG=<release>), into rel-v2-<tag>/. Publishes nothing.
#
# Refuses when the inputs look wrong rather than producing a plausible set that does not
# work, as tools/mkrelease.sh does for v1.x:
# - verify-v2.sh --tree must pass without a single failure;
# - the tag must be a release tag, not DEV-*, and the image's /etc/rd03v2-release must name it
#   and the repository URL it will be published under (publish-repo.sh);
# - the package index must verify against our committed public key;
# - nand-support.txt is derived from the kernel that was built (tools/mknand-support.sh), and
#   both NAND parts this board ships with must be in it.
#
# Assets: the sysupgrade image, the initramfs installer, the manifest and buildinfo files, the
# package repository as a tarball (the published repository keeps only recent releases), and
# sha256sums.txt over all of them. A v2 release is a GitHub pre-release: the v1.x installer
# tool reads releases/latest and expects the v1.x asset set.
set -euo pipefail
TREE=$(cd "${1:?usage: $0 <finished v2 build tree>}" && pwd)
cd "$(dirname "$0")/../.."
REPO=$PWD V2=$PWD/v2
T=$TREE/bin/targets/qualcommax/ipq50xx
P=openwrt-qualcommax-ipq50xx-xiaomi_mi-router-ax3000t-v2
die() { echo "mkrelease-v2: $*" >&2; exit 1; }

"$V2/tools/verify-v2.sh" --tree "$TREE" > "$TREE/verify-release.txt" 2>&1 ||
	die "verify-v2.sh failed, see $TREE/verify-release.txt"
X=$(mktemp -d); trap 'rm -rf "$X"' EXIT
tar -xOf "$T/$P-squashfs-sysupgrade.bin" --wildcards 'sysupgrade-*/root' > "$X/root.sqfs"
unsquashfs -q -d "$X/r" "$X/root.sqfs" etc/rd03v2-release >/dev/null 2>&1 || :
[ -f "$X/r/etc/rd03v2-release" ] || die "no /etc/rd03v2-release in the sysupgrade image"
. "$X/r/etc/rd03v2-release"
TAG=$RD03V2_TAG
case "$TAG" in DEV-*|'') die "the image is a development build ($TAG)";; esac
[ "$RD03V2_REPO" = "https://adcds.github.io/openwrt-xiaomi-ax3000t-rd03v2/v2/$TAG/packages.adb" ] ||
	die "the image lists $RD03V2_REPO, not the published repository of $TAG"
"$TREE/staging_dir/host/bin/apk" verify --keys-dir "$V2/keys" "$T/packages/packages.adb" >/dev/null 2>&1 ||
	die "the package index does not verify against v2/keys/public-key.pem"

OUT=$REPO/rel-v2-$TAG
[ -e "$OUT" ] && die "$OUT exists"
mkdir -p "$OUT"
for f in "$P-squashfs-sysupgrade.bin" "$P-initramfs-factory.ubi" "$P.manifest" \
	config.buildinfo feeds.buildinfo version.buildinfo; do
	[ -f "$T/$f" ] || die "missing $f"
	cp -p "$T/$f" "$OUT/"
done
"$REPO/tools/mknand-support.sh" "$TREE" > "$OUT/nand-support.txt"
# "<flash_type> <mfr:dev>" of the two parts RD03v2 units ship with: ESMT F50D1G41LB, Winbond
# W25N01KWZEIG (a part listed with flash_type "-" is one the bootloader cannot identify)
for id in '11 +c8:11' 'be +ef:be'; do
	grep -qE "^$id " "$OUT/nand-support.txt" || die "nand-support.txt lacks '$id', a NAND part RD03v2 units ship with"
done
tar -C "$T" -czf "$OUT/$P-packages-$TAG.tar.gz" --transform "s#^packages#packages-$TAG#" packages
(cd "$OUT" && sha256sum -- * > sha256sums.txt)
echo "mkrelease-v2: $TAG assembled in $OUT ($(ls "$OUT" | wc -l) files); kernel $(ls "$T"/packages/kernel-*.apk | sed 's#.*/kernel-##; s#\.apk$##')"
echo "next (approval needed): publish-repo.sh, then a GitHub pre-release with these assets"
