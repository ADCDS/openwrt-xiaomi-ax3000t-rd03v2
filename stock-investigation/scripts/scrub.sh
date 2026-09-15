#!/bin/sh
# scrub.sh - copy raw/ captures into captures/ with device identifiers removed.
#
# raw/ is gitignored because it holds the bench unit's serial, MIoT ids, keys,
# MAC addresses and SSIDs.  captures/ is what gets committed.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
raw="$here/../raw"
out="$here/../captures"
mkdir -p "$out"

# Secrets come from the gitignored env file so that none of them are written
# into this script.
envfile="$here/../.bench-env"
# shellcheck disable=SC1090
[ -f "$envfile" ] && . "$envfile"
: "${STOCK_PASS:=__unset_password__}"
: "${BENCH_PSK:=__unset_psk__}"

for f in "$raw"/*.txt "$raw"/*.csv; do
  [ -e "$f" ] || continue
  b=$(basename "$f")
  sed -E \
    -e 's/\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b/xx:xx:xx:xx:xx:xx/g' \
    -e 's/^(SN=|SN = |bdata SN = ).*/\1<redacted-serial>/' \
    -e 's/^(miot_did=|miot_key=|rand_key=|rand_nonce=).*/\1<redacted>/' \
    -e 's/(minet_rd03_[0-9a-z]+|25c829b1922d3123_miwifi|9053f2b0113e0bdcd)/<redacted-ssid>/g' \
    -e 's/^(wl[0-9]+_ssid=).*/\1<redacted-ssid>/' \
    -e 's/\bBRAVO(-IOT)?\b/<redacted-ssid>/g' \
    -e "s/${STOCK_PASS}/<redacted-password>/g" \
    -e "s/${BENCH_PSK}/<redacted-psk>/g" \
    -e 's/^([A-Za-z_]*(passwd|password|psk|key|secret)[A-Za-z_]*[ ]?=[ ]?).*/\1<redacted>/I' \
    "$f" > "$out/$b"
done

# The live device tree carries per-unit local-mac-address properties.
if [ -e "$raw/live.dts" ]; then
  sed -E \
    -e 's/(local-)?mac-address = \[[0-9a-fA-F ]+\]/mac-address = [xx xx xx xx xx xx]/g' \
    "$raw/live.dts" > "$out/live.dts"
fi

echo "scrubbed $(ls -1 "$out" | wc -l) files into captures/"
echo
echo "residual identifier check (should be empty):"
grep -rInE "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}|\[50 92 6a|64595/|2168377895|minet_rd03|${STOCK_PASS}|${BENCH_PSK}" "$out" || echo "  clean"
