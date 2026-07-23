# AN8855 tag_8021q FDB: the dual-keyspace trap (issue #7)

> TL;DR — under tag_8021q with independent VLAN learning (IVL), the switch FDB
> is keyed by `(MAC, VID)`. The data path never uses VID 0, so **any FDB entry
> installed at VID 0 is invisible to forwarding**. Host entries must be
> translated into the tag_8021q VID of the database they belong to
> (`999-2759` patch, sja1105 model).

## The bug (as shipped before v1.2)

The NSS build's AN8855 driver ran two disjoint FDB keyspaces:

- **Data path**: bridged frames classify into the tag_8021q **bridge VID**
  (3088 for bridge 1); `BR_LEARNING` re-enables hardware SA learning on
  bridged user ports, so every client MAC seen on a LAN port is learned at
  `(mac, 3088) → LAN port`.
- **Host path**: assisted learning (`assisted_learning_on_cpu_port`) installs
  wifi-client/router MACs through `.port_fdb_add` with **vid 0** (the bridge
  is VLAN-unaware), and `AN8855_PORT_VID_DEFAULT` is 0, so the "default vid"
  fallback kept them at `(mac, 0) → CPU`.

A client roaming from a peer AP onto local wifi still has its stale
hardware-learned `(mac, 3088) → backhaul-port` entry (its broadcasts crossed
the backhaul while it lived behind the other AP). The CPU host entry at
`(mac, 0)` never displaces it — different key. Every downstream unicast to the
client (DHCP OFFER/ACK first of all) ingresses the backhaul port, hits the
stale entry — a *known* unicast pointing back at its own ingress port — and is
**same-port filtered**. DHCP-after-roam fails until FDB ageing (~300 s), which
the client's retry loop usually re-arms. Flood was never broken (that is why
the AP's own IP stayed reachable — its MAC is never learned on a user port, so
unknown-unicast flood delivers it to the CPU).

## The fix (`999-2759-nss-an8855-tag8021q-host-fdb-vid.patch`)

Mirrors `sja1105_fdb_add`:

- `.port_fdb_add`/`.port_fdb_del` translate `vid == 0` per the `dsa_db`:
  `DSA_DB_BRIDGE → dsa_tag_8021q_bridge_vid(db.bridge.num)`,
  `DSA_DB_PORT → dsa_tag_8021q_standalone_vid(db.dp)`.
- `ds->fdb_isolation = true` so DSA keeps `db.bridge.num` intact (without it
  DSA forces the bridge number to 0 and the translation would compute the
  wrong VID).
- Same translation in the MDB ops, and tag_8021q VIDs are hidden from
  `bridge fdb` dumps (reported as 0), both like sja1105.

The host entry then lands on the same IVL key as the stale learned entry and
**overwrites** it, steering downstream unicast to the CPU. NSS-overlay-only;
the base MTK-tag build has a single keyspace and never had the bug.

## Live switch introspection: `tools/an8855-diag.c`

The driver registers an `an8855_dsa` generic-netlink family (raw switch
register read/write, root-only). `tools/an8855-diag.c` is a self-contained
client (no libnl) used to diagnose #7 on the running router — no rebuild, no
serial:

```sh
# build (static, OpenWrt toolchain)
aarch64-openwrt-linux-musl-gcc -static -O2 -o an8855-diag tools/an8855-diag.c

an8855-diag fdb            # dump all live FDB entries: MAC, VID, port mask
an8855-diag vlan 0 3088    # VLAN table entries: members, etag, IVL, valid
an8855-diag read 102000b4  # raw register read (UNUF shown here)
an8855-diag write <reg> <val>
```

The `fdb` dump is the fastest way to see which keyspace an entry landed in.
With the fix, host entries appear at 3072+ (standalone) / 3088+ (bridge) VIDs;
a `(mac, 0)` entry means the translation is not running. It can also *write*
FDB entries via the ATC registers — that is how the #7 drop mechanism was
proven pre-fix (a synthetic `(mac, 3088) → CPU` entry delivered, `→ ingress
port` black-holed, absent flooded).
