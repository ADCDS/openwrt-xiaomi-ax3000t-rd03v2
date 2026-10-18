# AmneziaWG

AmneziaWG is WireGuard with traffic obfuscation, for networks whose DPI blocks plain
WireGuard. Its kernel module, the `awg` tool with its network protocol, and a LuCI page are
in this port's package repository. Install them with `apk`, restart the network, and add an
interface with protocol "AmneziaWG VPN". LuCI's "Load configuration…" takes the `.conf` the
Amnezia app gives you.

## What it is

AmneziaWG keeps WireGuard's cryptography and changes what its packets look like on the wire:
junk packets before the handshake (`Jc`, `Jmin`, `Jmax`), random padding in front of packets
(`S1`-`S4`), custom message types in place of WireGuard's 1-4 (`H1`-`H4`, ranges since AWG
2.0), and decoy packets that can imitate another protocol (`I1`-`I5`).

Both ends have to run AmneziaWG with the same settings: a plain WireGuard peer cannot talk to
it once the obfuscation is on. The usual setup is a server installed by the Amnezia app,
which also generates the client configs.

## What ships

| Package | Version | What it is |
|---|---|---|
| `kmod-amneziawg` | 3.1.20260906 | the kernel module, from [amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) |
| `amneziawg-tools` | 3.1.20260812 | `awg` and the netifd protocol `amneziawg`, from [amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools) |
| `luci-proto-amneziawg` | 3.1.0 | the LuCI protocol page and Status → AmneziaWG |

The OpenWrt packaging comes from the community
[awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) feed, pinned in
[`feeds.lock`](../feeds.lock) and `build.sh`.

The kernel module is built with the image, so it installs only on the image of the same
release ([packages](packages.md)). Packages from elsewhere (Amnezia's releases, other OpenWrt
builds) will not install. A sysupgrade drops added packages: add them again afterwards.

## Installing

```sh
apk update
apk add luci-proto-amneziawg    # or amneziawg-tools alone, without the LuCI page
/etc/init.d/network restart
```

`apk` pulls in the rest: the module, the tools, `kmod-crypto-lib-chacha20poly1305`,
`kmod-crypto-lib-curve25519` and their dependencies, `kmod-udptunnel4`/`6` and `resolveip`
(11 packages, about 0.3 MB).

The restart matters: netifd loads protocol handlers only when it starts, so until then an
AmneziaWG interface stays down with protocol "none". A reboot does the same.

## Configuring

**In LuCI:**

1. Network → Interfaces → Add new interface…: a name (for example `awg0`) and protocol
   "AmneziaWG VPN", then Create interface.
2. General Settings → "Load configuration…": paste the `.conf` from the Amnezia app (or drag
   the file), then Import settings. That fills in the keys, the addresses, DNS, the
   AmneziaWG Settings tab and the peer.
3. Peers tab → edit the peer → tick **Route Allowed IPs**. The import leaves it off, and
   without it nothing is routed into the tunnel: it comes up and shows a handshake, but
   carries no traffic. With the app's `AllowedIPs = 0.0.0.0/0, ::/0` it sends everything
   through the tunnel.
4. Firewall Settings tab: put the interface in a firewall zone that masquerades and that the
   LAN may forward into (the `wan` zone, or a zone of its own as in the uci example below).
5. Save, then Save & Apply. Status → AmneziaWG shows the peer and its last handshake.

**For a full tunnel, give the WAN a metric** (Network → Interfaces → wan → Advanced
Settings → Use gateway metric: `10`, or `uci set network.wan.metric='10'`). The tunnel's
default route and the WAN's both have metric 0, so the tunnel's replaces the WAN's. When the
tunnel then goes down (disabled, or deleted), the router is left with no IPv4 default route
and no internet until `ifup wan` or a reboot. With the WAN at 10, both routes stay: the
tunnel's wins while it is up, and the WAN's takes over when it is not.

The server itself stays reachable through the WAN: the protocol adds a host route to the
peer's endpoint, unless "No Host Routes" is ticked.

**After changing a peer, restart the interface** (Network → Interfaces → Restart on it, or
`ifup awg0`). A network reload does not re-apply peer settings.

**With uci**, the equivalent of an Amnezia client config: the interface, its peer (a section
of type `amneziawg_<interface>`), and a firewall zone that LAN traffic is forwarded and
masqueraded into:

```sh
uci batch <<'EOF'
set network.awg0=interface
set network.awg0.proto='amneziawg'
set network.awg0.private_key='<PrivateKey>'
add_list network.awg0.addresses='<Address>'
set network.awg0.awg_jc='4'
set network.awg0.awg_jmin='40'
set network.awg0.awg_jmax='70'
set network.awg0.awg_s1='68'
set network.awg0.awg_s2='149'
set network.awg0.awg_s3='32'
set network.awg0.awg_s4='16'
set network.awg0.awg_h1='471800590-471800690'
set network.awg0.awg_h2='1246894907-1246895000'
set network.awg0.awg_h3='923637689-923637690'
set network.awg0.awg_h4='1769581055-1869581055'
set network.awg0.awg_i1='<b 0xf6ab3267fa><t><r 10>'
set network.server=amneziawg_awg0
set network.server.public_key='<peer PublicKey>'
add_list network.server.allowed_ips='0.0.0.0/0'
set network.server.route_allowed_ips='1'
set network.server.endpoint_host='<server>'
set network.server.endpoint_port='<port>'
set network.server.persistent_keepalive='25'
set network.wan.metric='10'
set firewall.awg=zone
set firewall.awg.name='awg'
set firewall.awg.input='REJECT'
set firewall.awg.output='ACCEPT'
set firewall.awg.forward='REJECT'
set firewall.awg.masq='1'
add_list firewall.awg.network='awg0'
set firewall.awg_fwd=forwarding
set firewall.awg_fwd.src='lan'
set firewall.awg_fwd.dest='awg'
EOF
uci commit; /etc/init.d/network reload; /etc/init.d/firewall reload
```

The `awg_*` values are examples: copy yours from the config (`Jc` → `awg_jc`, …, `I1` →
`awg_i1`), and leave out the ones your config doesn't have. A narrower `allowed_ips` routes
only those networks, and then the WAN metric is not needed. For the config's `DNS` line, add
`list network.awg0.dns='<server>'`; LuCI's import does that for you.

IPv6 through a full tunnel was not tested.

## Removing

Delete the interface (and the WAN metric, if you set it only for the tunnel), then:

```sh
apk del luci-proto-amneziawg amneziawg-tools kmod-amneziawg
```

`apk` also removes the dependencies it pulled in. The module stays loaded until a reboot or
`rmmod amneziawg`.

## Performance

Measured on v2.0.0 on 2026-10-18: a LAN client through the tunnel to an `amneziawg-go` peer on
a PC, 4 TCP streams, AWG 2.0 settings.

| | Mbit/s |
|---|---|
| Download (the router decrypts) | 49 |
| Upload (the router encrypts) | 31 |
| Ordinary WAN NAT with the tunnel up, still offloaded | 941 / 938 |

The router's CPU is the limit: it is saturated at these rates. NSS cannot offload the tunnel's
traffic, so every packet takes the host path. Other traffic keeps its NSS offload. If the
tunnel matters more to you than NSS offload, the v1.14 standard image (branch `v1`, no NSS)
did 199 / 66 Mbit/s on the same test.

`amneziawg-go`, the userspace implementation, is not needed with these packages. On v1.14 it
was much slower than the module and was killed for lack of memory under sustained load.
