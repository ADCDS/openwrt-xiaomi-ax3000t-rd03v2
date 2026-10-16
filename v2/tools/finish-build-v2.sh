#!/bin/bash
# Finish an already prepared, uniquely named v2 tree without discarding it.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd); V2=$REPO/v2
WS=${RD03V2_WS:-$(dirname "$REPO")}
. "$V2/upstream.lock"
TREE=$(cd "${1:?usage: $0 <prepared v2 tree>}" && pwd)
JOBS=${JOBS:-2}
DLDIR=${V2_DL:-$WS/dl-v2}
export TMPDIR=${TMPDIR:-$WS/v2-tmp}
mkdir -p "$TMPDIR"
shopt -s nullglob
die() { echo "finish-build-v2: $*" >&2; exit 1; }
case "$JOBS" in ''|*[!0-9]*|0) die 'JOBS must be a positive number' ;; esac
mkdir -p "$WS/v2-validation"
exec 9>"$WS/v2-validation/heavy-workload.lock"
flock -n 9 || die 'another heavy local workload is active'
available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
[ "$available" -ge "${V2_MIN_MEM_KB:-4194304}" ] || die "less than ${V2_MIN_MEM_KB:-4194304} kB available (V2_MIN_MEM_KB)"
git -C "$TREE" merge-base --is-ancestor "$COMMIT" HEAD || die 'wrong upstream tree'
while read -r name rev; do
 case "$name" in ''|\#*) continue ;; esac
 [ "$(git -C "$TREE/feeds/$name" rev-parse HEAD)" = "$rev" ] || die "feed $name differs from lock"
done < "$V2/feeds.lock"
python3 "$V2/tools/feed-overlay-v2.py" --check "$TREE"
[ -f "$TREE/files/etc/rd03v2-release" ] && [ -f "$TREE/.config.v2-wanted" ] || die 'tree is not prepared'
[ "$(stat -c %a "$TREE/private-key.pem")" = 600 ] || die 'wrong signing-key permissions'
openssl ec -in "$TREE/private-key.pem" -pubout 2>/dev/null | cmp -s - "$V2/keys/public-key.pem" ||
	die 'prepared signing key does not match the committed public key'
for f in $(cd "$V2/overlay" && find . -type f); do
 cmp -s "$V2/overlay/$f" "$TREE/$f" || die "prepared overlay differs: $f"
done
# TAG (and V2_REPO_URL) given: build this tree as another release, stamped the way build.sh
# stamps a new one. Without TAG the tree keeps the stamp it was prepared with.
if [ -n "${TAG:-}" ]; then
	"$V2/tools/stamp-release-v2.sh" "$TREE" "$TAG" \
		"${V2_REPO_URL:-https://adcds.github.io/openwrt-xiaomi-ax3000t-rd03v2/v2/$TAG/packages.adb}"
fi
# 8. build
if [ -L "$TREE/dl" ]; then
	rm "$TREE/dl"
elif [ -e "$TREE/dl" ]; then
	die 'preserving an existing dl directory; use the shared download cache explicitly'
fi
mkdir -p "$DLDIR"; ln -s "$DLDIR" "$TREE/dl"
for i in 1 2 3; do (cd "$TREE" && make download -j"$JOBS" >"$TREE/download.log" 2>&1) && break; done ||
	die "make download failed (see $TREE/download.log)"
# A rebuild leaves an earlier -wifi installer pair in place, and wifi-initramfs.sh refuses to
# run over one, so a release would ship the old pair (an earlier build once did). It is
# remade below from this build.
T=$TREE/bin/targets/qualcommax/ipq50xx
for f in "$T"/*-initramfs-uImage-wifi.itb "$T"/*-initramfs-factory-wifi.ubi; do
	echo "removing the previous build's $(basename "$f")"; rm -f "$f"
done
start=$(date +%s)
(cd "$TREE" && nice make -j"$JOBS" BUILD_LOG=1 >"$TREE/build.log" 2>&1) || die "make failed (see $TREE/build.log, logs/)"
echo "build: $(( $(date +%s) - start )) s"

# 9. the repository: packages of feeds outside the official ones land outside the target dir
# (his CI copies luci-app-nss the same way); the target dir is what gets indexed and published
# The packages 95-rd03v2-apk-pins pins (his changes without a version bump) go in as well, so
# the exact pinned versions stay installable from our repository.
python3 "$V2/tools/copy-repo-packages.py" "$TREE"
(cd "$TREE" && make package/index >"$TREE/index.log" 2>&1) || die "make package/index failed"

# 10. the beaconing -wifi installer pair, from this build (we hold the heavy-workload lock)
V2_HEAVY_LOCK_HELD=1 JOBS=$JOBS "$V2/tools/wifi-initramfs-v2.sh" "$TREE" >"$TREE/wifi-initramfs.log" 2>&1 ||
	die "the -wifi installer pass failed (see $TREE/wifi-initramfs.log)"

# 11. check what we built
"$V2/tools/verify-v2.sh" --tree "$TREE"
