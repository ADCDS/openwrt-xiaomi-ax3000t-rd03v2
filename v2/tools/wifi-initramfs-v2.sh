#!/bin/bash
# Reuse the reversible image pass; v2's early RAM service disables NSS.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
TREE=$(cd "${1:?usage: $0 <finished v2 tree>}" && pwd)
[ -x "$TREE/target/linux/qualcommax/ipq50xx/base-files/etc/init.d/rd03v2-installer" ] || {
	echo 'wifi-initramfs-v2: missing early RAM installer service' >&2; exit 1;
}
export JOBS=${JOBS:-2}
export WIFI_RCL=target/linux/qualcommax/ipq50xx/base-files/etc/rc.local
if [ ! -f "$TREE/$WIFI_RCL" ]; then
	export WIFI_RCL=package/base-files/files/etc/rc.local
fi
export TMPDIR=${TMPDIR:-${RD03V2_WS:-$(dirname "$REPO")}/v2-tmp}
mkdir -p "$TMPDIR"
WS=${RD03V2_WS:-$(dirname "$REPO")}
mkdir -p "$WS/v2-validation"
if [ "${V2_HEAVY_LOCK_HELD:-0}" != 1 ]; then
	exec 9>"$WS/v2-validation/heavy-workload.lock"
	flock -n 9 || { echo 'wifi-initramfs-v2: another heavy workload is active' >&2; exit 1; }
fi
available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
[ "$available" -ge 4194304 ] || { echo 'wifi-initramfs-v2: less than 4 GiB available' >&2; exit 1; }
exec "$REPO/v2/tools/wifi-initramfs.sh" "$TREE"
