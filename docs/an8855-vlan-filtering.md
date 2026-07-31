# Bridge VLAN filtering on the NSS build (tag_8021q)

> TL;DR — `option vlan_filtering '1'` works on the NSS build as of v1.5. Up to
> v1.4 it took the router off the network the moment it was applied, and only a
> reboot brought it back. The cause was a single register field: the
> mt7530-derived `.port_vlan_filtering` forced the **CPU port** to egress
> untagged, so the `tag_8021q` conduit tagger had no VID to decode. Fixed by
> `999-2761`, which follows the mainline sja1105/vsc73xx shadow-PVID model.

## The bug (as shipped up to v1.4)

`an8855_port_vlan_filtering()` was the stock mt7530 implementation with no
`tag_8021q` awareness. Enabling VLAN filtering on **one** user port
reprogrammed that port's *upstream* (CPU) port:

```c
an8855_port_set_vlan_mode(priv, dsa_upstream_port(ds, port),
			  AN8855_PORT_FALLBACK_MODE,
			  AN8855_VLAN_EG_CONSISTENT,   /* ← the fatal field */
			  ...);
```

`EG_CONSISTENT` means "untagged in, untagged out". It overrides the per-VID
egress-tag field that `an8855_vlan_add()` sets for CPU ports, and it is the
exact opposite of what `an8855_setup()` installs (`EG_DISABLED`, i.e. let the
VLAN table decide). The conduit then receives frames with no 802.1Q header at
all, `tag_vsc73xx_8021q.c` has no VID to demux, and **the host RX path dies for
every user port sharing that CPU port** — bridged or not.

TX kept working, which made it confusing to diagnose: the router carried on
transmitting, so its MAC stayed present and freshly-aged in the upstream
router's FDB while the box itself was unreachable. **Do not accept "the MAC is
still in the gateway's FDB" as evidence that the box is alive.**

Recovery required a reboot, not a config revert, because the disable path wrote
`EG_CONSISTENT` too and never restored the `tag_8021q` programming.

### Measured

On an RD03v2 AP (tagger `vsc73xx-8021q`, conduit port 5), enabling
`vlan_filtering` on `br-lan` changed exactly one field on the whole switch:

| | `PVC_P(5)` @ `0x10208a10` | `ping 192.168.1.1` |
|---|---|---|
| before | `0x91000000` — `PVC_EG_TAG` = 0 (`EG_DISABLED`) | 2/2 |
| `vlan_filtering=1` | `0x91000100` — `PVC_EG_TAG` = 1 (`EG_CONSISTENT`) | **0/2** |
| write back `0x91000000` | `0x91000000` | 2/2 |

The last row was applied live with `an8855-diag write` — the host path came
back with no reboot. That is the whole bug.

## The fix (`999-2761-nss-an8855-vlan-filtering.patch`)

Follows the mainline model for a driver that commits the `tag_8021q` VLAN as a
PVID (see the discussion in `net/dsa/tag_8021q.c`):

- **CPU-port `PVC_EG_TAG` is never touched outside `an8855_setup()`.** The CPU
  port stays a tagged member of every bridge VLAN — which `an8855_vlan_add()`
  already arranges — and the VLAN table keeps deciding egress tagging.
- **Shadow PVIDs.** `pvid_tag_8021q[]` and `pvid_bridge[]` in `an8855_priv`,
  plus `an8855_port_commit_vlan()` which programs whichever the port's current
  VLAN-awareness selects — `sja1105_commit_pvid()` /
  `vsc73xx_vlan_commit_pvid()`. `.tag_8021q_vlan_add/_del` and
  `.port_vlan_add/_del` now only update their own shadow and commit, so the two
  writers stop clobbering the single PVID register pair. This is also what
  makes *leaving* a VLAN-aware bridge restore the `tag_8021q` PVID without a
  reboot.
- **VIDs 3072–4095 are rejected** from `.port_vlan_add` with
  `"Range 3072-4095 reserved for dsa_8021q operation"`, as sja1105 and vsc73xx
  do. Previously a bridge VLAN in that range could silently rewrite the entries
  `tag_8021q` uses to identify source ports.
- **Inverted accept-frame test fixed.** The mt7530-derived original read "PVID
  set → accept tagged only", the opposite of its own comment and of
  `mt7530.c`, so a trunk-only port with no PVID got `ACC_ALL` and classified
  untagged ingress into VID 0.

## What you give up: source-port precision

Under a VLAN-aware bridge, frames reach software carrying the **bridge VID**,
not a `tag_8021q` VID, so DSA cannot tell which user port they came from. It
falls back to `dsa_find_designated_bridge_port_by_vid()` and the software
bridge sorts it out. This is not a shortcut in this driver — it is what
`net/dsa/tag_8021q.c` documents for this class of hardware, and the
`vsc73xx-8021q` tagger already expects it (`vsc73xx_xmit()` returns the skb
untouched when `br_vlan_enabled()`). Hardware forwarding between user ports is
unaffected: the switch FDB is keyed `(MAC, bridge VID)` with IVL, so it still
resolves destinations itself.

The base (non-NSS, `DSA_TAG_PROTO_MTK`) build never had this problem — its
special tag carries the source port in a header independent of the VLAN table —
and keeps full precision.

## Example: an isolated IoT VLAN over the backhaul

Dumb AP, VLAN 1 untagged everywhere, VLAN 20 tagged on the backhaul port only.

**Identify the backhaul port first — do not assume.** Tagging the wrong port
silently produces an IoT VLAN that reaches nothing. The port facing the
upstream router is the one its MAC is learned on:

```sh
# upstream router's MAC, as seen from a host on the LAN:  ip neigh show <router-ip>
an8855-diag fdb | grep -i <router-mac>     # port mask: bit N = switch port N
```

Switch port numbers map to netdev names via the PHY address in the boot log
(`dmesg | grep 'PHY \[mdio_an8855'`) — PHY `1:01` is port 0, `1:02` port 1, and
so on, so on the RD03v2 port 0 = `lan4`, 1 = `lan3`, 2 = `lan2`, 3 = `wan`, and
mask `0x04` means port 2, i.e. `lan2`. Substitute that port for `lan4` below.

```
config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'lan2'
	list ports 'lan3'
	list ports 'lan4'
	option vlan_filtering '1'

config bridge-vlan
	option device 'br-lan'
	option vlan '1'
	list ports 'lan2:u*'
	list ports 'lan3:u*'
	list ports 'lan4:u*'

config bridge-vlan
	option device 'br-lan'
	option vlan '20'
	list ports 'lan4:t'

config interface 'lan'
	option device 'br-lan.1'
	option proto 'static'
	option ipaddr '192.168.1.2'
	option netmask '255.255.255.0'
	option gateway '192.168.1.1'
	list dns '192.168.1.1'

config interface 'iot'
	option device 'br-lan.20'
	option proto 'none'
```

A `wifi-iface` with `option network 'iot'` then broadcasts an SSID whose
clients are bridged into VLAN 20 and reach only the upstream router's IoT
network.

## Verifying

```sh
ip addr show br-lan.1                    # must carry the management address
ping -c3 <gateway>                       # host path alive
cat /sys/class/net/eth1/dsa/tagging      # still vsc73xx-8021q
```

`dmesg | grep "Couldn't decode source"` is **not** a useful check for this
failure — it stayed empty throughout, in the broken state as well. The frames
die before the tagger gets far enough to warn. Test RX, not the log.

With `tools/an8855-diag.c` (see `docs/an8855-tag8021q-fdb.md` for the build
line), the healthy state under VLAN filtering is:

```sh
an8855-diag read 10208a10       # CPU port PVC: PVC_EG_TAG (bits 10:8) must be 0
an8855-diag vlan 1              # CPU port tagged member (etag field = 2), users untagged (0)
an8855-diag fdb                 # clients learned at the bridge VID
```

### Verified on hardware

All three paths were exercised on an RD03v2 AP (conduit port 5):

| Path | Result |
|---|---|
| Enabling `vlan_filtering` on a running system | host path stays up; SSH never drops |
| **Rebooting with `vlan_filtering '1'` already set** | comes up working; all LAN ports in `br-lan` |
| **Disabling it again, without a reboot** | recovers live; `tag_8021q` PVIDs restored |

The last two are the ones that used to fail. Register state after a reboot with
filtering enabled:

```
P0/P1/P2  PCR=0x03  PVID=1         bridged ports on the bridge PVID
P3        PCR=0x03  PVID=0x0c03    standalone port keeps its tag_8021q VID (3075)
P4/P5     PVC=0x91000000           CPU egress untouched (PVC_EG_TAG = 0)
VID1      members=0x27 etag=0x800  CPU tagged, user ports untagged
```

and after disabling it again — **without rebooting** — the bridged ports return
to `PCR=0x01` with `PVID=0x0c10` (the `tag_8021q` bridge VID 3088), which is the
shadow-PVID commit restoring what `tag_8021q` asked for.

## Do not put a bridge VLAN in 3072–4095

VIDs in that range belong to `tag_8021q` and are rejected with `-EBUSY`. Be aware
of the failure mode: the rejection reaches netifd as a netlink extack, so netifd
retries the bridge setup, gives up, and **leaves every DSA port out of the
bridge** — the device ends up reachable only over wifi, or not at all. The driver
also logs it, which is the fast way to spot it:

```
an8855-switch ...: port 1: refusing bridge VLAN 3090: range 3072-4095 is reserved for dsa_8021q
```

This matches `sja1105` and `vsc73xx`, which reject the same range.

Any nonzero `PVC_EG_TAG` on a CPU port means the host path is about to go
silent.

## Testing this safely

VLAN-filtering changes can drop the box off the network. Apply them detached
and arm a rollback that reboots, since a config revert alone did not recover
the pre-v1.5 failure:

```sh
cp /etc/config/network /root/network.good
cat > /root/rollback.sh <<'EOF'
#!/bin/sh
sleep 300
[ -f /root/ok ] && exit 0
cp /root/network.good /etc/config/network
sync; reboot
EOF
chmod +x /root/rollback.sh
start-stop-daemon -S -b -x /root/rollback.sh
```

`touch /root/ok` once the box is confirmed healthy. Note that `nohup … &` does
**not** survive a dropbear session — use `start-stop-daemon -S -b` (see
`docs/no-uart-reflash.md`).
