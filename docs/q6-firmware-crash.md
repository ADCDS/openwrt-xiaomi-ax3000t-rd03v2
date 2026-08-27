# When the WiFi firmware dies (Q6 / WCSS root-PD fatal)

> TL;DR — a fatal error in the **root** PD of the WiFi Q6 used to kill both
> radios until the box was rebooted. It now recovers by itself in about a
> second. Four driver bugs stood in the way; the interesting one is that the Q6
> restarts perfectly well and the kernel was discarding the interrupt that says
> so. The port still ships a watchdog, because something has to catch a
> recovery that fails.

## The failure

The IPQ5018 WiFi block is a Hexagon (Q6) running a *multi-PD* firmware: one
**root** PD plus one **user** PD per radio — `pd-1` = 2.4 GHz (`c000000.wifi`),
`pd-2` = 5 GHz QCN6122 (`b00a040.wifi`). `pd-3` is not used and is `offline` by
design.

When the root PD takes a fatal error, both radios go with it. The tell is in
the kernel log:

```
qcom-q6-mpd cd00000.remoteproc: fatal error received: ...
remoteproc remoteproc0: recovering cd00000.remoteproc
remoteproc remoteproc0: stopped remote processor cd00000.remoteproc
qcom-q6-mpd cd00000.remoteproc: start timed out
remoteproc remoteproc0: can't start rproc cd00000.remoteproc: -110
ath11k b00a040.wifi: failed to send WMI_... cmd: -108     (repeating forever)
```

It can be reproduced on demand:

```sh
echo assert > /sys/kernel/debug/ath11k/ahb-c000000.wifi/simulate_fw_crash
```

There is also a *silent* variant seen in the field: a radio simply stops,
with **no** fatal interrupt and nothing in the log. Only the survey counter
going flat reveals it — which is why the watchdog checks that too.

## Why recovery failed — three separate reasons

**1. The user PD stop waited on dead firmware.** `wcss_pd_stop()` skipped the
SMP2P stop handshake only when *that* user PD was `RPROC_CRASHED`. On a root
fatal the user PDs are still `RPROC_RUNNING`, so the driver asked firmware that
no longer existed for a stop-ack, ate the timeout, and returned early — before
`qcom_scm_msa_unlock()` and before the `rproc_shutdown()` that drops the root
PD's refcount. Fixed by `0821-…`; measured effect: the stop went from
`-ETIMEDOUT` after 5 s with the state stuck at `running`, to `rc=0` reaching
`offline`.

**2. A refcount that could never be released.** `rproc_shutdown()` returns
`-EINVAL` **without decrementing `rproc->power`** when its target is not
`RPROC_RUNNING`. Once the core's own recovery had left the root PD `OFFLINE`,
every later `rproc_shutdown()` on it was a no-op, so the count stayed at 2 and
`rproc_boot()` then returned *success without booting anything*. Recovering
from the user PDs downwards (so the root is still `RUNNING` while they are torn
down) does fix this — all three PDs then reach `offline` and the root gets a
real `qcom_scm_pas_shutdown()`.

**3. The Q6's ready interrupt was being thrown away.** This was the real one,
and it is fixed.

After a clean shutdown the firmware reloads, `qcom_scm_pas_auth_and_reset()`
*succeeds*, and then `qcom_q6v5_wait_for_start()` times out with `-110`. It
looks exactly like a processor that will not boot. It is not — the Q6 boots
fine, and we discard the signal that says so.

`qcom_smp2p_notify_in()` raises an interrupt only for bits that **changed**:

```c
	status = val ^ entry->last_value;
	entry->last_value = val;
	if (!status)
		continue;          /* no change -> no handle_nested_irq() */
```

The SMP2P SMEM items outlive the remote processor. On its second boot the Q6
republishes the *same* ready bit it published on the first, `last_value` still
holds it from that boot, the XOR is zero, and the interrupt is never delivered.

The measurement that proved it, before any fix: during a failed start the
**parent** smp2p summary interrupt increments (the Q6 does kick us) while the
`q6v5 ready` count stays pinned at its cold-boot value of 1. The doorbell
arrives; the edge is swallowed.

```sh
grep -E 'GIC-0 209|q6v5 ready' /proc/interrupts   # before and after a restart
```

Two things were missing, and both are needed:

- **`qcom,smp2p-feature-ssr-ack`** on the IPQ5018 `master-kernel` node. IPQ8074
  and IPQ6018 have carried it for years — see patches `0120-` and `0907-`, the
  latter of whose commit message describes this bug exactly: *"Without this
  first load is OK, but subsequent loads would hang and fail to complete."* The
  consuming code was already in the kernel; only the DT property was absent.
- **`0918-soc-qcom-smp2p-clear-cached-inbound-values-on-restart`**, which
  exports `qcom_smp2p_clear_last_value()` and calls it from `q6_wcss_start()`
  while the Q6 is held in reset, so its next publish registers as a change.
  `qcom_smp2p_do_ssr_ack()` only toggles the RESTART_ACK flag and kicks — it
  never touches `last_value` — so the DT property alone does not fix it. QSDK
  does the same thing (`qcom_clear_smp2p_last_value()`, enabled there for
  IPQ5332 and IPQ9574), and mainline's smp2p v2 support clears the same state
  on SSR detection.

With both in place a clean stop and start of the root PD works:

```
after rmmod:  cd00000.remoteproc=offline pd-1=offline pd-2=offline   ready_irq=1
  ROOT+pd-1 RUNNING again after 6s
final:        cd00000.remoteproc=running pd-1=running pd-2=running   ready_irq=2
```

`ready_irq` 1 → 2 is the edge finally being delivered. Both radios come back
and their survey counters advance again, with no reboot.

A footnote on how this was nearly missed: the failed-start path in
`q6_wcss_start()` also unwinds nothing — no `qcom_scm_pas_shutdown()`, no
`qcom_q6v5_unprepare()` — so every retry inherited the previous failure's state
and produced the `Unbalanced enable for IRQ` warning. That made "it fails
identically every time" look like a hardware limit when attempts 2..N were
simply never independent. `0822-` fixes it, and the sibling
`qcom_q6v5_wcss_sec.c` in this same tree already did it that way.

## 4. The datapath was freed while its interrupts were still live

With the restart working, a real firmware assert stopped leaving the radios
dead and started **rebooting the SoC instead** — instantly, before a one-second
sampling loop could take its first reading. The earlier stall had been hiding
this.

`ath11k_core_reset()` calls `ath11k_hif_ce_irq_disable()` before powering the
target down, but the AHB ops never set `ce_irq_enable`/`ce_irq_disable`, so on
AHB that call did nothing: the copy-engine interrupts and their tasklets stayed
live across `rproc_shutdown()`, touching register space that was no longer
there. The result is a null dereference in `ath11k_hal_srng_access_begin()`
from the monitor rings, and a panic.

Fixed by cherry-picking **openwrt/openwrt#24578** (patches `950-` and `953-`;
the PR's own `951-` is renumbered because this tree already has a `951-`).

## The whole chain, working

```
[42.51] remoteproc remoteproc1: stopped remote processor pd-1
[42.55] remoteproc remoteproc0: stopped remote processor cd00000.remoteproc
[42.55] remoteproc remoteproc2: stopped remote processor pd-2
[42.67] remoteproc remoteproc0: remote processor cd00000.remoteproc is now up
[42.68] remoteproc remoteproc1: remote processor pd-1 is now up
[42.70] remoteproc remoteproc2: remote processor pd-2 is now up
[43.36] ath11k c000000.wifi: pdev 1 successfully recovered
[43.73] ath11k b00a040.wifi: pdev 1 successfully recovered
```

A deliberate `simulate_fw_crash` assert, both radios back **1.2 seconds**
later, no reboot, box uptime continuous. Counters afterwards read `fatal=1`,
`ready=2`, `handover=2`, and `spawn-ack=2` on both user PDs — everything
restarted exactly once. Both radios pass traffic and both SSIDs are up.

For comparison, the reboot path this replaces took **1 m 47 s**.

## Also fixed: a latent array overflow

`qcom_get_pd_asid()` returns `spawn_bit / 8`, i.e. **1, 2, 3** — never 0. But
`struct q6_wcss` declared `struct userpd *upd[MAX_UPD]` with `MAX_UPD == 3`, so
registering `pd-3` wrote one pointer *past the end of the array*. It stayed
invisible only because `upd[]` was the last member, so the write landed in
allocator slack — it silently corrupts whatever is placed after it. Fixed by
`0819-…`.

## What the port does about it

`/usr/sbin/rd03v2-watchdog` (procd service, `START=99`) is a **backstop**, not
the primary recovery path — the driver handles a firmware crash by itself in
about a second, and the watchdog is there for what it does not cover. It
triggers on either:

- any of `remoteproc0` / `pd-1` / `pd-2` not `running` for 2 samples (~60 s), or
- the in-use channel's survey **active time frozen** for 4 samples (~2 min) —
  this is what catches the silent death, which raises no interrupt.

When it fires it **escalates** instead of reaching straight for a reboot:

1. **ath11k reset of the affected radio** (~1 s) — `hw-restart`, which rebuilds
   the driver state and respawns that user PD's firmware without touching the
   root PD. This is what fixes a wedged radio.
2. **Stop and start that user PD** (~16 s) — heavier, reloads firmware, but
   still costs the box nothing in uptime.
3. **Reboot** (~1 m 47 s) — only if both fail.

Only the affected radio is touched: a fault on 5 GHz does not cost 2.4 GHz
clients a reset. At most 3 in-place attempts are allowed per hour, so a fault
that needs constant nursing gets a reboot rather than being papered over every
couple of minutes.

Before touching anything it writes the evidence to `/overlay/rd03v2-watchdog/`:
remoteproc states, the `q6v5` IRQ counters (these survive a log wrap and are
the best forensic record), meminfo, and the tail of `dmesg`/`logread`.

Guards: it will not reboot within the first 10 minutes of uptime, nor within an
hour of its previous reboot, so a persistent fault cannot turn into a boot loop.

Verified on the bench, four ways:

| test | result |
|---|---|
| real firmware assert (driver recovers in ~1 s) | watchdog correctly does **nothing** — no incident logged |
| `pd-2` stopped by hand | detected in ~60 s, healed by ath11k reset, **no reboot** (spawn-ack 26→27) |
| same, checking blast radius | only `phy1-ap0` reset; the 2.4 GHz radio untouched |
| in-place recovery unavailable | falls through to a reboot, as designed |

To turn it off:

```sh
touch /etc/rd03v2-watchdog.disable   # takes effect on next start; or
/etc/init.d/rd03v2-watchdog disable && /etc/init.d/rd03v2-watchdog stop
```

Disable it before doing any deliberate crash testing, or it will reboot the box
out from under you.

## Diagnosing an event after the fact

```sh
ls /overlay/rd03v2-watchdog/          # incident-<stamp>.log per event
grep q6v5 /proc/interrupts            # fatal/ready/stop-ack/spawn-ack counters
for r in /sys/class/remoteproc/remoteproc*; do
        echo "$(cat $r/name) $(cat $r/state)"
done
```

`q6v5 fatal` incrementing means the firmware asserted. All counters at their
boot values while a radio is dead means the *silent* variant instead.

Note the box has no RTC and, as an AP, often no reachable NTP server, so
timestamps inside incident files can be wrong — `uptime` is recorded alongside
them and is the trustworthy clock.

Trying to recover by hand does not work on a shipped build, and is worth
knowing so you don't chase it: `echo stop > .../remoteprocN/state` returns
`-ETIMEDOUT` and the state does not change (reason 1 above), and after the
0821 fix the stop succeeds but the root still will not come back (reason 3).
