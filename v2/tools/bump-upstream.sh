#!/bin/bash
# bump-upstream.sh <release tag>: move v2 to another kuncy7 release, as far as hal can check
# it without building or flashing anything.
#
#  1. fetch the tag into our mirror of his tree, and his nss feed into ours, never pruning
#     (his CI deletes old releases and the feed branch gets rebased), and tag the pinned
#     commits rd03v2/<release> in both mirrors so they stay reachable;
#  2. freeze his feeds as of his CI run for that commit (tools/freeze-feeds.sh) and rewrite
#     upstream.lock and feeds.lock in place, for review with git diff;
#  3. PREPARE_ONLY build into a scratch tree: our tree patches apply (git am), the overlay
#     overwrites nothing of his, every feed pins, defconfig drops nothing we asked for;
#  4. his mac80211 series plus ours without fuzz (tools/check-mac80211-series.sh), and the
#     kernel prepared with OpenWrt's own patching, with fuzz or a failure in any of our kernel
#     patches reported.
#
# A failing tree patch, or one of our patches that no longer applies, usually means his tree
# now does what it did: drop ours, or refresh it. Then: a full build, verify-v2.sh, and a
# smoke test on the bench. The full phase C matrix is for releases.
#
# FEEDS_FROZEN_AT_OVERRIDE=<ISO 8601> sets the freeze time. Default: unchanged when re-preparing
# the locked release, else his CI run's start + 4 min (GitHub API), when feeds update has run.
set -euo pipefail
NEW=${1:?usage: $0 <release tag, e.g. ipq50xx-2026.10.09>}
cd "$(dirname "$0")/../.."
REPO=$PWD V2=$PWD/v2
. "$V2/upstream.lock"
NSS_MIRROR=${V2_NSS_MIRROR:-/home/agiu/dev/routers/rd03v2/mirrors/nss-packages.git}
NSS_URL=https://github.com/kuncy7/nss-packages.git
die() { echo "bump-upstream: $*" >&2; exit 1; }
[ -z "$(git -C "$REPO" status --porcelain -- v2/upstream.lock v2/feeds.lock)" ] ||
	die "v2/upstream.lock or v2/feeds.lock has uncommitted changes"

# 1. mirrors (no --prune: what we built on stays)
git -C "$MIRROR" fetch -q origin "+refs/tags/$NEW:refs/tags/$NEW" '+refs/heads/*:refs/heads/*'
C=$(git -C "$MIRROR" rev-parse "refs/tags/$NEW^{commit}")
git -C "$NSS_MIRROR" fetch -q "$NSS_URL" '+refs/heads/*:refs/heads/*'
echo "release $NEW = $C ($(git -C "$MIRROR" log -1 --format='%cI' "$C"))"

# 2. feeds as of his CI run
if [ -n "${FEEDS_FROZEN_AT_OVERRIDE:-}" ]; then
	FEEDS_FROZEN_AT=$FEEDS_FROZEN_AT_OVERRIDE
elif [ "$NEW" != "$RELEASE" ]; then
	FEEDS_FROZEN_AT=
fi
if [ -z "$FEEDS_FROZEN_AT" ]; then
	started=$(gh api "repos/kuncy7/openwrt-nss-edma/actions/runs?head_sha=$C" \
		--jq '[.workflow_runs[] | select(.path | test("ipq50xx"))] | sort_by(.run_started_at) | .[0].run_started_at' 2>/dev/null || true)
	[ -n "$started" ] && [ "$started" != null ] ||
		die "no CI run found for $C; set FEEDS_FROZEN_AT_OVERRIDE=<ISO 8601>"
	FEEDS_FROZEN_AT=$(date -u -d "$started + 4 min" +%Y-%m-%dT%H:%M:%SZ)
fi
conf=$(mktemp); trap 'rm -f "$conf"' EXIT
git -C "$MIRROR" show "$C:feeds.conf.default" > "$conf"
new_feeds=$("$V2/tools/freeze-feeds.sh" "$conf" "$FEEDS_FROZEN_AT")
nss=$(awk '$1 == "nss" { print $2 }' <<<"$new_feeds")
[ -n "$nss" ] || die "his feeds.conf.default has no nss feed"
git -C "$NSS_MIRROR" cat-file -e "$nss^{commit}" 2>/dev/null ||
	die "nss feed commit $nss is not in $NSS_MIRROR (rebased away before we fetched?)"
git -C "$MIRROR" tag -f "rd03v2/$NEW" "$C" >/dev/null
git -C "$NSS_MIRROR" tag -f "rd03v2/$NEW" "$nss" >/dev/null

sed -i -e "s/^RELEASE=.*/RELEASE=$NEW/" -e "s/^COMMIT=.*/COMMIT=$C/" \
	-e "s/^FEEDS_FROZEN_AT=.*/FEEDS_FROZEN_AT=$FEEDS_FROZEN_AT/" "$V2/upstream.lock"
grep -q "^COMMIT=$C\$" "$V2/upstream.lock" || die "could not rewrite upstream.lock"
echo "NOTE: update the release/commit times in the comment of v2/upstream.lock by hand"
# his feeds from the freeze; ours (not in his feeds.conf.default) keep their lines
{
	echo "# <feed> <commit>: v2/tools/freeze-feeds.sh <his feeds.conf.default> $FEEDS_FROZEN_AT"
	echo "$new_feeds"
	awk 'NR > 1' "$V2/feeds.lock" | awk -v his="$(cut -d' ' -f1 <<<"$new_feeds" | xargs)" '
		BEGIN { n = split(his, h, " "); for (i = 1; i <= n; i++) skip[h[i]] = 1 }
		/^#/ { c = c $0 "\n"; next }
		!($1 in skip) { printf "%s%s\n", c, $0 } { c = "" }'
} > "$V2/feeds.lock.new" && mv "$V2/feeds.lock.new" "$V2/feeds.lock"
git -C "$REPO" --no-pager diff --stat -- v2/upstream.lock v2/feeds.lock

# 3. prepare a scratch tree
W=$(mktemp -d); TREE=$W/openwrt-v2
echo "scratch tree: $TREE"
TAG=DEV-bump PREPARE_ONLY=1 TREE="$TREE" "$V2/build.sh"

# 4a. mac80211, strict
"$V2/tools/check-mac80211-series.sh" "$TREE" "$W/mac80211"
# 4b. kernel, with OpenWrt's patching; ours must apply without fuzz
ln -s "${V2_DL:-/home/agiu/dev/routers/rd03v2/dl-v2}" "$TREE/dl"
(cd "$TREE" && make target/linux/prepare V=s > "$W/kernel-prepare.log" 2>&1) ||
	die "kernel prepare failed: $W/kernel-prepare.log"
ours=$(cd "$V2/overlay/target/linux/qualcommax" 2>/dev/null && ls patches-*/*.patch 2>/dev/null | xargs -r -n1 basename || true)
bad=$(awk -v ours=" $(echo $ours) " '
	/^Applying .*\.patch/ { p = $2; sub(".*/", "", p) }
	/with fuzz|FAILED|Reversed/ && index(ours, " " p " ") { print p ": " $0 }' "$W/kernel-prepare.log")
[ -z "$bad" ] || die "our kernel patches do not apply cleanly:
$bad"
echo "kernel: our patches ($(echo $ours)) apply without fuzz"
echo "bump-upstream: $NEW prepared; next: a full build (TAG=DEV-<name> v2/build.sh), verify, bench smoke test"
