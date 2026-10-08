# ECM, IPv6 and multi-WAN policy routing (issue #36)

How the NSS image's connection manager (ECM) behaves with policy routing
(mwan3) and NAT66, and the fix in ECM patch
[`0030`](../nss/feed-patches/qca-nss-ecm/0030-ecm-db-defunct-on-policy-rule-changes.patch).
All results below are from the bench (v1.13-nss, whose ECM is identical to
v1.12-nss).

## What ECM does with IPv6

- **`front_end_ipv6_stop` is not a setting.** ECM uses that debugfs value as an
  internal pause flag. It writes 1 and then 0 around each of its own
  connection clean-up passes:
  - IPv6 route add or delete,
  - a bridge FDB entry moving or ageing out,
  - a neighbour changing MAC,
  - a Wi-Fi station expiring.

  A 1 written by hand lasts until the next such event. A dummy
  `ip -6 route add` was enough to reset it on the bench. mwan3 restarts and
  heavy traffic produce these events all the time.
- **NAT66 is never offloaded.** NSS refuses an IPv6 connection whose
  addresses are translated ("NPT66 acceleration is supported only through
  SFE", `frontends/cmn/ecm_ported_ipv6.c`), and SFE is not built. With the
  flag at 0, masqueraded IPv6 ran in the slow path at 245-275 Mbit/s, and
  NSS's IPv6 rule count did not move. TCP is offloaded only once the
  connection is established, so a connection stuck in SYN_SENT was never
  offloaded.
- **`dev.nss.ipv6cfg.ipv6_accel_mode=0` does not disable IPv6 offload** on
  this firmware. With it set, NSS still created IPv6 rules and forwarded
  routed IPv6 at 920 Mbit/s. Writing 1 back fails with an I/O error (the
  firmware refuses the change), and only a reboot restores it.
- Plain IPv6 over PPPoE is offloaded and fine: 925 Mbit/s each way. Running
  alongside NAT66 and IPv4 traffic, with 8 to 32 connections per path and
  repeated route churn, nothing stalled and every new connection completed.
  ECM refreshes the conntrack timeouts of offloaded flows.

## The stall: offloaded flows pinned across a policy routing change

ECM builds a connection's NSS rule from the egress its packets took when it
was accelerated. Route changes make ECM drop (defunct) the affected
connections. A default-route change in any routing table drops every IPv6
connection. Policy routing rules (`ip rule`) and packet marks never do. Stock
ECM has no notifier for rule changes, and conntrack mark events reach only a
classifier this build does not enable.

mwan3 routes with fwmark rules into per-WAN tables. During a restart or
failover, the rules and the table routes are removed and re-added:

1. The route events drop the offloaded connections.
2. Their next packets follow whatever routing is left. Without the rules,
   that is the main table, which may point at the other WAN.
3. ECM offloads them again on that path.
4. If the rules come back last, nothing drops them again, and NSS keeps
   sending them out the wrong WAN.

Routed IPv6 has no NAT, so the kernel's masquerade clean-up does not kill
these connections. They sit on a WAN that drops their source prefix.

Bench rig: PPPoE served by a Linux host (ISP1, routed IPv6), the bench's
other WAN (ISP2, NAT66 masquerade), fwmark rules to one table per WAN, and
the main table pointing at ISP2. The far end drops packets with the wrong
source prefix for the link they arrive on. The emulated restart removes the
rules and the table defaults for 3 s, then restores them.

| Restore order, ECM | Routed IPv6 upload over PPPoE |
|---|---|
| rules last, stock ECM | **0 Mbit/s from the restart to the end of the 40 s run**; its retransmits kept leaving on ISP2 |
| routes last, stock ECM | stalled during the restart, back 2 s after it (the last route event re-evaluates) |
| rules last, IPv6 offload held off | back right after the restart (slow path) |
| rules last, then `echo 1 > /sys/kernel/debug/ecm/ecm_db/defunct_all` | back on the next TCP retransmit |
| rules last, `ipv6_accel_mode=0` | stalled the same way |
| rules last, **patched ECM (0030)** | stalled during the restart, back right after the rules returned (t=14 of 40, then ~920 Mbit/s); retransmits stopped leaving on ISP2 |
| routes last, patched ECM | no stall |

Download over the same path recovered within seconds: there the rule is built
from the packets arriving over PPPoE. NAT66 flows are never offloaded and
were not affected.

IPv4 behaves differently. A masqueraded connection whose packets leave
through another interface is killed by the kernel, with or without NSS, so a
restart like this ends IPv4 connections on the moved path. That is ordinary
mwan3 behaviour (see its `flush_conntrack` option), not something ECM can
fix.

## The fix: patch 0030

ECM registers a FIB notifier. When a policy rule is added or deleted, it
defuncts all connections of that address family, which is what its route
notifiers already do for route changes. Their next packets are routed with
the current rules and offloaded on the right path. The notifier runs in
atomic context, so it only marks the family and schedules a work item. A
burst of rule changes (an mwan3 restart) collapses into a few passes, and a
change during a pass schedules another one after it. ECM logs
`ECM: policy routing rule changes defunct accelerated connections` when the
notifier is in place.

The cost is that every `ip rule` change makes all offloaded connections of
that family go through the slow path for a packet or two before they are
offloaded again. Rule changes happen when a multi-WAN manager starts, stops
or fails over, not during normal traffic.

On the bench the patched module behaved as follows:

- In the restart test above, the PPPoE upload recovered as soon as the rules
  were back, in both directions.
- Under a storm of 800 rule changes in 4.4 s, with IPv6/PPPoE, NAT66 and
  IPv4/PPPoE traffic running, the flows dipped and recovered. No kernel
  warnings appeared, and memory stayed flat.
- Rebuilt without the patch, the same tree reproduces the release's `ecm.ko`
  byte for byte, so 0030 is the only difference.
