#!/bin/bash
# test-watchdog.sh: drive the v2 rd03v2-watchdog through its --check mode
# against a fake board, one scenario at a time, and check what it decided.
#
#   v2/tools/test-watchdog.sh [--env host|target|both] [--rootfs DIR] [--keep] [SCENARIO...]
#
# The watchdog runs under BusyBox ash with nothing of the host's but the stubs:
#   host    hal's own busybox (sh and every applet);
#   target  the image's busybox, through qemu-aarch64 (binfmt_misc if it is
#           registered, a wrapper per applet if not) - the exact shell and
#           applets of the router. Slow (every applet is an emulated process).
# Both use the image's own uci and jsonfilter (through qemu), from --rootfs, an
# unpacked rootfs of a kuncy7-based image (default: the gate image's).
#
# The fake board lives in $ROOT/world, one file per fact (see world.sh below);
# the stubs (iw, wifi, ubus, rmmod, modprobe, insmod, dmesg, reboot, sync,
# logger) read and change it and render it as $ROOT/sys again, and record
# every action in $ROOT/calls ("wd ..." for the watchdog's, "user ..." for the
# scenario's own). The watchdog logs to $ROOT/log. A scenario fails on a
# missing or unexpected line in either, and on anything on the watchdog's
# stderr.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WD=$HERE/../overlay/target/linux/qualcommax/ipq50xx/base-files/usr/sbin/rd03v2-watchdog
CONF=$HERE/../overlay/target/linux/qualcommax/ipq50xx/base-files/etc/config/rd03v2-watchdog
RFS=${WD_ROOTFS:-/home/agiu/dev/routers/rd03v2/kuncy-gate/ipq50xx-2026.10.09/inspect/rootfs}
ENVS=both KEEP=0 ONLY=""
while [ $# -gt 0 ]; do
	case $1 in
		--env) ENVS=$2; shift 2 ;;
		--rootfs) RFS=$2; shift 2 ;;
		--keep) KEEP=1; shift ;;
		-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
		*) ONLY="$ONLY $1"; shift ;;
	esac
done
die() { echo "test-watchdog: $*" >&2; exit 2; }
[ -f "$WD" ] || die "no watchdog at $WD"
for f in bin/busybox sbin/uci usr/bin/jsonfilter lib/ld-musl-aarch64.so.1; do
	[ -e "$RFS/$f" ] || die "$RFS is not an unpacked image rootfs (no $f); pass --rootfs"
done
command -v qemu-aarch64 >/dev/null || die "qemu-aarch64 is needed to run the image's uci, jsonfilter and busybox"
# Exec the image's binaries straight through binfmt_misc when qemu-aarch64 is
# registered there (it then finds the loader through QEMU_LD_PREFIX), else
# through qemu-aarch64 -L.
if grep -qs '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64; then RUNT=""; else RUNT="qemu-aarch64 -L $RFS"; fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-watchdog.XXXXXX")
[ "$KEEP" = 1 ] || trap 'rm -rf "$WORK"' EXIT
STUBS=$WORK/stubs
mkdir -p "$STUBS"

# --- the fake board -----------------------------------------------------------
cat > "$STUBS/world.sh" <<'EOF'
# world.sh: the fake board (sourced by the stubs, the tick and the harness).
# $ROOT/world holds its state, one file per fact:
#   q6            q6wcss state: running, offline, crashed
#   core, drv     ath11k, ath11k_ahb: loaded or unloaded
#   offload       ath11k's nss_offload parameter; probe_offload: as last probed
#   phybase       number of the first phy (shifts by 2 on every probe)
#   nss_started   the NSS firmware plane is armed
#   autostart_<radio>    false after `wifi down`
#   disabled_<radio>, setupfail_<radio>, unconf_<radio>, mesh_<radio>, lan_down
#   nophy_<dev>   the phy is gone; noif_<dev>: the interfaces are gone
#   frozen_<dev>  survey active time stuck; sta_<dev>: station count;
#   rxmove_<dev>  their rx packets keep rising
#   heal_reset, heal_reload: an ath11k reset / driver reload cures the faults
#   dmesg         the kernel log
PATH=/usr/bin:/bin
W=$ROOT/world; S=$ROOT/sys
RADIOS="c000000.wifi b00a040.wifi"
wg() { cat "$W/$1" 2>/dev/null; }
ws() { echo "$2" > "$W/$1"; }
wis() { [ -e "$W/$1" ]; }
rec() { echo "[$(cut -d. -f1 "$ROOT/proc/uptime")] ${WHO:-wd} $*" >> "$ROOT/calls"; }
radio_of() { case $1 in c000000.wifi) echo radio0 ;; b00a040.wifi) echo radio1 ;; esac; }
dev_of() { case $1 in radio0) echo c000000.wifi ;; radio1) echo b00a040.wifi ;; esac; }
idx_of() { case $1 in c000000.wifi) echo 0 ;; b00a040.wifi) echo 1 ;; esac; }
phy_of() { echo "phy$(( $(wg phybase) + $(idx_of "$1") ))"; }
ifc_dev() { basename "$(readlink -f "$S/class/net/$1/phy80211/device")"; }

# Is radio section $1 up in netifd, with its interfaces?
radio_up() {
	ru_d=$(dev_of "$1")
	[ "$(wg drv)" = loaded ] || return 1
	for ru_f in "nophy_$ru_d" "noif_$ru_d" "unconf_$1" "disabled_$1" "setupfail_$1" lan_down; do
		wis "$ru_f" && return 1
	done
	[ "$(wg "autostart_$1")" != false ]
}

# Take in what the watchdog wrote: ath11k's nss_offload parameter (when it
# differs from what was rendered) and debugfs resets. True when it took any.
world_take() {
	wt=1
	f=$S/module/ath11k/parameters/nss_offload
	if [ -f "$f" ] && [ "$(cat "$f")" != "$(wg offload_r)" ]; then
		ws offload "$(cat "$f")"; wt=0
	fi
	for d in $RADIOS; do
		f=$S/kernel/debug/ath11k/ahb-$d/simulate_fw_crash
		[ -s "$f" ] || continue
		v=$(cat "$f"); : > "$f"; wt=0
		rec "debugfs $v $d"
		if [ "$v" = hw-restart ] && wis heal_reset; then
			rm -f "$W/frozen_$d" "$W/nophy_$d" "$W/noif_$d"
			echo "[ 999.000000] ath11k $d: pdev $(idx_of "$d") successfully recovered" >> "$W/dmesg"
		fi
	done
	return $wt
}
world_sync() { world_take; world_render; }   # after changing the board
world_poll() { world_take && world_render; } # before reading it

# The board as sysfs/debugfs.
world_render() {
	rm -rf "$S"
	mkdir -p "$S/class/net" "$S/class/ieee80211" "$S/class/remoteproc/remoteproc0" \
		"$S/devices/platform/soc" "$S/kernel/debug/qca-dwmac-nss"
	echo q6wcss > "$S/class/remoteproc/remoteproc0/name"
	wg q6 > "$S/class/remoteproc/remoteproc0/state"
	wis nss_started && echo "phys_if 1: started dev=eth0 fw_link=up" > "$S/kernel/debug/qca-dwmac-nss/status"
	if [ "$(wg core)" = loaded ]; then
		mkdir -p "$S/module/ath11k/parameters" "$S/module/ath11k/holders"
		wg offload > "$S/module/ath11k/parameters/nss_offload"
		ws offload_r "$(wg offload)"
	fi
	[ "$(wg drv)" = loaded ] || return 0
	mkdir -p "$S/module/ath11k_ahb"
	: > "$S/module/ath11k/holders/ath11k_ahb"
	for d in $RADIOS; do
		mkdir -p "$S/devices/platform/soc/$d" "$S/kernel/debug/ath11k/ahb-$d"
		: > "$S/kernel/debug/ath11k/ahb-$d/simulate_fw_crash"
		wis "nophy_$d" && continue
		p=$(phy_of "$d")
		mkdir -p "$S/class/ieee80211/$p"
		ln -s "$S/devices/platform/soc/$d" "$S/class/ieee80211/$p/device"
		r=$(radio_of "$d")
		radio_up "$r" || continue
		for i in ap0 $(wis "mesh_$r" && echo mesh0); do
			mkdir -p "$S/class/net/$p-$i"
			ln -s "$S/class/ieee80211/$p" "$S/class/net/$p-$i/phy80211"
		done
	done
}

# ubus call network.wireless status
wireless_status() {
	printf '{'
	sep=""
	for r in radio0 radio1; do
		wis "unconf_$r" && continue
		d=$(dev_of "$r"); p=$(phy_of "$d")
		up=false; radio_up "$r" && up=true
		as=true; [ "$(wg "autostart_$r")" = false ] && as=false
		dis=false; wis "disabled_$r" && dis=true
		rsf=false; wis "setupfail_$r" && rsf=true
		ifn=""; [ $up = true ] && ifn=",\"ifname\":\"$p-ap0\""
		ifs="{\"section\":\"default_$r\"$ifn,\"config\":{\"mode\":\"ap\",\"encryption\":\"psk2\",\"network\":[\"lan\"]}}"
		if wis "mesh_$r"; then
			ifn=""; [ $up = true ] && ifn=",\"ifname\":\"$p-mesh0\""
			ifs="$ifs,{\"section\":\"mesh_$r\"$ifn,\"config\":{\"mode\":\"mesh\",\"encryption\":\"sae\",\"network\":[\"lan\"]}}"
		fi
		printf '%s"%s":{"up":%s,"pending":false,"autostart":%s,"disabled":%s,"retry_setup_failed":%s,"config":{"path":"platform/soc@0/%s"},"interfaces":[%s]}' \
			"$sep" "$r" $up $as $dis $rsf "$d" "$ifs"
		sep=","
	done
	printf '}\n'
}
EOF

stub() { { echo '#!/bin/sh'; echo ". \"$STUBS/world.sh\""; cat; } > "$STUBS/$1"; chmod +x "$STUBS/$1"; }

stub iw <<'EOF'
world_poll
[ "$1" = dev ] && [ -e "$S/class/net/$2" ] || exit 1
ifc=$2; d=$(ifc_dev "$ifc"); shift 2
case "$*" in
"survey dump")
	# per radio, moving with time (ms of uptime) until frozen
	if wis "frozen_$d"; then
		a=$(wg "act_$d"); a=${a:-100000}
	else
		a=$(( $(cut -d. -f1 "$ROOT/proc/uptime") * 1000 )); ws "act_$d" "$a"
	fi
	f=2412; [ "$d" = b00a040.wifi ] && f=5180
	printf 'Survey data from %s\n\tfrequency:\t\t\t%s MHz [in use]\n\tnoise:\t\t\t\t-95 dBm\n\tchannel active time:\t\t%s ms\n\tchannel busy time:\t\t12 ms\n' "$ifc" "$f" "$a"
	printf 'Survey data from %s\n\tfrequency:\t\t\t%s MHz\n\tchannel active time:\t\t50 ms\n' "$ifc" $((f + 20)) ;;
"station dump")
	n=$(wg "sta_$d"); n=${n:-0}
	if wis "rxmove_$d"; then
		x=$(( $(cut -d. -f1 "$ROOT/proc/uptime") * 7 )); ws "rx_$d" "$x"
	else
		x=$(wg "rx_$d"); x=${x:-100}
	fi
	i=0
	while [ $i -lt "$n" ]; do
		printf 'Station 02:00:00:00:00:%02x (on %s)\n\trx packets:\t%s\n\ttx packets:\t5\n' $i "$ifc" "$x"
		i=$((i + 1))
	done ;;
info) printf 'Interface %s\n\tchannel 1 (2412 MHz), width: 20 MHz\n' "$ifc" ;;
*) exit 1 ;;
esac
EOF

stub wifi <<'EOF'
world_sync
rec "wifi $*"
case "${1:-up}" in
down) v=false ;;
up) v=true ;;
*) exit 1 ;;
esac
for r in ${2:-radio0 radio1}; do ws "autostart_$r" $v; done
world_sync
EOF

stub ubus <<'EOF'
world_poll
[ "$1" = call ] || exit 1
case "$2" in
network.wireless) [ "$3" = status ] && wireless_status ;;
network.interface)
	u=true; wis lan_down && u=false
	printf '{"interface":[{"interface":"lan","up":%s,"autostart":%s},{"interface":"wan","up":true,"autostart":true}]}\n' $u $u ;;
wpa_supplicant.*) rec "ubus reload ${2#wpa_supplicant.}"; wis supp_fail && exit 1; exit 0 ;;
*) exit 1 ;;
esac
EOF

stub modprobe <<'EOF'
world_sync
rec "modprobe $*"
case "$1" in
ath11k)
	[ "$(wg core)" = loaded ] || { ws core loaded; ws offload 0; } ;;  # nss_offload defaults to 0
ath11k_ahb)
	[ "$(wg core)" = loaded ] || exit 1
	[ "$(wg drv)" = loaded ] && exit 0
	ws drv loaded; ws probe_offload "$(wg offload)"; ws phybase $(( $(wg phybase) + 2 ))
	if [ "$(wg q6)" = crashed ]; then
		# a kept power reference: rproc_boot() starts nothing, the probe times out
		touch "$W/nophy_c000000.wifi" "$W/nophy_b00a040.wifi"
	else
		ws q6 running
		wis heal_reload && rm -f "$W"/frozen_* "$W"/nophy_* "$W"/noif_*
	fi ;;
*) exit 1 ;;  # ath11k_pci: not on this board
esac
world_sync
EOF

stub rmmod <<'EOF'
world_sync
rec "rmmod $*"
case "$1" in
ath11k_ahb)
	[ "$(wg drv)" = loaded ] || exit 1
	ws drv unloaded
	# rproc_shutdown() only from "running"
	[ "$(wg q6)" = running ] && ws q6 offline ;;
ath11k)
	[ "$(wg core)" = loaded ] || exit 1
	[ "$(wg drv)" = loaded ] && exit 1
	wis rmmod_fail && exit 1
	ws core unloaded ;;
*) exit 1 ;;
esac
world_sync
EOF

stub insmod <<'EOF'
rec "insmod $*"; exit 1
EOF
stub reboot <<'EOF'
rec "reboot $*"
EOF
stub dmesg <<'EOF'
cat "$W/dmesg"
EOF
stub logger <<'EOF'
rec "logger $*"
EOF
stub sync <<'EOF'
:
EOF
stub uci <<EOF
exec $RUNT "$RFS/sbin/uci" -c "\$ROOT/etc/config" "\$@"
EOF
stub jsonfilter <<EOF
exec $RUNT "$RFS/usr/bin/jsonfilter" "\$@"
EOF
stub tick <<'EOF'
world_poll
EOF

# --- toolboxes ----------------------------------------------------------------
mk_toolbox() {  # mk_toolbox ENV: sets TB, SHELL_DESC
	TB=$WORK/tb-$1
	mkdir -p "$TB"
	case $1 in
	host)
		bb=$(command -v busybox) || die "no busybox on this host"
		for a in $("$bb" --list); do ln -sf "$bb" "$TB/$a"; done
		SHELL_DESC="host: $("$bb" | head -1)" ;;
	target)
		for a in $(find "$RFS" -lname '*busybox' -printf '%f\n' | sort -u); do
			if [ -z "$RUNT" ]; then
				ln -sf "$RFS/bin/busybox" "$TB/$a"
			else
				printf '#!/bin/sh\nexec %s "%s/bin/busybox" %s "$@"\n' "$RUNT" "$RFS" "$a" > "$TB/$a"
				chmod +x "$TB/$a"
			fi
		done
		SHELL_DESC="target: $(strings "$RFS/bin/busybox" | grep -m1 '^BusyBox v') via qemu-aarch64${RUNT:+ (no binfmt)}" ;;
	esac
	# Only the watchdog's own commands come from here; the stubs shadow the rest.
	for s in "$STUBS"/*; do rm -f "$TB/$(basename "$s")"; done
}

# --- scenario plumbing ----------------------------------------------------------
w() { if [ $# -ge 2 ]; then echo "$2" > "$ROOT/world/$1"; else touch "$ROOT/world/$1"; fi; }
unw() { rm -f "$ROOT/world/$1"; }
board() { (export ROOT; . "$STUBS/world.sh"; world_sync); }
up() { echo "$1.00 0.00" > "$ROOT/proc/uptime"; }
uptime_now() { cut -d. -f1 "$ROOT/proc/uptime"; }
user() { env ROOT="$ROOT" WHO=user QEMU_LD_PREFIX="$RFS" "$STUBS/$@" > /dev/null; }

wdconf() {  # wdconf DRYRUN [INPLACE] [RELOAD] [ENABLED]
	{
		echo "config watchdog 'main'"
		echo "	option enabled '${4:-1}'"
		echo "	option dryrun '$1'"
		[ -n "${2:-}" ] && echo "	option inplace '$2'"
		echo "	option reload '${3:-1}'"
	} > "$ROOT/etc/config/rd03v2-watchdog"
}

new_world() {
	ROOT=$WORK/$CUR_ENV/$1
	rm -rf "$ROOT"
	mkdir -p "$ROOT/world" "$ROOT/proc" "$ROOT/etc/config" "$ROOT/overlay" "$ROOT/tmp"
	cp "$CONF" "$ROOT/etc/config/rd03v2-watchdog"
	cat > "$ROOT/etc/config/wireless" <<-EOF
	config wifi-device 'radio0'
		option type 'mac80211'
		option path 'platform/soc@0/c000000.wifi'
		option band '2g'

	config wifi-device 'radio1'
		option type 'mac80211'
		option path 'platform/soc@0/b00a040.wifi'
		option band '5g'

	config wifi-iface 'default_radio0'
		option device 'radio0'
		option mode 'ap'
		option network 'lan'

	config wifi-iface 'default_radio1'
		option device 'radio1'
		option mode 'ap'
		option network 'lan'
	EOF
	printf "config nss 'general'\n\toption enabled '1'\n\toption wifi_offload '1'\n" > "$ROOT/etc/config/nss"
	up 30
	printf ' 33:          1          0     GIC-0 290 Edge      q6v5 fatal\n' > "$ROOT/proc/interrupts"
	printf 'MemFree:           28576 kB\nMemAvailable:      24060 kB\n' > "$ROOT/proc/meminfo"
	w q6 running; w core loaded; w drv loaded; w offload 1; w phybase 0; w nss_started
	: > "$ROOT/world/dmesg"; : > "$ROOT/log"; : > "$ROOT/calls"
	cp "$STUBS/tick" "$ROOT/tick"
	board
	NSTEP=0
}

# step: one --check run (arms on the first of a boot, else one sample).
step() {
	NSTEP=$((NSTEP + 1))
	env -i PATH="$STUBS:$TB" ROOT="$ROOT" QEMU_LD_PREFIX="$RFS" HOME=/ \
		"$TB/sh" "$WD" --check > "$ROOT/out.$NSTEP" 2>&1
	if [ -s "$ROOT/out.$NSTEP" ]; then
		FAILS="$FAILS
    stderr/stdout at step $NSTEP: $(head -3 "$ROOT/out.$NSTEP" | tr '\n' '|')"
	fi
}
steps() { for _ in $(seq "$1"); do step; done; }
# until_log REGEX MAX: step until the log matches (at most MAX steps).
until_log() {
	_n=0
	while ! grep -qE -- "$1" "$ROOT/log" && [ $_n -lt "$2" ]; do step; _n=$((_n + 1)); done
}
count() { grep -cE -- "$2" "$ROOT/$1" 2>/dev/null; }
expect() {  # expect log|calls|FILE REGEX
	grep -qE -- "$2" "$ROOT/$1" 2>/dev/null || FAILS="$FAILS
    $1 lacks /$2/"
}
refute() {
	grep -qE -- "$2" "$ROOT/$1" 2>/dev/null && FAILS="$FAILS
    $1 has /$2/: $(grep -m1 -E -- "$2" "$ROOT/$1")"
}
evidence() { cat "$ROOT"/overlay/rd03v2-watchdog/incident-* 2>/dev/null; }
expect_world() {  # expect_world FACT VALUE
	[ "$(cat "$ROOT/world/$1" 2>/dev/null)" = "$2" ] || FAILS="$FAILS
    world/$1 is '$(cat "$ROOT/world/$1" 2>/dev/null)', expected '$2'"
}

# --- scenarios ------------------------------------------------------------------
# Each arms (step), moves past the 10 min no-action window where it needs to,
# breaks something and checks the decision.

sc_healthy() {  # nothing wrong: no incident, no action
	new_world healthy; wdconf 0; step
	expect log 'armed \(interval=30s.*radios: b00a040.wifi c000000.wifi , nss_offload=1, dryrun=0'
	up 700; steps 8
	refute log 'detected'
	refute calls 'wd '
}

sc_q6_crashed() {  # Q6 crashed: a reload cannot boot it (kept power reference), so reboot
	new_world q6-crashed; wdconf 0; step; up 700; step
	w q6 crashed; board
	steps 2
	expect log 'detected: remoteproc not running: q6wcss=crashed'
	expect log 'ath11k reset off \(inplace=auto, nss_offload=1\)'
	expect calls 'wd wifi down'
	expect calls 'wd rmmod ath11k_ahb'
	expect calls 'wd rmmod ath11k$'
	expect log 'q6wcss is crashed after unloading ath11k; a reload cannot boot it'
	refute calls 'wd modprobe'
	expect calls 'wd reboot $'
	expect log 'REBOOTING: remoteproc not running: q6wcss=crashed \(Q6 not offline after unloading ath11k\), no radio serving \(1/3\)'
	evidence > "$ROOT/evid"
	expect evid 'remoteproc0 q6wcss crashed'
	expect evid 'rebooting: '
}

sc_user_rmmod() {  # ath11k unloaded by hand: reloaded as nss-dwmac-up loads it, offload restored
	new_world user-rmmod; wdconf 0; step; up 700; step
	user rmmod ath11k_ahb; user rmmod ath11k
	expect_world q6 offline
	steps 2
	expect log 'detected: remoteproc not running: q6wcss=offline'
	expect log 'reloading ath11k \(nss_offload=1\)'
	refute calls 'wd rmmod'
	expect calls 'wd modprobe ath11k$'
	expect calls 'wd modprobe ath11k_ahb'
	expect calls 'wd modprobe ath11k_pci'
	expect calls 'wd wifi up$'
	expect_world probe_offload 1
	expect log 'RECOVERED in place via driver reload: remoteproc not running'
	refute calls 'wd (insmod|reboot)'
}

sc_phy_missing() {  # a radio's phy gone: driver reload (offload on: no ath11k reset)
	new_world phy-missing; wdconf 0; step; up 700; step
	w nophy_b00a040.wifi; w heal_reload; board
	steps 2
	expect log 'detected: radio missing: b00a040.wifi\(no phy\)'
	refute calls 'debugfs'
	expect calls 'wd rmmod ath11k_ahb'
	expect log 'RECOVERED in place via driver reload'
	expect_world phybase 2
	refute calls 'wd reboot'
}

sc_iface_lost() {  # interfaces gone while netifd wants them up: driver reload
	new_world iface-lost; wdconf 0; step; up 700; step
	w noif_c000000.wifi; w heal_reload; board
	steps 3
	refute log 'detected'
	step
	expect log 'detected: radio missing: c000000.wifi\(no interface\)'
	expect log 'RECOVERED in place via driver reload'
}

sc_wifi_down() {  # `wifi down` by the user: not an incident
	new_world wifi-down; wdconf 0; step; up 700; step
	user wifi down
	steps 6
	refute log 'detected'
	expect log 'c000000.wifi was taken down on purpose'
	expect log 'b00a040.wifi was taken down on purpose'
	refute calls 'wd '
}

sc_radio_disabled() {  # radio disabled in /etc/config/wireless: not an incident
	new_world radio-disabled; wdconf 0; step; up 700; step
	w disabled_radio1; board
	steps 6
	refute log 'detected'
	expect log 'b00a040.wifi was taken down on purpose'
	refute calls 'wd '
}

sc_stopped_radio_kept_down() {  # wifi down radio0, then radio1 freezes: the reload leaves radio0 down
	new_world stopped-radio; wdconf 0; step; up 700; step
	user wifi down radio0
	steps 2
	expect log 'c000000.wifi was taken down on purpose'
	w frozen_b00a040.wifi; w heal_reload
	until_log 'detected' 6
	expect log 'detected: survey freeze: phy1-ap0\(active=[0-9]+\)'
	expect log 'leaving radio0 down after the reload'
	expect calls 'wd wifi up radio1'
	refute calls 'wd wifi up radio0'
	refute calls 'wd wifi up$'
	expect log 'RECOVERED in place via driver reload'
	expect_world autostart_radio0 false
}

sc_freeze() {  # survey frozen, no stations: driver reload with offload on
	new_world freeze; wdconf 0; step; up 700; step
	w frozen_c000000.wifi; w heal_reload
	steps 3
	refute log 'detected'
	step
	expect log 'detected: survey freeze: phy0-ap0\(active=[0-9]+\)'
	refute calls 'debugfs'
	expect log 'RECOVERED in place via driver reload: survey freeze'
}

sc_freeze_rx() {  # survey frozen but stations passing frames: no incident
	new_world freeze-rx; wdconf 0; step; up 700; step
	w frozen_b00a040.wifi; w sta_b00a040.wifi 2; w rxmove_b00a040.wifi
	steps 6
	refute log 'detected'
	expect log "phy1-ap0: survey active time stuck at [0-9]+, but b00a040.wifi's stations are passing frames"
	[ "$(count log 'stations are passing frames')" = 1 ] || FAILS="$FAILS
    the passing-frames note was logged more than once"
}

sc_offload_off_reset() {  # no offload: ath11k reset of the radio, then the encrypted mesh re-joined
	new_world offload-off; wdconf 0
	w offload 0; w mesh_radio1; unw nss_started
	printf "config nss 'general'\n\toption enabled '1'\n\toption wifi_offload '0'\n" > "$ROOT/etc/config/nss"
	board; step; up 700; step
	expect log 'armed .*nss_offload=0'
	w frozen_b00a040.wifi; w heal_reset
	until_log 'detected' 6
	expect log 'detected: survey freeze: phy1-ap0\(active=[0-9]+\) phy1-mesh0\(active=[0-9]+\)'
	expect log 'in-place: ath11k reset of b00a040.wifi'
	expect calls 'wd debugfs hw-restart b00a040.wifi'
	refute calls 'debugfs hw-restart c000000.wifi'
	expect log 'RECOVERED in place via ath11k reset'
	refute calls 'wd (rmmod|modprobe|reboot)'
	step
	expect calls 'wd ubus reload phy1-mesh0'
	refute calls 'ubus reload phy1-ap0'
	expect log 'b00a040.wifi restarted in place: joined the encrypted mesh on phy1-mesh0 again'
}

sc_inplace_forced() {  # uci inplace 1 with offload on: the ath11k reset is tried first
	new_world inplace-forced; wdconf 0 1; step; up 700; step
	w frozen_c000000.wifi; w heal_reset
	until_log 'detected' 6
	expect calls 'wd debugfs hw-restart c000000.wifi'
	expect log 'RECOVERED in place via ath11k reset'
	refute calls 'wd rmmod'
}

sc_reload_off() {  # uci reload 0: straight from detection (offload on) to a reboot
	new_world reload-off; wdconf 0 "" 0; step; up 700; step
	w frozen_c000000.wifi
	until_log 'detected' 6
	refute calls 'wd (rmmod|modprobe|debugfs)'
	expect log 'REBOOTING: survey freeze:.*\(driver reload off\) \(evidence'
	expect calls 'wd reboot $'
}

sc_rate_limit() {  # 3 incidents handled in place per hour of uptime; the 4th reboots
	new_world rate-limit; wdconf 0 1; step; up 700; step
	w heal_reset
	for i in 1 2 3 4; do
		w frozen_b00a040.wifi
		_n=0
		while [ "$(count log 'detected:')" -lt $i ] && [ $_n -lt 10 ]; do step; _n=$((_n + 1)); done
		[ "$(count log 'detected:')" = $i ] || { FAILS="$FAILS
    incident $i not detected"; break; }
	done
	[ "$(count log 'RECOVERED in place via ath11k reset')" = 3 ] || FAILS="$FAILS
    expected 3 recoveries in place"
	expect log 'in-place recovery used 3 times in the last 3600s of uptime; rebooting instead'
	expect log 'REBOOTING: survey freeze:.*\(in-place budget exhausted\)'
	[ "$(count calls 'wd debugfs hw-restart')" = 3 ] || FAILS="$FAILS
    expected 3 ath11k resets, saw $(count calls 'wd debugfs hw-restart')"
	expect calls 'wd reboot $'
	[ "$(uptime_now)" -lt 3600 ] || FAILS="$FAILS
    the 4 incidents took $(uptime_now)s of uptime, more than the window"
}

sc_min_uptime() {  # incident in the first 10 min: evidence and log only
	new_world min-uptime; wdconf 0; step
	w frozen_c000000.wifi
	until_log 'detected' 6
	expect log 'uptime <600s, not intervening yet'
	refute calls 'wd '
	[ "$(ls "$ROOT"/overlay/rd03v2-watchdog/incident-* 2>/dev/null | wc -l)" = 1 ] || FAILS="$FAILS
    no evidence file"
}

sc_hold_after_watchdog_boot() {  # after a watchdog reboot, one radio serving: reboot held until 1 h
	new_world hold; wdconf 0
	mkdir -p "$ROOT/overlay/rd03v2-watchdog"; echo "earlier incident" > "$ROOT/overlay/rd03v2-watchdog/rebooted"
	step; up 900
	[ -f "$ROOT/tmp/rd03v2-watchdog/watchdog-boot" ] || FAILS="$FAILS
    the rebooted marker was not taken as a watchdog boot"
	w frozen_c000000.wifi
	until_log 'detected' 6
	expect calls 'wd modprobe ath11k_ahb'
	expect log 'would reboot \(survey freeze:.*\(in-place recovery failed\)\) but this boot follows a watchdog reboot and is under 3600s of uptime; holding'
	refute calls 'wd reboot'
	steps 2
	refute calls 'wd reboot'
	up 3700; step
	expect calls 'wd reboot $'
	expect log 'REBOOTING: survey freeze'
}

sc_dead_reboot() {  # after a watchdog reboot, no radio serving: the 10 min suffice (1/3)
	new_world dead; wdconf 0
	mkdir -p "$ROOT/overlay/rd03v2-watchdog"; echo x > "$ROOT/overlay/rd03v2-watchdog/rebooted"
	step; up 700; step
	w q6 crashed; board
	steps 2
	expect log 'REBOOTING: .*no radio serving \(1/3\)'
	expect calls 'wd reboot $'
	[ "$(cat "$ROOT/overlay/rd03v2-watchdog/dead-reboots" 2>/dev/null)" = 1 ] || FAILS="$FAILS
    dead-reboots is not 1"
}

sc_dead_reboot_cap() {  # ...but not a 4th time in a row: held, and ath11k put back meanwhile
	new_world dead-cap; wdconf 0
	mkdir -p "$ROOT/overlay/rd03v2-watchdog"; echo x > "$ROOT/overlay/rd03v2-watchdog/rebooted"
	echo 3 > "$ROOT/overlay/rd03v2-watchdog/dead-reboots"
	step; up 700; step
	w q6 crashed; board
	steps 2
	expect log 'but 3 no-radio reboots in a row already, and this boot is under 3600s of uptime; holding'
	refute calls 'wd reboot'
	expect calls 'wd modprobe ath11k_ahb'
}

sc_dryrun_default() {  # the shipped config (dry run): evidence and a plan, nothing done
	new_world dryrun; step; up 700; step
	expect log 'armed .*dryrun=1, inplace=auto, reload=1'
	w frozen_c000000.wifi
	until_log 'detected' 6
	expect log 'DRY-RUN: would try, until the radios are healthy: ath11k reload \(nss_offload=1\) -> reboot$'
	refute calls 'wd '
	evidence > "$ROOT/evid"
	expect evid 'dry run, nothing done; would try: ath11k reload'
	expect evid 'config: dryrun=1 inplace=auto reload=1'
	# the fault stays: reported again, but only after the dry-run pause
	_n=0
	while [ "$(count log 'detected:')" -lt 2 ] && [ $_n -lt 8 ]; do step; _n=$((_n + 1)); done
	t1=$(grep -m1 'detected:' "$ROOT/log" | sed 's/^\[\([0-9]*\)\].*/\1/')
	t2=$(grep 'detected:' "$ROOT/log" | sed -n '2s/^\[\([0-9]*\)\].*/\1/p')
	[ -n "$t2" ] && [ $((t2 - t1)) -ge 900 ] || FAILS="$FAILS
    second dry-run report at ${t2:-never}, first at $t1: not after the 900 s pause"
	refute calls 'wd '
}

sc_dryrun_offload_off() {  # dry run without offload: the plan starts with the ath11k reset
	new_world dryrun-nooffload; w offload 0; board; step; up 700; step
	w frozen_b00a040.wifi
	until_log 'detected' 6
	expect log 'DRY-RUN: would try, until the radios are healthy: ath11k reset of b00a040.wifi -> ath11k reload \(nss_offload=0\) -> reboot$'
	refute calls 'wd '
}

sc_disabled_file() {  # /etc/rd03v2-watchdog.disable: idle
	new_world disabled-file; wdconf 0
	touch "$ROOT/etc/rd03v2-watchdog.disable"
	w q6 crashed; board
	steps 3
	expect log 'disabled by .*/etc/rd03v2-watchdog.disable, idling'
	refute log 'armed|detected'
	refute calls 'wd '
}

sc_disabled_uci() {  # uci enabled 0: idle
	new_world disabled-uci; wdconf 0 "" 1 0
	w q6 crashed; board
	steps 3
	expect log 'disabled \(uci rd03v2-watchdog.main.enabled=0\), idling'
	refute log 'armed|detected'
}

sc_setup_failed() {  # netifd gives up on a working radio: a configuration problem, no action
	new_world setupfail; wdconf 0; step; up 700; step
	w setupfail_radio1; board
	steps 6
	expect log 'b00a040.wifi: netifd gave up setting it up \(retry_setup_failed\) while the radio was working'
	[ "$(count log 'netifd gave up')" = 1 ] || FAILS="$FAILS
    the retry_setup_failed note was logged more than once"
	refute log 'detected'
}

sc_no_wifi() {  # no radio configured, ath11k never loaded, Q6 never up: nothing to watch, no incident
	new_world no-wifi; wdconf 0
	w unconf_radio0; w unconf_radio1; w drv unloaded; w core unloaded; w q6 offline
	printf '' > "$ROOT/etc/config/wireless"
	board; step
	expect log 'no radio registered after boot and none configured; watching q6wcss only'
	up 700; steps 4
	refute log 'detected'
	refute calls 'wd '
}

sc_never_registers() {  # radios configured but ath11k never came up in this boot: reload
	new_world never-registers; wdconf 0
	w drv unloaded; w q6 offline; w heal_reload; board
	step
	expect log 'no radio registered after boot, though netifd has radios configured; treating them as missing'
	up 700; steps 2
	expect log 'detected: radio missing: b00a040.wifi\(no phy\) c000000.wifi\(no phy\)'
	expect calls 'wd modprobe ath11k_ahb'
	expect log 'RECOVERED in place via driver reload'
}

SCENARIOS="healthy q6_crashed user_rmmod phy_missing iface_lost wifi_down radio_disabled
stopped_radio_kept_down freeze freeze_rx offload_off_reset inplace_forced reload_off rate_limit
min_uptime hold_after_watchdog_boot dead_reboot dead_reboot_cap dryrun_default dryrun_offload_off
disabled_file disabled_uci setup_failed no_wifi never_registers"

run_env() {
	CUR_ENV=$1
	mk_toolbox "$1"
	echo "== $SHELL_DESC"
	pass=0 fail=0
	for s in $SCENARIOS; do
		[ -z "$ONLY" ] || case " $ONLY " in *" $s "*) ;; *) continue ;; esac
		FAILS=""
		t0=$(date +%s)
		"sc_$s"
		t=$(( $(date +%s) - t0 ))
		if [ -z "$FAILS" ]; then
			pass=$((pass + 1)); printf '  PASS %-26s %3ss\n' "$s" "$t"
		else
			fail=$((fail + 1)); printf '  FAIL %-26s %3ss%s\n' "$s" "$t" "$FAILS"
			echo "    --- log:"; sed 's/^/      /' "$ROOT/log" | tail -15
			echo "    --- calls:"; sed 's/^/      /' "$ROOT/calls" | tail -10
		fi
	done
	echo "  $pass passed, $fail failed"
	TOTAL_FAIL=$((TOTAL_FAIL + fail))
}

TOTAL_FAIL=0
case $ENVS in
	host|target) run_env "$ENVS" ;;
	both) run_env host; run_env target ;;
	*) die "--env is host, target or both" ;;
esac
[ "$KEEP" = 1 ] && echo "kept: $WORK"
[ "$TOTAL_FAIL" = 0 ]
