#!/bin/sh
# Reproduce the experimental patch audit on Linux. Does not build or flash.
set -eu
export LC_ALL=C
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -ne 1 ]; then
    echo "Usage: sh tools/check-wifi-nss-port.sh NEW_WORK_DIRECTORY" >&2
    exit 2
fi
for tool in git curl sha256sum tar zstd patch find sort cp; do
    command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 2; }
done
if [ -e "$1" ]; then
    echo "Use a new work directory. Existing paths are never removed." >&2
    exit 2
fi
mkdir -p -- "$1"
work=$(CDPATH= cd -- "$1" && pwd)
openwrt_rev=25ee12629edcc38feffbd06255dd47840cd7af7e
donor_rev=92a2d104145c8d265851c4b388a41bd8e9c21cd9
source_hash=2ad578c6cae22f192fefd44e1449725228d4109ee781998b41dcbae872554968

fetch_tree() {
    destination=$1
    url=$2
    revision=$3
    git init -q "$destination"
    git -C "$destination" remote add origin "$url"
    git -C "$destination" fetch --depth 1 --filter=blob:none origin "$revision"
    git -C "$destination" sparse-checkout init --cone
    git -C "$destination" sparse-checkout set package/kernel/mac80211
    git -C "$destination" checkout -q --detach FETCH_HEAD
    [ "$(git -C "$destination" rev-parse HEAD)" = "$revision" ]
}
fetch_tree "$work/openwrt" https://github.com/openwrt/openwrt.git "$openwrt_rev"
fetch_tree "$work/donor" https://github.com/qosmio/openwrt-ipq.git "$donor_rev"
archive="$work/backports-6.18.26.tar.zst"
curl --fail --location --retry 3 \
    https://github.com/openwrt/backports/releases/download/backports-v6.18.26/backports-6.18.26.tar.zst \
    --output "$archive"
printf '%s  %s\n' "$source_hash" "$archive" | sha256sum -c -
tar -xf "$archive" -C "$work"
target="$work/backports-6.18.26"
mkdir -p "$work/patches/baseline" "$work/patches/nss"
cp -a "$work/openwrt/package/kernel/mac80211/patches/." "$work/patches/baseline/"
cp -a "$repo/files/package/kernel/mac80211/patches/." "$work/patches/baseline/"
cp -a "$work/donor/package/kernel/mac80211/patches/nss/." "$work/patches/nss/"
cp -a "$repo/experimental/wifi-nss/patch-overrides/." "$work/patches/nss/"

log="$work/patches.log"
manifest="$work/applied.tsv"
printf 'stage\tpatch\tsha256\n' > "$manifest"
apply_group() {
    stage=$1
    group=$2
    directory="$work/patches/$stage/$group"
    [ -d "$directory" ] || return 0
    find "$directory" -maxdepth 1 -type f -name '*.patch' | sort > "$work/series.txt"
    while IFS= read -r file; do
        name=${file##*/}
        printf '[%s/%s/%s]\n' "$stage" "$group" "$name" >> "$log"
        if ! patch --dry-run -f -p1 -d "$target" -i "$file" >> "$log" 2>&1; then
            printf 'PATCH CONFLICT: %s/%s/%s\nSee %s\n' "$stage" "$group" "$name" "$log" >&2
            exit 1
        fi
        patch -f -p1 -d "$target" -i "$file" >> "$log" 2>&1
        hash=$(sha256sum "$file")
        hash=${hash%% *}
        printf '%s\t%s/%s\t%s\n' "$stage" "$group" "$name" "$hash" >> "$manifest"
    done < "$work/series.txt"
}
for group in build subsys ath ath5k ath9k ath10k ath11k ath12k rt2x00 mt7601u mwl brcm rtl; do
    apply_group baseline "$group"
done
for group in subsys ath10k ath11k; do
    apply_group nss "$group"
done
printf 'Patch application passed. Source: %s\n' "$target"
printf 'This is NOT a compile, ABI check, firmware image, or hardware validation.\n'
