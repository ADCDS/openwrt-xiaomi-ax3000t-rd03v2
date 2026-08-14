#!/usr/bin/env bash
# mkrelease.sh — assemble the release asset set for a tag, from two finished
# build trees (default flavour + NSS flavour).
#
# WHY THIS EXISTS
#   Releases here are entirely manual: two builds, a dozen images that have to
#   be renamed with the -nss suffix by hand, and a sha256sums.txt the release
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
# WHAT v1.7 ADDED
#   Each tree now yields TWO initramfs flavours. The ordinary one comes up with
#   both radios disabled (correct for an installed system); the "-wifi" one
#   beacons while it is running from RAM, so an install can be driven with no
#   LAN cable — see tools/wifi-initramfs.sh and tools/installer-wifi.rc.local.
#   Only the initramfs artifacts are taken from that second pass; the squashfs
#   images still come from the radio-silent pass, so a release still contains
#   exactly two sysupgrade images.
#
#   Two names that differ but bytes that do not is the whole failure mode there,
#   and a "-wifi" image that does not beacon is useless in exactly the situation
#   it exists for (no cable, no serial). Worse in the other direction: an
#   ordinary image that DOES beacon would put an open-ish AP on a box with no
#   root password. So this does not trust the filenames — it reads
#   /etc/rc.local back out of all eight initramfs artifacts and checks each one
#   is what its name claims.
#
#   It also emits nand-support.txt (tools/mknand-support.sh), so an installer
#   can gate on the release itself instead of a hardcoded chip table.
#
# Usage:
#   TAG=v1.7 \
#   DEFAULT_TREE=~/rel-v17-default/openwrt \
#   NSS_TREE=~/rel-v17-nss/openwrt \
#   OUT=~/rel-v1.7 \
#   ./tools/mkrelease.sh
#
# Both trees must have been built with KMODS=1 (see build.sh) — otherwise the
# kmod tarball is a stub that does not match its own image — and both must have
# had tools/wifi-initramfs.sh run over them.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TAG="${TAG:?set TAG, e.g. TAG=v1.7}"
DEFAULT_TREE="${DEFAULT_TREE:?set DEFAULT_TREE=/path/to/openwrt}"
NSS_TREE="${NSS_TREE:?set NSS_TREE=/path/to/openwrt}"
OUT="${OUT:-$PWD/rel-$TAG}"

T=bin/targets/qualcommax/ipq50xx
PREFIX=openwrt-qualcommax-ipq50xx-xiaomi_mi-router-ax3000t-v2

# From the ordinary, radio-silent build.
IMAGES=(
	"$PREFIX-initramfs-factory.ubi"
	"$PREFIX-initramfs-uImage.itb"
	"$PREFIX-squashfs-factory.ubi"
	"$PREFIX-squashfs-sysupgrade.bin"
)
# From the second image pass. Initramfs only — see the header.
WIFI_IMAGES=(
	"$PREFIX-initramfs-factory-wifi.ubi"
	"$PREFIX-initramfs-uImage-wifi.itb"
)
# Below this, the tree was plainly not built with KMODS=1 (a stock build has
# about 60). Not a tuned threshold — just far enough from both cases to tell
# them apart.
MIN_KMODS=500

# The functional payload of tools/installer-wifi.rc.local, not one of its
# comments — this still has to work if the comments are ever trimmed.
MARKER='OpenWrt-RD03v2-Installer'
EXTRACT="$REPO/tools/initramfs-extract.sh"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -x "$EXTRACT" ] || die "missing or non-executable $EXTRACT"
[ -x "$REPO/tools/mknand-support.sh" ] || die "missing tools/mknand-support.sh"

# "kernel-6.12.94~90960c...-r1.apk" -> "6.12.94~90960c...-r1". The canonical
# source is `make -C target/linux val.LINUX_VERMAGIC`, but that needs a
# configured tree and a make invocation; the kernel package filename carries
# the same identity for free.
kver() {
	local f
	f=$(ls "$1/$T/packages/"kernel-*.apk 2>/dev/null | head -n1) \
		|| die "no kernel-*.apk in $1/$T/packages — is this a finished build tree?"
	[ -n "$f" ] || die "no kernel-*.apk in $1/$T/packages — is this a finished build tree?"
	f=${f##*/kernel-}; echo "${f%.apk}"
}

# Read /etc/rc.local back out of a built initramfs and check it against what the
# artifact's name promises. Extraction failure is fatal, never "absent": a
# negative result is used as evidence here.
check_beacon() {  # check_beacon <image> <yes|no> <label>
	local img=$1 want=$2 label=$3 rcl
	rcl=$("$EXTRACT" "$img" etc/rc.local) \
		|| die "$label: could not read /etc/rc.local out of $(basename "$img")"
	if printf '%s' "$rcl" | grep -q "$MARKER"; then
		[ "$want" = yes ] \
			|| die "$label: $(basename "$img") must be radio-silent, but its /etc/rc.local beacons"
		# The gate is what keeps a -wifi image that somehow reached NAND quiet.
		printf '%s' "$rcl" | grep -q 'rootfs_type\|/proc/mounts' \
			|| die "$label: $(basename "$img") beacons with no tmpfs gate"
	else
		[ "$want" = no ] \
			|| die "$label: $(basename "$img") is a -wifi artifact but its /etc/rc.local does not beacon"
	fi
}

check_tree() {  # check_tree <tree> <label>
	local tree=$1 label=$2 i n
	[ -d "$tree/$T" ] || die "$label: no $T — not a finished build tree"
	for i in "${IMAGES[@]}"; do
		[ -f "$tree/$T/$i" ] || die "$label: missing image $i"
	done
	for i in "${WIFI_IMAGES[@]}"; do
		[ -f "$tree/$T/$i" ] || die "$label: missing $i — run tools/wifi-initramfs.sh on this tree"
	done
	[ -f "$tree/staging_dir/packages/qualcommax/packages.adb" ] \
		|| die "$label: no merged package index at staging_dir/packages/qualcommax"
	# `|| true` so pipefail does not turn "no kmods at all" — the case this
	# check exists for — into a silent exit before the message is printed.
	n=$(ls "$tree/$T/packages/"kmod-*.apk 2>/dev/null | wc -l || true)
	[ "$n" -ge "$MIN_KMODS" ] \
		|| die "$label: only $n kmods in $T/packages — rebuild with KMODS=1"
	# The index is signed with this tree's own key, and the image ships that
	# key in /etc/apk/keys. If it does not verify here it will not verify on
	# the device either, and the failure would only surface at install time.
	"$tree/staging_dir/host/bin/apk" verify --keys-dir "$tree" \
		"$tree/staging_dir/packages/qualcommax/packages.adb" >/dev/null 2>&1 \
		|| die "$label: package index does not verify against its own public-key.pem"

	# The -wifi pass must have changed the image, and changed it in the one way
	# it was supposed to. Names prove nothing; read the file out of both.
	local base wifi
	for wifi in "${WIFI_IMAGES[@]}"; do
		base=${wifi/-wifi./.}
		[ "$(sha256sum <"$tree/$T/$base")" != "$(sha256sum <"$tree/$T/$wifi")" ] \
			|| die "$label: $wifi is byte-identical to $base — the second image pass did nothing"
	done
	for i in "${IMAGES[@]}"; do
		case "$i" in *initramfs*) check_beacon "$tree/$T/$i" no "$label";; esac
	done
	for i in "${WIFI_IMAGES[@]}"; do
		check_beacon "$tree/$T/$i" yes "$label"
	done
	echo "    $label: $n kmods, kernel $(kver "$tree"), -wifi initramfs verified"
}

# foo-x.bin -> foo-x-nss.bin, but foo-x-wifi.itb -> foo-x-nss-wifi.itb: the
# flavour suffix goes before the variant suffix, so the four initramfs assets
# read …-uImage{,-nss}{,-wifi}.itb.
nssname() {
	local stem=${1%.*} ext=${1##*.}
	case "$stem" in
		*-wifi) echo "${stem%-wifi}-nss-wifi.$ext" ;;
		*)      echo "$stem-nss.$ext" ;;
	esac
}

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
		echo "packages=$(ls "$tree"/staging_dir/packages/qualcommax/*.apk 2>/dev/null | wc -l || true)"
		echo
		echo "These packages install ONLY on the $label image from this same"
		echo "release. A kmod depends on kernel=$(kver "$tree") exactly, and the"
		echo "index is signed with that image's own key. Both initramfs flavours"
		echo "($label and $label -wifi) come from this tree, so either works."
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
for i in "${IMAGES[@]}" "${WIFI_IMAGES[@]}"; do
	cp -f "$DEFAULT_TREE/$T/$i" "$OUT/$i"
	cp -f "$NSS_TREE/$T/$i"     "$OUT/$(nssname "$i")"
done

echo ">>> deriving nand-support.txt from the built kernel"
"$REPO/tools/mknand-support.sh" "$DEFAULT_TREE" > "$OUT/nand-support.txt"
# Both trees build the same spinand sources from the same pinned commit plus the
# same files/ patches, so a disagreement means one tree is not what it claims.
"$REPO/tools/mknand-support.sh" "$NSS_TREE" > "$OUT/.nand-support.nss"
diff -q <(grep -v '^#' "$OUT/nand-support.txt") <(grep -v '^#' "$OUT/.nand-support.nss") >/dev/null \
	|| die "the two trees disagree about which NAND parts the kernel supports"
rm -f "$OUT/.nand-support.nss"
# The whole point of the release: a Winbond unit must be listed as drivable.
grep -q '^be  ef:be' "$OUT/nand-support.txt" \
	|| die "nand-support.txt does not list the Winbond W25N01KW (flash_type be) — 4d074a2 is not in this build"
grep -q '^11  c8:11' "$OUT/nand-support.txt" \
	|| die "nand-support.txt does not list the ESMT F50D1G41LB (flash_type 11)"

echo ">>> packing kmod repos (this takes a moment)"
kmodtar "$DEFAULT_TREE" "$OUT/$PREFIX-kmods.tar.gz"     default
kmodtar "$NSS_TREE"     "$OUT/$PREFIX-kmods-nss.tar.gz" nss

# Last, so it covers the tarballs too — the release notes promise it covers
# every asset.
( cd "$OUT" && rm -f sha256sums.txt && sha256sum -- * > sha256sums.txt )

# Cheap, and it catches the one thing the notes promise: an asset added to $OUT
# after this ran, or a name sha256sum could not read.
missing=$(cd "$OUT" && for f in *; do
	[ "$f" = sha256sums.txt ] && continue
	grep -q "  $f\$" sha256sums.txt || echo "$f"
done)
[ -z "$missing" ] || die "sha256sums.txt does not cover: $missing"

echo
echo "$TAG assets in $OUT:"
( cd "$OUT" && ls -lh )
echo
echo "  assets:         $(cd "$OUT" && ls | wc -l)"
echo "  default kernel: $(kver "$DEFAULT_TREE")"
echo "  nss     kernel: $(kver "$NSS_TREE")"
echo
echo "Publish with:"
echo "  gh release create $TAG --title '$TAG — ...' --notes-file NOTES.md $OUT/*"
