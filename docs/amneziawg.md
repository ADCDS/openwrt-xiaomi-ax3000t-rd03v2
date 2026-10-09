# AmneziaWG

> TL;DR — AmneziaWG is WireGuard with traffic obfuscation, for networks whose
> DPI blocks plain WireGuard. From v1.14 the release package archive
> (`…-kmods.tar.gz`, or `…-kmods-nss.tar.gz` for an `-nss` image) carries
> its kernel module, the `awg` tool with its network protocol, and a LuCI
> page. Nothing is in the image, so install it from the archive, restart the
> network, and add an interface with protocol "AmneziaWG VPN". In LuCI,
> "Import configuration" takes the `.conf` the Amnezia app gives you.

## What it is

AmneziaWG keeps WireGuard's cryptography and changes what its packets look
like on the wire: junk packets before the handshake (`Jc`, `Jmin`, `Jmax`),
random padding in front of packets (`S1`–`S4`), custom message types in
place of WireGuard's 1–4 (`H1`–`H4`, ranges since AWG 2.0), and decoy
packets that can imitate another protocol (`I1`–`I5`).

Both ends have to run AmneziaWG with the same settings: a plain WireGuard
peer cannot talk to it once the obfuscation is on. The usual setup is a
server installed by the Amnezia app, which also generates the client
configs.

The kernel module has to be built against this port's kernel, so packages
from elsewhere (Amnezia's releases, other OpenWrt builds) will not install.

## What ships

| Package | Version | What it is |
|---|---|---|
| `kmod-amneziawg` | 3.1.20260906 | the kernel module, from [amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) |
| `amneziawg-tools` | 3.1.20260812 | `awg` and the netifd protocol `amneziawg`, from [amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools) |
| `luci-proto-amneziawg` | 3.1.0 | the LuCI protocol page and Status → AmneziaWG |

The OpenWrt packaging comes from the community
[awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) feed, pinned in
[`feeds.lock`](../feeds.lock). Amnezia's own `amneziawg-openwrt` stopped at
AWG 1.0 in 2024.

They depend on modules and tools that are also in the archive:
`kmod-crypto-lib-chacha20poly1305`, `kmod-crypto-lib-curve25519` and their
dependencies, `kmod-udptunnel4`/`6` (the `-nss` image already has these two),
`ip-tiny` and `resolveip`. `ip-tiny` takes over `/sbin/ip` from busybox.

v1.13 has the same kernels and package signing keys as v1.14, so the v1.14
packages also install on v1.13.

## Installing

Install onto the NAND system, from the archive that matches your image (see
[Installing kernel modules](installation-and-usage.md#installing-kernel-modules)).

**With a PC**, `apk` resolves the dependencies by itself. Serve the
extracted archive and install the LuCI package, which pulls in the rest
(`amneziawg-tools` alone if you don't want LuCI):

```sh
tar -xzf openwrt-…-v2-kmods.tar.gz -C kmods && cd kmods
python3 -m http.server 8000
```
```sh
# on the router:
apk add --repositories-file /dev/null \
        --repository http://<pc-ip>:8000/packages.adb luci-proto-amneziawg
```

**From the router alone**, extract the whole set from the release:

```sh
TAG=v1.14
A=openwrt-qualcommax-ipq50xx-xiaomi_mi-router-ax3000t-v2-kmods.tar.gz   # …-kmods-nss.tar.gz on an -nss image
U=https://github.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2/releases/download/$TAG/$A
F="kmod-amneziawg-6.12.94.3.1.20260906-r1.apk amneziawg-tools-3.1.20260812-r1.apk luci-proto-amneziawg-3.1.0-r1.apk
kmod-crypto-lib-chacha20poly1305-6.12.94-r1.apk kmod-crypto-lib-chacha20-6.12.94-r1.apk kmod-crypto-lib-poly1305-6.12.94-r1.apk
kmod-crypto-lib-curve25519-6.12.94-r1.apk kmod-crypto-kpp-6.12.94-r1.apk kmod-udptunnel4-6.12.94-r1.apk kmod-udptunnel6-6.12.94-r1.apk
ip-tiny-6.18.0-r2.apk resolveip-2.apk"
mkdir -p /tmp/awg && cd /tmp/awg
wget -q -O - "$U" | tar -xzf - $(for f in $F; do echo ./$f; done)
apk add --repositories-file /dev/null ./*.apk
cd / && rm -rf /tmp/awg
```

On an `-nss` image `apk` reports the two `kmod-udptunnel` packages as
"Replacing" with the same version; that is harmless.

**Then restart the network** (`/etc/init.d/network restart`) or reboot.
netifd only loads protocol handlers when it starts, so until then an
AmneziaWG interface stays down with protocol "none".

## Configuring

**In LuCI:** Network → Interfaces → Add new interface, protocol
"AmneziaWG VPN". Under General Settings, "Load configuration…" next to
Import configuration takes the `.conf` from the Amnezia app (paste it or
drag the file) and fills in the keys, addresses, the AmneziaWG Settings tab
and the peer. Put the interface in a firewall zone (Firewall Settings tab),
then Save & Apply. Status → AmneziaWG shows the peers and their last
handshake.

**With uci**, the equivalent of an Amnezia client config: the interface,
its peer (a section of type `amneziawg_<interface>`), and a firewall zone
that LAN traffic may be forwarded and masqueraded into:

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

The `awg_*` values are examples: copy yours from the config (`Jc` →
`awg_jc`, …, `I1` → `awg_i1`). Leave out the ones your config doesn't have.
`0.0.0.0/0` with `route_allowed_ips` sends everything through the tunnel; a
narrower `allowed_ips` routes only those networks. For the config's `DNS`
line, add `list network.awg0.dns='<server>'`; LuCI's import does that for you.

## Removing

```sh
apk del luci-proto-amneziawg amneziawg-tools kmod-amneziawg
```

Add the dependencies to the same command if nothing else uses them. The
module stays loaded, and the LuCI backend registered, until the next reboot.

## Performance

Measured on the bench on 2026-10-09 with v1.14: a LAN client sending through
the tunnel to an `amneziawg-go` peer on a PC, 4 TCP streams, AWG 2.0
settings.

| Image | Download (router decrypts) | Upload (router encrypts) |
|---|---|---|
| default, packet steering on (the default) | 199 Mbit/s | 66 Mbit/s |
| default, packet steering off | 84 Mbit/s | 45 Mbit/s |
| `-nss` | 43 Mbit/s | 28 Mbit/s |

The router's CPU is the limit: it is saturated at these rates, and other
routed traffic competes with the tunnel.

The `-nss` image tunnels slower although its module is the same: a download
that ends on the router itself reaches about 195 Mbit/s there. NSS cannot
offload the tunnel's traffic, so every decrypted packet takes NSS's host
path to the LAN, and the NSS connection manager keeps packet steering off.
If the tunnel matters more to you than NSS offload, the default image is the
faster choice.

`amneziawg-go`, the userspace implementation, also runs here (it needs only
`kmod-tun`, which is in the image), but it is much slower: in a download to the
router itself, 46 Mbit/s against 170 Mbit/s for the kernel module. On an `-nss`
image it was killed for lack of memory under sustained load (49 MB
resident); with `GOMEMLIMIT=20MiB` it survived at 22 Mbit/s. With the
packages above it is not needed.
