#!/bin/bash
# check-mac80211-series.sh <tree> [workdir]: apply the tree's whole mac80211 patch series to a
# fresh backports source, in the order of its Build/Patch (NSS directories last, as with
# CONFIG_ATH11K_NSS_SUPPORT), refusing any fuzz.
#
# OpenWrt's patch-kernel.sh applies with patch's default fuzz of 2, so a hunk of ours whose
# context drifted after a bump of his tree can land in the wrong place without an error. This
# check runs before the build (and from bump-upstream.sh). It leaves the patched source in
# <workdir>/src, a git repository with one commit per patch, for inspection.
#
# Exit status: 0 all patches applied without fuzz, 1 otherwise.
set -euo pipefail
TREE=$(cd "${1:?usage: $0 <tree> [workdir]}" && pwd)
WORK=${2:-$(mktemp -d)}
MK=$TREE/package/kernel/mac80211/Makefile
PD=$TREE/package/kernel/mac80211/patches
die() { echo "check-mac80211-series: $*" >&2; exit 1; }

ver=$(sed -n 's/^PKG_VERSION:=//p' "$MK")
hash=$(sed -n 's/^PKG_HASH:=//p' "$MK")
src=$(sed -n 's/^PKG_SOURCE:=//p' "$MK" | sed "s/\$(PKG_VERSION)/$ver/")
[ -n "$ver" ] && [ -n "$hash" ] && [ -n "$src" ] || die "cannot read PKG_VERSION/PKG_HASH/PKG_SOURCE from $MK"
tarball=$(readlink -f "$TREE/dl/$src" 2>/dev/null || true)
[ -f "$tarball" ] || tarball=${V2_DL:-/home/agiu/dev/routers/rd03v2/dl-v2}/$src
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

rm -rf "$WORK/src"; mkdir -p "$WORK/src"; cd "$WORK/src"
tar --zstd -xf "$tarball" --strip-components=1 2>/dev/null || tar -xf "$tarball" --strip-components=1
G="git -c user.name=check -c user.email=check@localhost"
git init -q && git add -A && $G commit -qm "backports-$ver"
n=0 bad=0
for d in "${dirs[@]}"; do
	[ -d "$PD/$d" ] || continue
	[ -s "$PD/$d/series" ] && die "$d has a series file; this check does not handle it"
	for f in $(cd "$PD/$d" && LC_ALL=C ls -1 | LC_ALL=C sort); do
		out=$(patch -p1 -F0 --no-backup-if-mismatch -i "$PD/$d/$f" 2>&1) || {
			echo "FAIL $d/$f"; echo "$out" | grep -E 'FAILED|rej|malformed' | sed 's/^/    /'; bad=1; break 2; }
		git add -A && $G commit -qm "$d/$f"
		n=$((n + 1))
	done
done
[ $bad = 0 ] || exit 1
echo "mac80211 $ver: $n patches applied without fuzz (${dirs[*]}); source in $WORK/src"
