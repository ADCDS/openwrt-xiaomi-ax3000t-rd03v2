#!/bin/sh
# Phase 5 - switch and GMAC (Q4 RX pause).  READ ONLY (devmem reads only).
# Run: ./rsh < phase5.sh > ../raw/phase5-switch.txt
sec() { echo; echo "===== $* ====="; }

sec links
ip -o link 2>/dev/null || ifconfig -a 2>/dev/null

sec ethtool-pause
for i in eth0 eth1; do echo "== $i"; ethtool -a $i 2>&1; done

sec ethtool-info
for i in eth0 eth1; do echo "== $i"; ethtool $i 2>&1; ethtool -i $i 2>&1; done

sec ethtool-stats
for i in eth0 eth1; do echo "== $i"; ethtool -S $i 2>&1; done

sec ssdk
ssdk_sh port flowctrl get 0 2>&1 | head -20
for p in 0 1 2 3 4 5; do echo "-- port $p"; ssdk_sh port flowctrl get $p 2>&1 | head -6; done
ssdk_sh debug phy dump 2>&1 | head -20

sec an8855-module
ls /sys/module/AN8855/parameters/ 2>/dev/null
for p in /sys/module/AN8855/parameters/*; do [ -e "$p" ] && echo "${p##*/} = $(cat $p 2>/dev/null)"; done
ls /sys/module/qca_ssdk/parameters/ 2>/dev/null
for p in /sys/module/qca_ssdk/parameters/*; do [ -e "$p" ] && echo "${p##*/} = $(cat $p 2>/dev/null)"; done

sec dmesg-switch
dmesg | grep -i -E "an8855|hsgmii|sgmii|2500|flow|nss-dp|nss_dp|mdio|phy|link"

sec devmem-mac-flowctrl
# nss-dp GMAC MAC config / flow-control registers.  eth0 @0x39c00000, eth1 @0x39d00000.
# Offsets mirrored from the nss-dp patch in this repo (docs/nss-wifi-validation.md).
for base in 0x39c00000 0x39d00000; do
  echo "== base $base"
  for off in 0x00 0x04 0x08 0x0c 0x10 0x14 0x18 0x1c; do
    a=$(printf '0x%08x' $(( base + off )))
    echo "   $a = $(devmem $a 32 2>/dev/null)"
  done
done

sec devmem-gmac-flow-explicit
# MAC2 (eth1 / switch-facing) flow-control register read-back
devmem 0x39c00018 32 2>/dev/null
devmem 0x39d00018 32 2>/dev/null

sec netdev-features
for i in eth0 eth1; do echo "== $i"; ethtool -k $i 2>&1 | head -30; done

sec interface-uci
uci show network 2>/dev/null | head -60
