#!/bin/bash
# uboot-catch.sh — hands-free U-Boot catch + RAM-boot for the AX3000T RD03v2.
#
# Catches the stock bootloader's 5-second countdown without touching a
# keyboard, persists boot_wait=on, TFTPs the OpenWrt initramfs and boots it.
# Together with `boot_wait=on` this makes the whole flash loop remote:
#   ssh/serial `reboot` -> this script catches U-Boot -> initramfs in RAM ->
#   `sysupgrade -n` -> NAND. No fingers on the reset button.
#
# How the catch works (and why simpler attempts fail):
#  - A CR is streamed to the serial port every 80 ms through ONE fd held open
#    for the whole run. Do NOT open/close the port per write - a USB UART can
#    drop the byte before it is transmitted - and do NOT wait for "Hit any
#    key" before typing: by the time you see it, the 5 s window is half gone.
#  - The countdown only exists at all while boot_wait=on. Stock firmware's
#    first full boot silently turns it OFF again (see README step 2/3); this
#    script re-runs `saveenv` on every catch so the window persists.
#
# Requirements:
#  - Serial adapter on the router's UART (115200 8N1).
#  - A TFTP server on $SERVER_IP serving $IMAGE (dnsmasq line: see README).
#  - Exclusive access to $DEV (stop other readers first: fuser -v $DEV).
#
# Usage:
#   DEV=/dev/ttyUSB0 SERVER_IP=192.168.31.100 CLIENT_IP=192.168.31.147 \
#   IMAGE=fw.itb LOG=./serial.log ./uboot-catch.sh
#   ... then power-cycle (or `reboot`) the router. Timeout: 30 min.
#
# U-Boot TFTP is ~100 KB/s (512-byte stop-and-wait through a polling driver):
# a ~14 MB initramfs takes 2-3 minutes. The hash marks are progress, not a
# stall.

DEV="${DEV:-/dev/ttyUSB0}"
SERVER_IP="${SERVER_IP:-192.168.31.100}"
CLIENT_IP="${CLIENT_IP:-192.168.31.147}"
IMAGE="${IMAGE:-fw.itb}"
LOG="${LOG:-./uboot-catch-serial.log}"
FLAG="$(mktemp -u /tmp/uboot-catch.XXXXXX.stop)"
ts(){ date +%T; }

stty -F "$DEV" 115200 raw -echo -echoe -echok -echoctl -echoke 2>/dev/null || {
	echo "cannot configure $DEV (permissions? adapter present?)" >&2; exit 1; }

cat "$DEV" >> "$LOG" 2>/dev/null &          # capture (held open)
CATPID=$!
exec 3>"$DEV"                               # write fd (held open, never reopened)
( while [ ! -f "$FLAG" ]; do printf '\r' >&3; sleep 0.08; done ) &
CRPID=$!
cleanup(){ touch "$FLAG"; kill "$CRPID" "$CATPID" 2>/dev/null; exec 3>&- 2>/dev/null; }
trap cleanup EXIT

echo "[$(ts)] CR-stream armed on $DEV. Power-cycle / reboot the router now (<=30 min)."
if ! timeout 1800 stdbuf -oL tail -Fn0 "$LOG" | grep -qm1 "IPQ5018#"; then
	echo "[$(ts)] no U-Boot prompt seen. If the countdown never pauses," \
	     "boot_wait is off -> redo the TFTP recovery (README step 2)." >&2
	exit 1
fi
echo "[$(ts)] U-Boot prompt caught."
touch "$FLAG"; sleep 0.6; kill "$CRPID" 2>/dev/null; wait "$CRPID" 2>/dev/null
sleep 1; printf '\r' >&3; sleep 0.5

echo "[$(ts)] persisting boot_wait=on + bootdelay (saveenv)"
printf 'setenv boot_wait on\r'  >&3; sleep 0.8
printf 'setenv bootdelay 5\r'   >&3; sleep 0.8
printf 'setenv uart_en 1\r'     >&3; sleep 0.8
printf 'saveenv\r'              >&3; sleep 2.5

echo "[$(ts)] tftpboot $IMAGE from $SERVER_IP"
printf 'setenv serverip %s\r' "$SERVER_IP" >&3; sleep 0.6
printf 'setenv ipaddr %s\r'   "$CLIENT_IP" >&3; sleep 0.6
printf 'tftpboot 0x44000000 %s\r' "$IMAGE" >&3; sleep 0.6

echo "[$(ts)] waiting for the transfer (~100 KB/s, allow 240 s)..."
if timeout 240 stdbuf -oL tail -Fn0 "$LOG" | grep -qm1 "Bytes transferred"; then
	sleep 1; printf 'bootm 0x44000000\r' >&3
	echo "[$(ts)] bootm sent - OpenWrt initramfs booting. Serial log: $LOG"
else
	echo "[$(ts)] TFTP did not complete (server up? cable? tftp-root?)" >&2
	exit 1
fi

# keep capturing so the boot is observable; Ctrl-C to stop
trap - EXIT; touch "$FLAG" 2>/dev/null; kill "$CRPID" 2>/dev/null
wait "$CATPID"
