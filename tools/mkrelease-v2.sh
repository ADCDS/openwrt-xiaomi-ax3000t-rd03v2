#!/bin/bash
# Assemble a verified release atomically. --local never publishes anything.
set -euo pipefail
LOCAL=0 EXPECT_URL='' OUT=''
while [ $# -gt 0 ]; do
 case "$1" in
 --local) LOCAL=1; shift ;;
 --expect-repo-url) EXPECT_URL=${2:?URL}; shift 2 ;;
 --out) OUT=${2:?directory}; shift 2 ;;
 --*) echo "unknown option: $1" >&2; exit 2 ;;
 *) break ;;
 esac
done
[ $# = 1 ] || { echo "usage: $0 [--local --expect-repo-url URL --out DIR] <tree>" >&2; exit 2; }
TREE=$(cd "$1" && pwd)
REPO=$(cd "$(dirname "$0")/.." && pwd); V2=$REPO
T=$TREE/bin/targets/qualcommax/ipq50xx
P=openwrt-qualcommax-ipq50xx-xiaomi_mi-router-ax3000t-v2
die() { echo "mkrelease-v2: $*" >&2; exit 1; }
"$V2/tools/verify-v2.sh" --tree "$TREE" > "$TREE/verify-release.txt" 2>&1 || die "tree verification failed: $TREE/verify-release.txt"
# scratch on disk, not in a RAM /tmp that other work can fill (as finish-build-v2.sh)
export TMPDIR=${TMPDIR:-${RD03V2_WS:-$(cd "$(dirname "$0")/../.." && pwd)}/v2-tmp}
mkdir -p "$TMPDIR"
X=$(mktemp -d); STAGE=''
cleanup() { rm -rf "$X"; [ -z "$STAGE" ] || rm -rf "$STAGE"; }
trap cleanup EXIT
tar -xOf "$T/$P-squashfs-sysupgrade.bin" --wildcards 'sysupgrade-*/root' > "$X/root.sqfs"
unsquashfs -q -d "$X/r" "$X/root.sqfs" etc/rd03v2-release lib/apk/db/installed >/dev/null 2>&1 || :
[ -f "$X/r/etc/rd03v2-release" ] || die 'image has no release stamp'
# Parse only known stamp fields and quote their values before evaluating.
eval "$(python3 - "$X/r/etc/rd03v2-release" <<'PY'
import shlex,sys
for line in open(sys.argv[1]):
 if line.startswith(('RD03V2_TAG=', 'RD03V2_REPO=')):
  key,value=line.rstrip().split('=',1)
  words=shlex.split(value)
  if len(words)!=1:raise SystemExit('invalid stamp')
  print(key+'='+shlex.quote(words[0]))
PY
)"
TAG=${RD03V2_TAG:?missing tag}
case "$TAG" in *[!A-Za-z0-9._-]*|'') die 'unsafe tag';; esac
if [ "$LOCAL" = 1 ]; then
 [ -n "$EXPECT_URL" ] || die '--local needs --expect-repo-url'
else
 case "$TAG" in DEV-*) die 'development image';; esac
 EXPECT_URL="https://adcds.github.io/openwrt-xiaomi-ax3000t-rd03v2/v2/$TAG/packages.adb"
fi
[ "$RD03V2_REPO" = "$EXPECT_URL" ] || die 'image repository differs from expected URL'
for f in "$P-squashfs-sysupgrade.bin" "$P-initramfs-factory.ubi" "$P-initramfs-uImage.itb" "$P-initramfs-factory-wifi.ubi" "$P-initramfs-uImage-wifi.itb" config.buildinfo feeds.buildinfo version.buildinfo; do
 [ -f "$T/$f" ] || die "missing $f"
done
OUT=${OUT:-$REPO/rel-v2-$TAG}
[ ! -e "$OUT" ] || die "$OUT exists"
mkdir -p "$(dirname "$OUT")"
STAGE=$(mktemp -d "$(dirname "$OUT")/.v2-assets.XXXXXX")
for f in "$P-squashfs-sysupgrade.bin" "$P-initramfs-factory.ubi" "$P-initramfs-uImage.itb" "$P-initramfs-factory-wifi.ubi" "$P-initramfs-uImage-wifi.itb" config.buildinfo feeds.buildinfo version.buildinfo; do cp -p "$T/$f" "$STAGE/"; done
# The buildinfo files name build-host paths: the NSS feed comes from the local mirror, and the
# ccache directory is set. Publish the fork the pinned NSS commit lives in, and no ccache path.
NSS_PUBLIC=$(. "$V2/upstream.lock" && echo "$NSS_URL")
[ -n "$NSS_PUBLIC" ] || die 'no NSS_URL in upstream.lock'
sed -i "s#^src-git nss [^^]*\^#src-git nss $NSS_PUBLIC^#" "$STAGE/feeds.buildinfo"
sed -i '/^CONFIG_CCACHE_DIR=/d' "$STAGE/config.buildinfo"
awk '/^P:/ {n=substr($0,3)} /^V:/ {print n " - " substr($0,3)}' "$X/r/lib/apk/db/installed" | LC_ALL=C sort > "$STAGE/$P.manifest"
"$V2/tools/mknand-support.sh" "$TREE" > "$STAGE/nand-support.txt"
tar -C "$T" -czf "$STAGE/$P-packages-$TAG.tar.gz" --transform "s#^packages#packages-$TAG#" packages
# no build-host path in any text asset (they are published as they are)
for f in config.buildinfo feeds.buildinfo version.buildinfo "$P.manifest" nand-support.txt; do
	! grep -qE '/home/|/root/|/tmp/' "$STAGE/$f" || die "a build-host path is left in $f"
done
(cd "$STAGE" && sha256sum -- * > sha256sums.txt)
"$V2/tools/verify-v2.sh" --release "$STAGE" --apk "$TREE/staging_dir/host/bin/apk" || die 'assembled artifacts failed verification'
mv -T "$STAGE" "$OUT"; STAGE=''
echo "mkrelease-v2: $TAG assembled in $OUT; nothing published"
