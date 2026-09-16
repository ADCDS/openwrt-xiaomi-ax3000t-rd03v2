#!/bin/sh
# Phase 3 - Wi-Fi driver state (Q2 NSS offload, Q7 QCN6102 identity).  READ ONLY.
# Run: ./rsh < phase3.sh > ../raw/phase3-wifi.txt
sec() { echo; echo "===== $* ====="; }

sec ini-tree
ls -la /ini/ 2>/dev/null; ls -la /ini/internal/ 2>/dev/null

sec global.ini
cat /ini/global.ini 2>/dev/null

sec internal-inis
for f in /ini/internal/*; do echo "## $f"; cat "$f"; done 2>/dev/null

sec wifi_nss_olcfg
cat /lib/wifi/wifi_nss_olcfg 2>/dev/null
ls -la /lib/wifi/ 2>/dev/null

sec module-parameters
for m in qca_ol umac wifi_3_0 qca_nss_drv qdf qca_nss_dp mem_manager cfg80211 asf ath_pktlog qca_ssdk; do
  echo "== $m"
  for p in /sys/module/$m/parameters/*; do
    [ -e "$p" ] || continue
    echo "   ${p##*/} = $(cat $p 2>/dev/null)"
  done
done

sec dmesg-wifi
dmesg | grep -i -E "qcn6|6102|6122|5018|chip|soc_id|board_id|bdf|bdwlan|caldata|fw_version|WLAN\.|mem_mode|nss.*wifi|wifili|target_type|hif|ol_ath|cnss|wlan"

sec iw-dev
iw dev 2>/dev/null

sec iw-phy
iw phy 2>/dev/null | head -200

sec ifconfig
ifconfig -a 2>/dev/null | head -80

sec wifi-uci
uci show wireless 2>/dev/null | sed -e 's/\(key\|password\|psk\)=.*/\1=<redacted>/'

sec cfg80211tool-list
cfg80211tool wifi0 2>&1 | head -40
echo "---- wifi1"
cfg80211tool wifi1 2>&1 | head -40

sec cfg80211tool-nss
for r in wifi0 wifi1; do
  for k in get_nss_wifi_offload nss_wifi_olcfg get_fw_recovery get_ol_cfg; do
    echo "$r $k -> $(cfg80211tool $r $k 2>&1 | head -2)"
  done
done

sec wifistats
wifistats wifi0 1 2>&1 | head -60
echo "---- wifi1"
wifistats wifi1 1 2>&1 | head -60

sec apstats
apstats -v 2>&1 | head -120

sec nss-wifili-stats
ls /sys/kernel/debug/qca-nss-drv/stats/ 2>/dev/null
echo "---- wifili"
cat /sys/kernel/debug/qca-nss-drv/stats/wifili 2>/dev/null | head -120

sec cnss-debugfs
ls -R /sys/kernel/debug/cnss 2>/dev/null | head -60
for f in /sys/kernel/debug/cnss/*; do [ -f "$f" ] && { echo "## $f"; cat "$f" 2>/dev/null | head -40; }; done

sec ieee80211-debugfs
ls /sys/kernel/debug/ieee80211/ 2>/dev/null

sec firmware-files
ls -la /lib/firmware/ 2>/dev/null | head -60
ls -la /lib/firmware/qcn6122/ 2>/dev/null
ls -la /lib/firmware/IPQ5018/ 2>/dev/null
ls -la /lib/firmware/qcn6122/*/ 2>/dev/null | head -40

sec remoteproc
for d in /sys/class/remoteproc/*; do
  echo "-- $d name=$(cat $d/name 2>/dev/null) state=$(cat $d/state 2>/dev/null) fw=$(cat $d/firmware 2>/dev/null)"
done
ls /sys/kernel/debug/remoteproc/ 2>/dev/null
