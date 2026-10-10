#!/bin/bash
# publish-repo.sh <tree> [pages worktree]: stage a release's package repository for GitHub
# Pages, at v2/<tag>/ of the gh-pages branch, which is the URL the image lists first in
# /etc/apk/repositories.d/distfeeds.list. Commits locally and stops: pushing gh-pages is what
# publishes, and needs an explicit OK.
#
# The repository holds what a v2 image installs from us: the kernel modules (they install only
# on the image of the same build), our extras (AmneziaWG, luci-app-nss) and the exact versions
# the image pins (95-rd03v2-apk-pins). Userspace otherwise comes from OpenWrt's snapshot feeds.
# GitHub Pages sites are limited to 1 GB; `du` below shows what each release costs.
set -euo pipefail
TREE=$(cd "${1:?usage: $0 <finished v2 build tree> [pages worktree]}" && pwd)
cd "$(dirname "$0")/../.."
REPO=$PWD V2=$PWD/v2
WT=${2:-$REPO/../pages-worktree}
T=$TREE/bin/targets/qualcommax/ipq50xx
P=openwrt-qualcommax-ipq50xx-xiaomi_mi-router-ax3000t-v2
die() { echo "publish-repo: $*" >&2; exit 1; }

X=$(mktemp -d); trap 'rm -rf "$X"' EXIT
tar -xOf "$T/$P-squashfs-sysupgrade.bin" --wildcards 'sysupgrade-*/root' > "$X/root.sqfs"
unsquashfs -q -d "$X/r" "$X/root.sqfs" etc/rd03v2-release >/dev/null 2>&1 || :
[ -f "$X/r/etc/rd03v2-release" ] || die "no /etc/rd03v2-release in the sysupgrade image"
. "$X/r/etc/rd03v2-release"
TAG=$RD03V2_TAG
case "$TAG" in DEV-*|'') die "the image is a development build ($TAG)";; esac
"$TREE/staging_dir/host/bin/apk" verify --keys-dir "$V2/keys" "$T/packages/packages.adb" >/dev/null 2>&1 ||
	die "the package index does not verify against v2/keys/public-key.pem"

# a local gh-pages worktree; the branch is created (orphan) the first time, locally only
if [ ! -d "$WT" ]; then
	if git -C "$REPO" rev-parse -q --verify refs/heads/gh-pages >/dev/null; then
		git -C "$REPO" worktree add -q "$WT" gh-pages
	else
		git -C "$REPO" worktree add -q --detach "$WT"
		git -C "$WT" checkout -q --orphan gh-pages
		git -C "$WT" rm -rq --cached . 2>/dev/null || true
		find "$WT" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
		touch "$WT/.nojekyll"
	fi
fi
[ "$(git -C "$WT" symbolic-ref --short HEAD)" = gh-pages ] || die "$WT is not on gh-pages"
D=$WT/v2/$TAG
[ -e "$D" ] && die "$D exists; a published release's repository is never replaced"
mkdir -p "$D"
cp -p "$T"/packages/*.apk "$T/packages/packages.adb" "$D/"
git -C "$WT" add -A
git -C "$WT" -c user.name="Adriel Santos" -c user.email=adriel@adriel.eu commit -q -m "v2 $TAG: package repository"
du -sh "$WT/v2"/* | sed 's/^/  /'
echo "publish-repo: $TAG staged in $WT (local commit $(git -C "$WT" rev-parse --short HEAD))"
echo "to publish (approval needed): git -C $WT push origin gh-pages"
