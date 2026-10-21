#!/bin/bash
# check-mac80211-series.sh <tree> [workdir]: apply the tree's whole mac80211 patch series to a
# fresh backports source, in the order of its Build/Patch (the NSS directories last, as with
# CONFIG_ATH11K_NSS_SUPPORT: patches/nss/<driver>, then patches/nss-extra/<driver> where the
# Makefile has it; the mesh directories only with WITH_MESH=1, as for
# CONFIG_ATH11K_NSS_MESH_SUPPORT, which the 256 MB group does not build), refusing any fuzz.
#
# OpenWrt's patch-kernel.sh applies with patch's default fuzz of 2, so a hunk of ours whose
# context drifted after a bump of his tree can land in the wrong place without an error. This
# check runs before the build (and from bump-upstream.sh). It leaves the patched source in
# <workdir>/src, a git repository with one commit per patch, for inspection.
#
# The one exception: a patch of his listed in mac80211-fuzz-reviewed.txt with its sha256 gets
# patch's default fuzz, after a review of where it lands. Ours never do.
#
# Exit status: 0 all patches applied without fuzz (or with reviewed fuzz), 1 otherwise.
set -euo pipefail
TREE=$(cd "${1:?usage: $0 <tree> [workdir]}" && pwd)
WORK=${2:-$(mktemp -d)}
MK=$TREE/package/kernel/mac80211/Makefile
PD=$TREE/package/kernel/mac80211/patches
V2=$(cd "$(dirname "$0")/.." && pwd)
REVIEWED=$V2/tools/mac80211-fuzz-reviewed.txt
die() { echo "check-mac80211-series: $*" >&2; exit 1; }
# reviewed <dir/file>: listed with this exact content, and not one of ours (the overlay's)
reviewed() {
	[ -e "$V2/overlay/package/kernel/mac80211/patches/$1" ] && return 1
	local h; h=$(sha256sum "$PD/$1" | cut -d' ' -f1)
	grep -vE '^\s*(#|$)' "$REVIEWED" 2>/dev/null | grep -qxF "$h $1"
}

# PKG_VERSION is either the version or derived from PKG_SOURCE_VERSION
srcver=$(sed -n 's/^PKG_SOURCE_VERSION:=//p' "$MK")
ver=$(sed -n 's/^PKG_VERSION:=//p' "$MK")
case $ver in *'$(PKG_SOURCE_VERSION)'*) ver=${srcver//-/_} ;; esac
hash=$(sed -n 's/^PKG_HASH:=//p' "$MK")
src=$(sed -n 's/^PKG_SOURCE:=//p' "$MK" | sed -e "s/\$(PKG_VERSION)/$ver/" -e "s/\$(PKG_SOURCE_VERSION)/$srcver/")
[ -n "$ver" ] && [ -n "$hash" ] && [ -n "$src" ] || die "cannot read PKG_VERSION/PKG_HASH/PKG_SOURCE from $MK"
tarball=$(readlink -f "$TREE/dl/$src" 2>/dev/null || true)
[ -f "$tarball" ] || tarball=${V2_DL:-${RD03V2_WS:-$(cd "$(dirname "$0")/../.." && pwd)}/dl-v2}/$src
[ -f "$tarball" ] || die "$src is not downloaded (make package/kernel/mac80211/download)"
echo "$hash  $tarball" | sha256sum -c --quiet - || die "$src does not match PKG_HASH"

# The directory order of Build/Patch, then the NSS directories (NSS_PATCH). The Makefile is
# parsed, not copied, so a reordering on his side shows up here.
mapfile -t dirs < <(sed -n '/^define Build\/Patch/,/^endef/s/.*PatchDir,$(PKG_BUILD_DIR),$(PATCH_DIR)\/\([a-z0-9]*\),.*/\1/p' "$MK")
nss=$(sed -n 's/^NSS_PATCH:= *//p' "$MK")
[ ${#dirs[@]} -ge 10 ] && [ -n "$nss" ] || die "cannot parse the Build/Patch order of $MK"
grep -q 'PatchDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/nss/$(driver),nss/$(driver)/' "$MK" ||
	die "the NSS patch loop of $MK changed"
for d in $nss; do dirs+=("nss/$d"); done
[ "${WITH_MESH:-0}" = 1 ] && dirs+=("nss/mesh")
extra=$(sed -n 's/^NSS_EXTRA_PATCH:= *//p' "$MK")
if [ -n "$extra" ]; then
	grep -q 'PatchDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/nss-extra/$(driver),nss-extra/$(driver)/' "$MK" ||
		die "the nss-extra patch loop of $MK changed"
	for d in $extra; do dirs+=("nss-extra/$d"); done
	[ "${WITH_MESH:-0}" = 1 ] && dirs+=("nss-extra/mesh")
fi

rm -rf "$WORK/src"; mkdir -p "$WORK/src"; cd "$WORK/src"
tar --zstd -xf "$tarball" --strip-components=1 2>/dev/null || tar -xf "$tarball" --strip-components=1
G="git -c user.name=check -c user.email=check@localhost"
git init -q && git add -A && $G commit -qm "backports-$ver"
n=0 nf=0 bad=0
for d in "${dirs[@]}"; do
	[ -d "$PD/$d" ] || continue
	[ -s "$PD/$d/series" ] && die "$d has a series file; this check does not handle it"
	for f in $(cd "$PD/$d" && LC_ALL=C ls -1 | LC_ALL=C sort); do
		fuzz=-F0
		reviewed "$d/$f" && fuzz=
		out=$(patch -p1 $fuzz --no-backup-if-mismatch -i "$PD/$d/$f" 2>&1) || {
			echo "FAIL $d/$f"; { echo "$out" | grep -E 'FAILED|rej|malformed' || echo "$out" | tail -5; } | sed 's/^/    /'; bad=1; break 2; }
		if [ -z "$fuzz" ]; then
			if grep -q 'with fuzz' <<<"$out"; then
				nf=$((nf + 1)); echo "NOTE $d/$f applies with reviewed fuzz"
			else
				echo "NOTE $d/$f is listed as reviewed but needs no fuzz now: drop its line"
			fi
		fi
		git add -A && $G commit -qm "$d/$f"
		n=$((n + 1))
	done
done
[ $bad = 0 ] || exit 1
echo "mac80211 $ver: $n patches applied, $nf of his with reviewed fuzz, none of ours (${dirs[*]}); source in $WORK/src"
