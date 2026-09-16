#!/bin/sh
# check-scandeps.sh - does mac80211's SCAN_DEPS actually make ath.mk a
# prerequisite of its package metadata?
#
# WHY THIS EXISTS
# tools/integrate-wifi-nss.py edits package/kernel/mac80211/ath.mk. If ath.mk is
# not a scan dependency, an incremental build can mix a NEW ath.mk with OLD
# metadata, and .packagedeps - where ALL_VARIANTS comes from - is regenerated
# from the stale copy. The ath11k bus packages are variant-gated, so that is not
# cosmetic.
#
# The trap this guards against is specific and was shipped once: an ABSOLUTE
# glob silently captures the wrong directory. scan.mk:81 greps the SCAN_DEPS
# text into a generated makefile expanded at TOP LEVEL, and scan.mk:48 rebases
# each entry onto $(SCAN_DIR)/$(2)/ ONLY when it is not absolute. So
#
#     SCAN_DEPS = *.mk                        -> package/kernel/mac80211/*.mk   (right)
#     SCAN_DEPS = $(wildcard $(CURDIR)/*.mk)  -> <openwrt topdir>/rules.mk      (wrong)
#
# Both look plausible; only one works, and the failure is silent. This resolves
# the line the same way scan.mk does and asserts the answer.
#
# Usage: tools/check-scandeps.sh <openwrt-tree>
set -eu

TREE="${1:?usage: check-scandeps.sh <openwrt-tree>}"
PKG=package/kernel/mac80211
MK="$TREE/$PKG/Makefile"
WANT=ath.mk

[ -f "$MK" ] || { echo "ERROR: no $MK" >&2; exit 1; }

# scan.mk:81 - same regex, same strip.
DEPS=$(grep -hE '^ *SCAN_DEPS *= *' "$MK" | sed -e 's/^.*DEPS *= *//' || true)

if [ -z "$DEPS" ]; then
	echo "FAIL: $PKG/Makefile declares no SCAN_DEPS" >&2
	echo "      ath.mk is then not a prerequisite of its packageinfo." >&2
	exit 1
fi

# scan.mk:48 - absolute entries stand, relative ones rebase onto the package dir.
# Expand each pattern INSIDE the directory it belongs to. Two traps here, both
# hit during development:
#   * `for dep in $DEPS` glob-expands against the CALLER's cwd. build.sh runs
#     this from the openwrt tree, which has rules.mk, so "*.mk" silently became
#     "rules.mk" and the check failed on a correct Makefile.
#   * `$(cd "$dir" && ls -d $dep)` does not help: the expansion still happens in
#     the caller before the subshell starts.
# So: keep globbing off while iterating the patterns, and turn it back on only
# inside the subshell that has already cd'd to the right place.
set -f
resolved=""
for dep in $DEPS; do
	case "$dep" in
	/*)	dir="$TREE" ;;
	*)	dir="$TREE/$PKG" ;;
	esac
	[ -d "$dir" ] || continue
	hits=$(cd "$dir" && set +f && for m in $dep; do [ -e "$m" ] && echo "$m"; done)
	resolved="$resolved $hits"
done
set +f

for f in $resolved; do
	if [ "$(basename "$f")" = "$WANT" ]; then
		echo "OK: SCAN_DEPS resolves to $WANT (+$(($(echo $resolved | wc -w) - 1)) sibling .mk files)"
		exit 0
	fi
done

echo "FAIL: SCAN_DEPS = $DEPS" >&2
echo "      resolves to:${resolved:- (nothing)}" >&2
echo "      $WANT is NOT among them, so editing it will not force a metadata rescan." >&2
echo "      Use a RELATIVE glob (see package/firmware/linux-firmware/Makefile)." >&2
exit 1
