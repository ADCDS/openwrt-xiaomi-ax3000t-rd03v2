# L2TP and PPTP

Some ISPs give Internet access only inside a tunnel: DHCP on the WAN port hands out a private
address, and through it the router opens an L2TP (or PPTP) session to the ISP's server with a
username and password. The client side of both is in this port's package repository from
v2.1.2: install it with `apk`, restart the network, and add an interface with protocol
"L2TP" or "PPtP".

## What ships

| Package | What it is |
|---|---|
| `xl2tpd` | the L2TP daemon and netifd's protocol `l2tp` |
| `ppp-mod-pppol2tp` | pppd's PPP-over-L2TP plugin |
| `kmod-pppol2tp` | the kernel's PPP-over-L2TP driver (`l2tp_ppp.ko`) |
| `ppp-mod-pptp` | pppd's PPTP plugin; with it netifd offers protocol `pptp` |
| `kmod-pptp`, `kmod-mppe` | the kernel's PPTP driver and MPPE encryption |

The kernel modules are built with the image, so they install only on the image of the same
release ([packages](packages.md)); v2.1.1 and earlier have none. A sysupgrade drops added
packages: add them again afterwards.

## Installing

```sh
apk update
apk add xl2tpd          # L2TP
apk add ppp-mod-pptp    # PPTP
/etc/init.d/network restart
```

`apk` pulls in the plugin and the kernel modules: 13 packages for both, about 0.4 MB. The
restart matters: netifd loads protocol handlers only when it starts, so until then LuCI does
not offer the protocol and an interface that uses it stays down. A reboot does the same.

## Configuring

**In LuCI:**

1. Network → Interfaces → Add new interface…: a name (for example `isp`) and protocol "L2TP"
   (or "PPtP"), then Create interface.
2. General Settings: the server your ISP names (a host name or an address), the username and
   the password.
3. Firewall Settings: the `wan` zone.
4. Network → Interfaces → wan → Advanced Settings → Use gateway metric: `10` (see below).
5. Save, then Save & Apply.

**With uci:**

```sh
uci set network.isp=interface
uci set network.isp.proto='l2tp'            # or 'pptp'
uci set network.isp.server='<the ISP server>'
uci set network.isp.username='<username>'
uci set network.isp.password='<password>'
uci set network.wan.metric='10'
uci add_list firewall.@zone[1].network='isp'   # zone 1 is wan in OpenWrt's default firewall
uci commit
/etc/init.d/network reload
/etc/init.d/firewall reload
```

**Why the WAN metric.** The tunnel's default route and the one DHCP gives the WAN both have
metric 0, and netifd installs a route by replacing any other with the same metric: the
tunnel's takes the WAN's place, and when the tunnel goes down the router is left with no IPv4
default route at all until the WAN is set up again. On the bench that is exactly what
happened. With the WAN at 10 both routes stay: the tunnel's wins while it is up, and the
WAN's takes over when it is not. The protocol adds a host route to the server through the
WAN, so the server stays reachable once the tunnel carries the default route. The server's
name is looked up with the WAN's DNS when the tunnel starts.

If it does not come up, `logread | grep -E 'xl2tpd|pppd'` shows why (authentication,
an unreachable server, an option pppd refuses).

## PPTP

**PPTP needs one line of `/etc/ppp/options.pptp` changed.** OpenWrt's file still says
`mppe required,no40,no56,stateless`, which pppd 2.5 no longer accepts: the interface fails at
once with `unrecognized option 'mppe'` in the log and `OPTION_ERROR` in `ifstatus`. The file
comes from OpenWrt's `ppp-mod-pptp`; its snapshot build has the same line. pppd 2.5 spells the
same settings (MPPE required, 128-bit only, stateless) as two options:

```sh
sed -i 's/^mppe required,no40,no56,stateless$/require-mppe-128\nnomppe-stateful/' /etc/ppp/options.pptp
ifup isp
```

On the bench the session then came up with "MPPE 128-bit stateless compression enabled". apk
keeps the edited file if the package is removed.

## Speed

Tunnel traffic is not offloaded: NSS and ECM have no L2TP or PPTP support in this build
(ECM is built without its L2TPv2 and PPTP front ends, whose kernel hooks are not ported), so
the CPU handles every packet. On the bench, with a wired client routed through the tunnel to
a test server:

| | Up | Down |
|---|---|---|
| L2TP, one TCP connection | 43-46 Mbit/s | 56-57 Mbit/s |
| PPTP (MPPE-128), one TCP connection | 55-56 Mbit/s | 38-41 Mbit/s |
| L2TP, four TCP connections | 55 Mbit/s | 52 Mbit/s |
| no tunnel, the same path (offloaded) | 75-83 Mbit/s | 75 Mbit/s |

In the tunnel runs one CPU core was fully busy: the kernel processes received packets on the
second core. Some L2TP runs measured lower (30-47 Mbit/s) without the core saturated. The
no-tunnel row is what the bench's path allowed, at 2-4 % CPU; routed and offloaded the
router does over 900 Mbit/s ([VALIDATION](../VALIDATION.md)).
