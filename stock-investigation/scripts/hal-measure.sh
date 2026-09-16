#!/bin/bash
# hal-measure.sh <ssid> <bssid> <psk> - run ON hal, as root.
#
# Associates wlp4s0 to one specific BSS, generates a little traffic so the
# running RSSI averages settle, and prints what *hal* hears from that AP.
# The AP side is read separately; the pair gives the link asymmetry.
#
# hal is a fixed reference receiver: same radio, same antenna, same position for
# every measurement, so its own TX power and reporting offset cancel when two
# APs are compared.
set -u
SSID=$1; BSSID=$2; PSK=$3
CONF=/run/hal-measure.conf

for p in $(pgrep -f 'wlp4s0 -c /run/hal-measure'); do kill "$p" 2>/dev/null; done
sleep 1
cat > "$CONF" <<EOF
ctrl_interface=/run/wpa_supplicant
network={
    ssid="$SSID"
    bssid=$BSSID
    psk="$PSK"
    key_mgmt=WPA-PSK
    proto=RSN
}
EOF
chmod 600 "$CONF"
ip addr flush dev wlp4s0 2>/dev/null
ip link set wlp4s0 up
setsid wpa_supplicant -B -i wlp4s0 -c "$CONF" -f /run/hal-measure.log >/dev/null 2>&1
sleep 9

if ! iw dev wlp4s0 link | grep -q Connected; then
  echo "ASSOC FAILED for $SSID/$BSSID"
  tail -5 /run/hal-measure.log 2>/dev/null
  exit 1
fi

# Pin the client TX power. The regulatory ceiling iw reports follows whatever
# the AP advertises (20/23/30 dBm across the four BSSes here), and the
# reciprocity algebra is only valid if the client transmits identically in every
# measurement. 15 dBm is below every ceiling and below the card's hardware
# maximum, so it is actually achieved rather than clamped.
iw dev wlp4s0 set txpower fixed 1500 2>/dev/null || echo "WARN: could not fix txpower"

# Traffic so signal/avg are not a single stale beacon sample.
GW=$(iw dev wlp4s0 link | sed -n 's/.*Connected to \([0-9a-f:]*\).*/\1/p')
timeout 12 ping -c 25 -i 0.2 -I wlp4s0 "${4:-192.168.31.1}" >/dev/null 2>&1
sleep 2

echo "### hal hears AP: ssid=$SSID bssid=$BSSID"
iw dev wlp4s0 link | grep -E 'Connected|freq|signal|tx bitrate|rx bitrate'
echo "hal_txpower: $(iw dev wlp4s0 info | sed -n 's/^[[:space:]]*txpower //p')"
echo "hal_station_view:"
iw dev wlp4s0 station dump | grep -E 'signal:|signal avg|beacon signal|rx bitrate|tx bitrate'
echo "hal_survey_in_use:"
iw dev wlp4s0 survey dump | grep -A3 'in use' | grep -E 'frequency|noise'
