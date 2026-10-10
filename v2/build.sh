#!/bin/bash
# v2/build.sh: build the RD03v2 v2 image.
#
#   v2 = kuncy7's openwrt-nss-edma release (v2/upstream.lock)
#      + our changes to his files   (v2/tree-patches/*.patch, git am: no fuzz, fails loudly)
#      + our new files               (v2/overlay/, copied without overwriting anything of his;
#                                     v2/shared.list: files shared with the v1.x tree)
#      + feeds pinned to commits     (v2/feeds.lock)
#      + his CI config fragments plus ours (v2/config/), signed with our own key.
#
# The image lists our package repository (kernel modules and our extras) plus OpenWrt's
# official snapshot userspace feeds, like his CI does; the official target/kmods feeds are
# left out because their kernel is not ours.
#
# Usage: TAG=<release or DEV-name> [JOBS=n] [PREPARE_ONLY=1] [TREE=dir] v2/build.sh
#   V2_KEY_DIR    signing key dir (private-key.pem 0600 + public-key.pem)
#   V2_DL         persistent download cache
#   V2_REPO_URL   package repository URL baked into the image
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD V2=$PWD/v2
. "$V2/upstream.lock"
TAG=${TAG:?set TAG: a release name, or DEV-<something> for a local test build}
TREE=${TREE:-$REPO/openwrt-v2}
JOBS=${JOBS:-$(nproc)}
KEYDIR=${V2_KEY_DIR:-/home/agiu/dev/routers/rd03v2/keys/v2}
DLDIR=${V2_DL:-/home/agiu/dev/routers/rd03v2/dl-v2}
REPO_URL=${V2_REPO_URL:-https://adcds.github.io/openwrt-xiaomi-ax3000t-rd03v2/v2/$TAG/packages.adb}
NSS_MIRROR=${V2_NSS_MIRROR:-/home/agiu/dev/routers/rd03v2/mirrors/nss-packages.git}
die() { echo "build.sh: $*" >&2; exit 1; }
lines() { grep -vE '^\s*(#|$)' "$1" || true; }  # a list file without comments; empty is fine
# anchor <count> <ERE> <file>: the pattern must match exactly <count> lines, so an edit fails
# loudly when his tree moves instead of silently doing nothing (same as ../build.sh).
anchor() {
	local n; n=$(grep -cE -- "$2" "$3" || true)
	[ "$n" = "$1" ] || die "anchor: '$2' matches $n lines in $3, expected $1"
}

# 0. preflight
[ -e "$TREE" ] && die "$TREE exists; remove it first"
[ "$(stat -c %a "$KEYDIR/private-key.pem")" = 600 ] || die "$KEYDIR/private-key.pem must be mode 600"
openssl ec -in "$KEYDIR/private-key.pem" -pubout 2>/dev/null | cmp -s - "$KEYDIR/public-key.pem" ||
	die "public-key.pem does not match private-key.pem"
cmp -s "$KEYDIR/public-key.pem" "$V2/keys/public-key.pem" ||
	die "the signing key is not the one committed in v2/keys/public-key.pem"

# 1. his tree at the locked commit (full history: getver.sh derives the revision from it)
git clone -q --no-checkout "$MIRROR" "$TREE"
git -C "$TREE" checkout -q --detach "$COMMIT"
[ "$(git -C "$TREE" rev-parse HEAD)" = "$COMMIT" ] || die "checkout is not $COMMIT"
echo "base: $RELEASE $COMMIT ($(git -C "$TREE" log -1 --format=%cs))"
G="git -C $TREE -c user.name=rd03v2-v2 -c user.email=v2@localhost"

# 2. our changes to his files
shopt -s nullglob
patches=("$V2"/tree-patches/*.patch)
if [ ${#patches[@]} -gt 0 ]; then
	$G am -q "${patches[@]}" || die "a tree patch does not apply; his tree moved (git -C $TREE am --show-current-patch)"
	echo "tree patches: ${#patches[@]} applied"
fi

# 3. our new files, never overwriting his
copy_new() {  # copy_new <src> <dst relative to TREE>
	[ -e "$TREE/$2" ] && die "overlay would overwrite his $2"
	mkdir -p "$(dirname "$TREE/$2")"; cp -p "$1" "$TREE/$2"
}
(cd "$V2/overlay" && find . -type f -printf '%P\n') | while read -r f; do copy_new "$V2/overlay/$f" "$f"; done
lines "$V2/shared.list" | while read -r src dst; do
	copy_new "$REPO/$src" "$dst"
done
if [ -n "$($G status --porcelain)" ]; then $G add -A; $G commit -q -m "rd03v2 v2 overlay"; fi

# 4. feeds: his feed list, every feed pinned to a commit
F=$TREE/feeds.conf.default
anchor 1 '^src-git packages https://git.openwrt.org/feed/packages.git$' "$F"
anchor 1 '^src-git luci https://git.openwrt.org/project/luci.git$' "$F"
anchor 1 '^src-git routing https://git.openwrt.org/feed/routing.git$' "$F"
anchor 1 '^src-git telephony https://git.openwrt.org/feed/telephony.git$' "$F"
anchor 1 '^src-git video https://github.com/openwrt/video.git$' "$F"
anchor 1 '^src-git nss https://github.com/kuncy7/nss-packages.git;ipq50xx-rebase$' "$F"
# AmneziaWG (#39): not one of his feeds. Same community feed and pin as v1.x (../build.sh).
echo 'src-git amneziawg https://github.com/Slava-Shchipunov/awg-openwrt.git' >>"$F"
# his nss feed branch gets rebased: build it from our mirror
sed -i "s#^src-git nss https://github.com/kuncy7/nss-packages.git;ipq50xx-rebase\$#src-git nss $NSS_MIRROR;ipq50xx-rebase#" "$F"
lines "$V2/feeds.lock" | while read -r name rev; do
	anchor 1 "^src-git $name " "$F"
	sed -i -E "s#^(src-git $name [^;^ ]+)(;[^ ^]+)?\$#\1^$rev#" "$F"
done
unpinned=$(grep -E '^src-' "$F" | grep -vE '\^[0-9a-f]{40}$' || true)
[ -z "$unpinned" ] || die "unpinned feeds: $unpinned"
(cd "$TREE" && ./scripts/feeds update -a >"$TREE/feeds-update.log" 2>&1 && ./scripts/feeds install -a >"$TREE/feeds-install.log" 2>&1) ||
	die "feeds update/install failed (see $TREE/feeds-*.log)"
lines "$V2/feeds.lock" | while read -r name rev; do
	[ "$(git -C "$TREE/feeds/$name" rev-parse HEAD)" = "$rev" ] || die "feeds/$name is not at $rev"
done
echo "feeds: $(grep -cE '^src-' "$F") pinned"

# AmneziaWG sources, pinned to commits, as in ../build.sh: the feed names Amnezia's kernel module
# and tools by git tag only, so build them from the commits those tags pointed to, with the hash
# of OpenWrt's source tarball of that commit. Update with ../build.sh and docs/amneziawg.md.
awg_pin() {  # awg_pin <package> <PKG_VERSION> <commit> <source tarball sha256>
	local mk=$TREE/feeds/amneziawg/$1/Makefile
	anchor 1 "^PKG_VERSION:=$2\$" "$mk"
	anchor 1 '^PKG_SOURCE_VERSION:=v\$\(PKG_VERSION\)$' "$mk"	# ERE, unlike ../build.sh
	grep -q '^PKG_MIRROR_HASH:=' "$mk" && die "$mk already sets PKG_MIRROR_HASH; review the pin"
	sed -i "s#^PKG_SOURCE_VERSION:=v\$(PKG_VERSION)\$#PKG_SOURCE_VERSION:=$3\nPKG_MIRROR_HASH:=$4#" "$mk"
	anchor 1 "^PKG_SOURCE_VERSION:=$3\$" "$mk"
	anchor 1 "^PKG_MIRROR_HASH:=$4\$" "$mk"
}
awg_pin kmod-amneziawg  3.1.20260906 4569c4c67f3a57414969260cafbbd04694fbaae0 \
	25a91c7492221291ec8d4ad5672f20c2ed49ec11f0e61478280bf0a37c89b37f
awg_pin amneziawg-tools 3.1.20260812 ee0f0a9aa34ff0a0da4b3433b9512781cfe02843 \
	0c27841a3b4860c7fd085cd627c5b0f9c25653afdaef1e73fd3e350fb3445dab

# 5. package repositories baked into the image, and a release stamp
mkdir -p "$TREE/files/etc/apk/repositories.d"
{
	echo "$REPO_URL"
	for f in base luci packages routing telephony video; do
		echo "https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/$f/packages.adb"
	done
} >"$TREE/files/etc/apk/repositories.d/distfeeds.list"
cat >"$TREE/files/etc/rd03v2-release" <<EOF
RD03V2_TAG='$TAG'
RD03V2_BASE='kuncy7/openwrt-nss-edma $RELEASE $COMMIT'
RD03V2_FEEDS_LOCK='$(sha256sum "$V2/feeds.lock" | cut -c1-16)'
RD03V2_REPO='$REPO_URL'
EOF

# 6. our signing key (package/Makefile only generates one when the file is missing)
install -m 600 "$KEYDIR/private-key.pem" "$TREE/private-key.pem"
install -m 644 "$KEYDIR/public-key.pem" "$TREE/public-key.pem"

# 7. .config: his CI fragments (without his 256m device list) + ours
CI=$TREE/.github/ci/ipq50xx
for f in common 256m kmods-extra; do [ -f "$CI/$f.config" ] || die "his $f.config is missing"; done
{
	cat "$CI/common.config"
	grep -v '^CONFIG_TARGET_DEVICE_' "$CI/256m.config"
	cat "$CI/kmods-extra.config" "$V2/config/rd03v2.config" "$V2/config/kmods.config"
} >"$TREE/.config.v2-wanted"
cp "$TREE/.config.v2-wanted" "$TREE/.config"
echo "CONFIG_CCACHE_DIR=\"$DLDIR/../ccache-v2\"" >>"$TREE/.config"
(cd "$TREE" && make defconfig >"$TREE/defconfig.log" 2>&1) || die "make defconfig failed"
# like his CI: defconfig must not drop anything we asked for
# (later fragments override earlier ones, so only the last setting of each symbol counts)
# (package symbols carry the package name: hyphens, dots and pluses too)
dropped=$(grep -E '^(CONFIG_[A-Za-z0-9_.+-]+=|# CONFIG_[A-Za-z0-9_.+-]+ is not set)' "$TREE/.config.v2-wanted" |
	awk '{ s = ($1 == "#") ? $2 : substr($0, 1, index($0, "=") - 1); last[s] = $0; if (!(s in seen)) { seen[s] = 1; order[++n] = s } }
	     END { for (i = 1; i <= n; i++) print last[order[i]] }' |
	while read -r l; do grep -qxF "$l" "$TREE/.config" || echo "$l"; done)
[ -z "$dropped" ] || die "defconfig dropped: $dropped"
for must in CONFIG_TARGET_DEVICE_qualcommax_ipq50xx_DEVICE_xiaomi_mi-router-ax3000t-v2=y \
	CONFIG_ATH11K_MEM_PROFILE_256M=y CONFIG_NSS_MEM_PROFILE_LOW=y CONFIG_ATH11K_NSS_SUPPORT=y \
	CONFIG_NSS_FIRMWARE_VERSION_12_2=y; do
	grep -qxF "$must" "$TREE/.config" || die ".config lacks $must"
done
[ "$(grep -c '^CONFIG_TARGET_DEVICE_.*=y' "$TREE/.config")" = 1 ] || die "more than one device selected"
(cd "$TREE" && ./scripts/diffconfig.sh >"$TREE/diffconfig.txt")
echo "config: $(wc -l <"$TREE/diffconfig.txt") diffconfig lines"

[ "${PREPARE_ONLY:-0}" = 1 ] && { echo "PREPARE_ONLY: stopping before make"; exit 0; }

# 8. build
rm -rf "$TREE/dl"; mkdir -p "$DLDIR"; ln -s "$DLDIR" "$TREE/dl"
for i in 1 2 3; do (cd "$TREE" && make download -j8 >"$TREE/download.log" 2>&1) && break; done ||
	die "make download failed (see $TREE/download.log)"
start=$(date +%s)
(cd "$TREE" && nice make -j"$JOBS" BUILD_LOG=1 >"$TREE/build.log" 2>&1) || die "make failed (see $TREE/build.log, logs/)"
echo "build: $(( $(date +%s) - start )) s"

# 9. the repository: packages of feeds outside the official ones land outside the target dir
# (his CI copies luci-app-nss the same way); the target dir is what gets indexed and published
T=$TREE/bin/targets/qualcommax/ipq50xx
for p in luci-app-nss amneziawg-tools luci-proto-amneziawg; do
	a=("$T"/packages/"$p"-[0-9]*.apk)
	[ ${#a[@]} = 0 ] || continue		# a target package already
	a=("$TREE"/bin/packages/*/*/"$p"-[0-9]*.apk)
	[ ${#a[@]} = 1 ] || die "expected one $p package, found ${#a[@]}"
	cp -p "${a[0]}" "$T/packages/"
done
(cd "$TREE" && make package/index >"$TREE/index.log" 2>&1) || die "make package/index failed"

# 10. check what we built
"$V2/tools/verify-v2.sh" --tree "$TREE"
