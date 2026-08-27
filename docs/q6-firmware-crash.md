# When the WiFi firmware dies (Q6 / WCSS root-PD fatal)

> TL;DR — a fatal error in the **root** PD of the WiFi Q6 kills both radios and
> the driver cannot bring them back. Two of the three reasons were driver bugs
> and are fixed here; the third is the Q6 itself refusing to restart, which no
> amount of driver work in `qcom_q6v5_mpd` has been able to solve. That is why
> the port ships a watchdog that reboots the box instead.

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

**3. The Q6 does not restart — and the driver never unwinds the failed
attempt.** After a clean shutdown the firmware reloads and
`qcom_scm_pas_auth_and_reset()` *succeeds*, but the Q6 never raises its ready
interrupt and `qcom_q6v5_wait_for_start()` times out (`-110`). Look at what
`q6_wcss_start()` does with that failure:

```c
	qcom_q6v5_prepare(&wcss->q6);              /* running = true, enable_irq() */
	ret = qcom_scm_pas_auth_and_reset(desc->pasid);
	if (ret) {
		dev_err(wcss->dev, "wcss_reset failed\n");
		return ret;                        /* no unprepare */
	}
	ret = qcom_q6v5_wait_for_start(&wcss->q6, 5 * HZ);
	if (ret == -ETIMEDOUT)
		dev_err(wcss->dev, "start timed out\n");
	return ret;                                /* no pas_shutdown, no unprepare */
```

Nothing is undone. The peripheral is left authenticated-and-reset in TrustZone
with no matching `qcom_scm_pas_shutdown()`, and the q6v5 context is still
"prepared" (`running == true`, handover IRQ enabled — which is where the
`Unbalanced enable for IRQ` warning comes from). **Every later attempt starts
from that poisoned state**, so "it fails every time" is not independent
evidence of a hardware limit: attempts 2..N are consequences of attempt 1
never being cleaned up.

The sibling driver in this same tree, `qcom_q6v5_wcss_sec.c`, routes *every*
error path through `goto unprepare`. This one does neither. Whether adding
that unwind (plus a `pas_shutdown` on the timeout) makes the restart succeed is
**untested** — it is the next experiment, not a settled answer.

What *is* settled: ath11k's own reset path works on this hardware. Writing
`hw-restart` to `simulate_fw_crash` tears both radios down and brings them
back, no reboot, `pdev 1 successfully recovered`, both survey counters
advancing again. So restarting radios in software is demonstrably possible
here when the Q6 is alive; only the crashed-root case is unresolved.

Because (3) is unresolved today, the fix for (2) buys nothing user-visible yet
and is **not** shipped — only (1) and the array-overflow fix below are.

## Also fixed: a latent array overflow

`qcom_get_pd_asid()` returns `spawn_bit / 8`, i.e. **1, 2, 3** — never 0. But
`struct q6_wcss` declared `struct userpd *upd[MAX_UPD]` with `MAX_UPD == 3`, so
registering `pd-3` wrote one pointer *past the end of the array*. It stayed
invisible only because `upd[]` was the last member, so the write landed in
allocator slack — it silently corrupts whatever is placed after it. Fixed by
`0819-…`.

## What the port does about it

`/usr/sbin/rd03v2-watchdog` (procd service, `START=99`) reboots the box when
the radios are gone for good. It triggers on either:

- any of `remoteproc0` / `pd-1` / `pd-2` not `running` for 2 samples (~60 s), or
- the in-use channel's survey **active time frozen** for 4 samples (~2 min) —
  this is what catches the silent death, which raises no interrupt.

Before rebooting it writes the evidence to `/overlay/rd03v2-watchdog/`:
remoteproc states, the `q6v5` IRQ counters (these survive a log wrap and are
the best forensic record), meminfo, and the tail of `dmesg`/`logread`.

Guards: it will not reboot within the first 10 minutes of uptime, nor within an
hour of its previous reboot, so a persistent fault cannot turn into a boot loop.

Measured on a real crash: **detected in 39 s, service restored 1 m 47 s after
the crash**, unattended.

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
