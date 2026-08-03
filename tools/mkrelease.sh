#!/usr/bin/env bash
# mkrelease.sh — assemble the release asset set for a tag, from two finished
# build trees (default flavour + NSS flavour).
#
# WHY THIS EXISTS
#   Releases here are entirely manual: two builds, eight images that have to be
#   renamed with the -nss suffix by hand, and a sha256sums.txt the release
#   notes promise "covers all assets". Doing that by hand is how you end up
#   shipping a kmod tarball built from a different tree than the image next to
#   it — and with kmods that is not cosmetic. A kmod hard-depends on
#   "kernel=<version>~<vermagic>-r<rel>", the vermagic is an md5 over the
#   kernel config, and KMODS=1 changes that config. Images from one tree and
#   kmods from another silently refuse to install. The two trees also carry
#   different apk signing keys (build.sh clones fresh, so each run generates
#   its own private-key.pem and the image ships only its own public half).
#
#   So this pairs each image set with the kmod repo from the SAME tree, and
#   refuses to run when the inputs look wrong rather than producing a plausible
#   set of assets that does not work.
#
# Usage:
#   TAG=v1.7 \
#   DEFAULT_TREE=~/rel-v17-default/openwrt \
#   NSS_TREE=~/rel-v17-nss/openwrt \
#   OUT=~/rel-v1.7 \
#   ./tools/mkrelease.sh
#
# Both trees must have been built with KMODS=1 (see build.sh) — otherwise the
# kmod tarball is a stub that does not match its own image anyway.
set -euo pipefail

TAG="${TAG:?set TAG, e.g. TAG=v1.7}"
DEFAULT_TREE="${DEFAULT_TREE:?set DEFAULT_TREE=/path/to/openwrt}"
NSS_TREE="${NSS_TREE:?set NSS_TREE=/path/to/openwrt}"
OUT="${OUT:-$PWD/rel-$TAG}"

T=bin/targets/qualcommax/ipq50xx
PREFIX=openwrt-qualcommax-ipq50xx-xiaomi_mi-router-ax3000t-v2
IMAGES=(
	"$PREFIX-initramfs-factory.ubi"
	"$PREFIX-initramfs-uImage.itb"
	"$PREFIX-squashfs-factory.ubi"
	"$PREFIX-squashfs-sysupgrade.bin"
)
# Below this, the tree was plainly not built with KMODS=1 (a stock build has
# about 60). Not a tuned threshold — just far enough from both cases to tell
# them apart.
MIN_KMODS=500

die() { echo "ERROR: $*" >&2; exit 1; }

# "kernel-6.12.94~90960c...-r1.apk" -> "6.12.94~90960c...-r1". The canonical
# source is `make -C target/linux/ val.LINUX_VERMAGIC`, but that needs a
# configured tree and a make invocation; the kernel package filename carries
# the same identity for free.
kver() {
	local f
	f=$(ls "$1/$T/packages/"kernel-*.apk 2>/dev/null | head -n1) \
		|| die "no kernel-*.apk in $1/$T/packages — is this a finished build tree?"
	[ -n "$f" ] || die "no kernel-*.apk in $1/$T/packages — is this a finished build tree?"
	f=${f##*/kernel-}; echo "${f%.apk}"
}

check_tree() {  # check_tree <tree> <label>
	local tree=$1 label=$2 i n
	[ -d "$tree/$T" ] || die "$label: no $T — not a finished build tree"
	for i in "${IMAGES[@]}"; do
		[ -f "$tree/$T/$i" ] || die "$label: missing image $i"
	done
	[ -f "$tree/staging_dir/packages/qualcommax/packages.adb" ] \
		|| die "$label: no merged package index at staging_dir/packages/qualcommax"
	n=$(ls "$tree/$T/packages/"kmod-*.apk 2>/dev/null | wc -l)
	[ "$n" -ge "$MIN_KMODS" ] \
		|| die "$label: only $n kmods in $T/packages — rebuild with KMODS=1"
	# The index is signed with this tree's own key, and the image ships that
	# key in /etc/apk/keys. If it does not verify here it will not verify on
	# the device either, and the failure would only surface at install time.
	"$tree/staging_dir/host/bin/apk" verify --keys-dir "$tree" \
		"$tree/staging_dir/packages/qualcommax/packages.adb" >/dev/null 2>&1 \
		|| die "$label: package index does not verify against its own public-key.pem"
	echo "    $label: $n kmods, kernel $(kver "$tree")"
}

nssname() { local b=$1; echo "${b%.*}-nss.${b##*.}"; }   # foo.bin -> foo-nss.bin

kmodtar() {  # kmodtar <tree> <output.tar.gz> <label>
	local tree=$1 out=$2 label=$3 tmp
	tmp=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp'" RETURN
	{
		echo "tag=$TAG"
		echo "flavour=$label"
		echo "kernel=$(kver "$tree")"
		echo "openwrt=$(cat "$tree/$T/version.buildinfo" 2>/dev/null || echo unknown)"
		echo "packages=$(ls "$tree"/staging_dir/packages/qualcommax/*.apk 2>/dev/null | wc -l)"
		echo
		echo "These packages install ONLY on the $label image from this same"
		echo "release. A kmod depends on kernel=$(kver "$tree") exactly, and the"
		echo "index is signed with that image's own key."
		echo
		echo "Serve this directory from your PC and install over the network:"
		echo
		echo "  python3 -m http.server 8000          # here, on your PC"
		echo
		echo "  # on the router (the NAND system, NOT the RAM initramfs):"
		echo "  apk add --repositories-file /dev/null \\"
		echo "          --repository http://<pc-ip>:8000/packages.adb kmod-<name>"
		echo
		echo "The --repository argument must name packages.adb, not the directory."
	} > "$tmp/VERSION"
	# -h: the merged repo is symlinks into bin/. Two -C so VERSION rides along.
	tar -czhf "$out" -C "$tree/staging_dir/packages/qualcommax" . -C "$tmp" VERSION
}

echo ">>> checking build trees"
check_tree "$DEFAULT_TREE" default
check_tree "$NSS_TREE"     nss

# Two different flavours must not share a vermagic; if they do, the same tree
# was almost certainly passed twice and one set of assets would be mislabelled.
[ "$(kver "$DEFAULT_TREE")" != "$(kver "$NSS_TREE")" ] \
	|| die "both trees report the same kernel vermagic — is NSS_TREE really the NSS build?"
[ "$(sha256sum <"$DEFAULT_TREE/$T/$PREFIX-squashfs-sysupgrade.bin")" \
  != "$(sha256sum <"$NSS_TREE/$T/$PREFIX-squashfs-sysupgrade.bin")" ] \
	|| die "both trees produced an identical sysupgrade image — same tree twice?"

echo ">>> collecting images"
mkdir -p "$OUT"
for i in "${IMAGES[@]}"; do
	cp -f "$DEFAULT_TREE/$T/$i" "$OUT/$i"
	cp -f "$NSS_TREE/$T/$i"     "$OUT/$(nssname "$i")"
done

echo ">>> packing kmod repos (this takes a moment)"
kmodtar "$DEFAULT_TREE" "$OUT/$PREFIX-kmods.tar.gz"     default
kmodtar "$NSS_TREE"     "$OUT/$PREFIX-kmods-nss.tar.gz" nss

# Last, so it covers the tarballs too — the release notes promise it covers
# every asset.
( cd "$OUT" && rm -f sha256sums.txt && sha256sum -- * > sha256sums.txt )

echo
echo "$TAG assets in $OUT:"
( cd "$OUT" && ls -lh )
echo
echo "  default kernel: $(kver "$DEFAULT_TREE")"
echo "  nss     kernel: $(kver "$NSS_TREE")"
echo
echo "Publish with:"
echo "  gh release create $TAG --title '$TAG — ...' --notes-file NOTES.md $OUT/*"
