# When the WiFi firmware dies (Q6 / WCSS root-PD fatal)

> TL;DR — a fatal error in the **root** PD of the WiFi Q6 kills both radios.
> Several driver bugs stood in the way of recovering it and are fixed; the
> interesting one is that the Q6 restarts perfectly well and the kernel was
> discarding the interrupt that says so. **The root PD now restarts by itself,
> but the radios still do not come back**: nothing in the committed kernel
> respawns the user PDs that carry them, so their firmware never returns. In
> every trial so far — asserts 7 to 32 minutes after boot — the radios stayed
> dead until a reboot, which the watchdog does a couple of minutes later. An
> assert early in the boot may be routed differently (the withdrawn log below
> was at 42 s) and has not been tested. A kernel fix is written but not yet in
> this tree or tested on hardware.

## The failure

The IPQ5018 WiFi block is a Hexagon (Q6) running a *multi-PD* firmware: one
**root** PD plus one **user** PD per radio — `pd-1` = 2.4 GHz (`c000000.wifi`),
`pd-2` = 5 GHz QCN6122 (`b00a040.wifi`). `pd-3` is not used and is `offline` by
design. Each user PD hosts that radio's WLAN firmware, including the QMI
server ath11k talks to.

When the root PD takes a fatal error, both radios go with it. It can be
reproduced on demand:

```sh
echo assert > /sys/kernel/debug/ath11k/ahb-c000000.wifi/simulate_fw_crash
```

Before the fixes below, the root PD never came back:

```
qcom-q6-mpd cd00000.remoteproc: fatal error received: ...
remoteproc remoteproc0: recovering cd00000.remoteproc
remoteproc remoteproc0: stopped remote processor cd00000.remoteproc
qcom-q6-mpd cd00000.remoteproc: start timed out
remoteproc remoteproc0: can't start rproc cd00000.remoteproc: -110
ath11k b00a040.wifi: failed to send WMI_... cmd: -108     (repeating forever)
```

With them, it does — and the radios stay dead anyway (2026-09-13, NSS Wi-Fi
image; the default build and the NSS image with offload off behave the same):

```
[1691.407] qcom-q6-mpd cd00000.remoteproc: fatal error received: err_smem_ver.2.1: ...
[1691.487] remoteproc remoteproc0: recovering cd00000.remoteproc
[1691.502] remoteproc remoteproc0: stopped remote processor cd00000.remoteproc
[1691.546] ath11k b00a040.wifi: failed to submit beacon template command: -108
[1693.230] remoteproc remoteproc0: remote processor cd00000.remoteproc is now up
[1697.594] ath11k b00a040.wifi: failed to send WMI_PDEV_GET_NFCAL_POWER cmd: -108
           ... -108 forever; no pd-1/pd-2 line, no chip_id, no "successfully recovered"
```

A *silent* variant has also been reported from the field: a radio stops, with
**no** fatal interrupt and nothing in the log, and only the survey counter
going flat shows it — which is why the watchdog checks that too. That counter
is a heuristic, not proof. On one live-AP boot (2026-09-06) the QCN6122's
in-use survey entry read `active=149` in all four incidents: before the
first ath11k reset, and again 1.35 h, 7.5 min and 5 min after resets that each
logged `pdev 1 successfully recovered`, until the watchdog rebooted the box;
every `userpd` fatal counter stayed at 0. The same exact value returning is
more like stale data than a random firmware death, and ath11k has two ways to
leave it stale: it marks and refreshes the `[in use]` entry by
`ar->rx_channel`, which it sets only in `add_chanctx` (the channel-switch path
has a `TODO: Update ar->rx_channel`), and it skips the refresh while a scan is
running. Whether the radio was really dead in those incidents is not known.

## Why recovery failed — the bugs that are fixed

**1. The user PD stop waited on dead firmware.** `wcss_pd_stop()` skipped the
SMP2P stop handshake only when *that* user PD was `RPROC_CRASHED`. On a root
fatal the user PDs are still `RPROC_RUNNING`, so the driver asked firmware that
no longer existed for a stop-ack, ate the timeout, and returned early — before
`qcom_scm_msa_unlock()` and before the `rproc_shutdown()` that drops the root
PD's refcount. Fixed by `0821-…`, which skips the handshake while the root PD
is crashed or offline; measured effect: the stop went from `-ETIMEDOUT` after
5 s with the state stuck at `running`, to `rc=0` reaching `offline`.

That measurement was taken while the root PD could not restart. Now that it
can (reason 3), the root is `RUNNING` again by the time anything stops a user
PD, so 0821's check no longer applies: the stop asks the *new* root firmware,
which never spawned that PD, and times out (`pd not stopped`,
`can't stop rproc: -110`). Nothing that used to work broke — before, the radios
stayed dead through reason 2 — but it is why every in-place recovery attempt
after a root-PD assert fails today.

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

With both in place a clean stop and start of the root PD works. Measured with
a host-initiated teardown — `wifi down`, `rmmod ath11k_ahb`, `modprobe` — not
with a crash:

```
after rmmod:  cd00000.remoteproc=offline pd-1=offline pd-2=offline   ready_irq=1
  ROOT+pd-1 RUNNING again after 6s
final:        cd00000.remoteproc=running pd-1=running pd-2=running   ready_irq=2
```

`ready_irq` 1 → 2 is the edge finally being delivered. Both radios come back
and their survey counters advance again, with no reboot. The same fixes are
what let the root PD restart after an assert (the log above) — but see the
next section for why that is not enough.

A footnote on how this was nearly missed: the failed-start path in
`q6_wcss_start()` also unwinds nothing — no `qcom_scm_pas_shutdown()`, no
`qcom_q6v5_unprepare()` — so every retry inherited the previous failure's state
and produced the `Unbalanced enable for IRQ` warning. That made "it fails
identically every time" look like a hardware limit when attempts 2..N were
simply never independent. `0822-` fixes it, and the sibling
`qcom_q6v5_wcss_sec.c` in this same tree already did it that way.

## 4. The datapath was freed while its interrupts were still live

With the restart working, a firmware crash test stopped leaving the radios
dead and started **rebooting the SoC instead** — instantly, before a one-second
sampling loop could take its first reading. The earlier stall had been hiding
this. (The trigger and PD routing of that test were not recorded; see
[the section below](#what-is-still-broken-the-user-pds-are-never-respawned) for
why a root-PD assert alone does not reach ath11k's recovery today.)

`ath11k_core_reset()` calls `ath11k_hif_ce_irq_disable()` before powering the
target down, but the AHB ops never set `ce_irq_enable`/`ce_irq_disable`, so on
AHB that call did nothing: the copy-engine interrupts and their tasklets stayed
live across `rproc_shutdown()`, touching register space that was no longer
there. The result is a null dereference in `ath11k_hal_srng_access_begin()`
from the monitor rings, and a panic. The firmware-crash path
(QMI server exit → `restart_work` → `ath11k_core_reconfigure_on_crash()`)
never disabled them at all.

Fixed by cherry-picking **openwrt/openwrt#24578** (patches `950-` and `953-`;
the PR's own `951-` is renumbered because this tree already has a `951-`).

## What is still broken: the user PDs are never respawned

On a root-PD fatal, `q6v5_fatal_interrupt()` reports the crash of the **root**
rproc only, and the remoteproc core recovers exactly that rproc:
`rproc_boot_recovery()` stops and starts `cd00000.remoteproc`. `pd-1` and
`pd-2` are separate rprocs, not subdevices of the root, and nothing on that
path touches them: they keep reading `running`, the root keeps a power count of
2, and no one sends the new root firmware the spawn request that brings a user
PD up. `q6_wcss_start()` and `q6_wcss_stop()` have no user-PD handling at all.

ath11k does notice the crash: stopping the root's glink subdevice removes the
QRTR node, both radios get a QMI `SERVER_EXIT`, set `CRASH_FLUSH`, and every
WMI command returns `-ESHUTDOWN` (the `-108` flood). Recovery would continue
when the WLAN firmware's QMI server comes back — but that server lives in the
user PD, so it never does. A user PD restarted on its own shows the server
returning within ~100 ms (`pd-2 is now up`, then `chip_id … fw_version`).

What was measured on 2026-09-13, one assert each on the NSS Wi-Fi image, the
same image with `nss_offload=0`, and the v1.8 default build: only the root's
fatal counter moved (`q6v5 fatal` 0 → 1), the root PD came back (1.7 s after
the fatal on the NSS image; `ready=2 handover=2` on v1.8), the `userpd1`/
`userpd2` spawn-ack counters did not move, no `pd-1`/`pd-2` stop or start line
appeared, and ath11k returned `-108` until the box was rebooted. The relevant
kernel sources are identical in the v1.8 and PR #17 trees; as far as the
committed history shows, this never worked.

The same held for a fourth assert on the NSS image at 6.8 min of uptime, done
by hand with the watchdog disabled to test the driver reload
(`soak/wired/H4-premise`): the root PD was back 0.4 s after its stop line, only
the root's counters moved, `wifi down` plus the unload of ath11k took 21 s with
both user-PD stops timing out (`pd not stopped`, `-110`), `pd-1` and `pd-2`
still read `running` afterwards, and 40 s after `insmod` no radio had come
back (no `chip_id` line). The trials asserted between 6.8 and about 32 min after
boot. Whether an assert early in the boot is routed the same way has not been
tested.

An earlier revision of this document showed "the whole chain, working" — both
radios back 1.2 s after an assert. That log cannot come from a root-PD fatal
alone on this code: it starts with `stopped remote processor pd-1`, which only
a stop of the user PDs (or a user-PD fatal) prints, and its 120 ms root restart
is shorter than any measured since (0.4 s and 1.7 s in recovery, 2.3 s cold). But it
was taken at 42 s of uptime, and its counters (`fatal=1 ready=2 handover=2`,
spawn-ack 2 on both user PDs) do show a root fatal plus a respawn. The trigger
and image behind it were not kept. It may have been both user PDs being taken
down while the root was still running, or the firmware routing an early assert
through user-PD fatals alongside the root's — which, for the user, would still
be a root-PD assert that recovered. It is withdrawn as evidence until an
assert at about 40 s of uptime has been run and its counters recorded.

Two more things make the dead state stick:

- **A failed user-PD stop leaks a power reference.** `ath11k_ahb_power_down()`
  ignores `rproc_shutdown()`'s result, and `ath11k_core_reset()` calls
  `power_up` straight after. When the stop times out, `rproc_shutdown()`
  restores the count and `rproc_boot()` then raises it past 1 without booting
  anything. From then on a stop only decrements that count — no stop, no log,
  `0` — and a start only raises it again. Every later `hw-restart`,
  `echo stop/start > /sys/class/remoteproc/remoteprocN/state` and driver
  reload is a silent no-op for that PD, for the rest of the boot. Not fixed.
- **With NSS Wi-Fi offload** (the PR #17 build), in-driver recovery has its own
  failure even without a root-PD fatal: a `hw-restart` took the root PD down
  with a NOC error on the IPQ5018 and left the QCN6122 a zombie, in every trial
  (3 and 2 respectively; with offload off the IPQ5018 recovered in both of 2).
  The leading suspect is shared ring pointers that
  `ath11k_hal_srng_clear()` does not reset for the rings NSS owns, which lets
  the restarted firmware read a stale NSS-written head pointer; it has not been
  confirmed. Candidate patches exist; none is in this tree or benched.

**The pending fix (0823, not in this tree).** Two variants are written against
the patched 6.12.94 `qcom_q6v5_mpd.c` and compile, neither run on hardware
(`CONFIG_QCOM_Q6V5_MPD=y`, so testing needs a kernel image):

- *Minimal:* a root boot generation counter, so stopping a user PD that the
  current root firmware never spawned skips the stop handshake instead of
  timing out. That would let the watchdog's per-PD steps below respawn the
  radios, ~2 min after the assert (detection) plus a few seconds; it does
  nothing on its own, and with NSS offload the `hw-restart` path hits the
  failure above.
- *Full:* tear the user PDs down with the crashed root and respawn them once it
  is back, so the radios recover with no watchdog involvement. The respawn
  still has to move to after glink is started (it currently runs inside the
  root's start, before glink, under the root's lock), and a failed root
  restart is not handled.

## Also fixed: a latent array overflow

`qcom_get_pd_asid()` returns `spawn_bit / 8`, i.e. **1, 2, 3** — never 0. But
`struct q6_wcss` declared `struct userpd *upd[MAX_UPD]` with `MAX_UPD == 3`, so
registering `pd-3` wrote one pointer *past the end of the array*. It stayed
invisible only because `upd[]` was the last member, so the write landed in
allocator slack — it silently corrupts whatever is placed after it. Fixed by
`0819-…`.

## What the port does about it

`/usr/sbin/rd03v2-watchdog` (procd service, `START=99`) is a **backstop**. It
cannot bring back radios whose user PDs are gone — nothing short of a reboot
can today — so for a root-PD assert its job is to notice and reboot, keeping
the evidence. For the cases in-place recovery can fix, it tries that first.

**What it watches**, every 30 s once the boot has settled:

- any of `remoteproc0` / `pd-1` / `pd-2` not `running` for 2 samples (~60 s);
- a radio with no registered phy (~60 s) that either had one when the watchdog
  armed, or is one of the board's two radios and has a `wifi-device` in netifd
  (so firmware that never comes up in a boot is caught too, not overlooked);
- a radio losing all its interfaces while netifd still wants it up (~2 min).
  netifd's view comes from `ubus call network.wireless status`, for every
  `wifi-device` whose `path` names the radio (the most wanted one counts), and
  from `ubus call network.interface dump`. The radio is dropped from the set
  instead when it was taken down on purpose: `wifi down`, `disabled` in
  `/etc/config/wireless`, no enabled `wifi-iface`, or every `wifi-iface` on
  networks that are down (`ifdown`, `auto 0` — netifd leaves those interfaces
  out itself). When netifd has given up setting the radio up
  (`retry_setup_failed`, typically a channel, HE mode, key or country it cannot
  apply) while its survey was still moving at the last sample, that is logged
  once and not acted on; with a flat survey before, it still counts. When
  netifd cannot be asked, the radio counts as wanted. The set is taken once the
  radios have stopped changing for a minute and kept in `/tmp/rd03v2-watchdog/`;
  a radio that shows up later is added. This is what keeps a failed driver
  reload visible: with no phys and no interfaces left, and every rproc still
  reading `running`, the checks above would otherwise have nothing to look at;
- the in-use channel's survey **active time frozen** for 4 samples (~2 min),
  unless the radio's stations are still receiving frames (`rx packets` in
  `iw dev … station dump`, summed over the radio's interfaces, going up; ath11k
  fills that from NSS peer stats too). It is how the silent death shows, and
  the only trigger a root-PD assert trips: afterwards every rproc reads
  `running`. It is a heuristic (see [the failure](#the-failure)): with no
  stations connected, a stale survey entry on a working radio still counts as
  frozen. Incident files record, per interface, the survey value, the station
  frame count, the `[in use]` survey frequency and the channel `iw dev … info`
  reports, so the next such incident can tell a stale entry from a dead radio.

Interfaces are listed from `/sys/class/net/*/phy80211`, and every `iw` call has
a deadline: nl80211 dumps take the rtnl lock, which an unload stuck in
`ieee80211_unregister_hw` holds.

**What it does**, stopping at the first step after which every expected radio
is registered, carries its interfaces and has a moving survey counter:

1. **ath11k reset of the affected radio** (~20 s with the settle time) —
   `hw-restart`, which rebuilds the driver state and restarts that user PD
   without touching the root PD, *when the PD's stop succeeds*.
2. **Stop and start that user PD** (~40 s). A PD that does not reach `offline`
   is not started again: `start` on a running remoteproc only raises its power
   count.
3. **Reload the ath11k driver** (~1–3 min, both radios) — `wifi down`, `rmmod`
   `ath11k_ahb` and `ath11k`, `insmod` them again with the options the box
   booted with (from `/etc/modules.conf` and `/etc/modules.d`, as kmodloader
   applies them, so the NSS Wi-Fi build keeps `nss_offload=1 frame_mode=2`),
   `wifi up`, then the health check by radio, since interface names change
   across a reload. A radio that was stopped with `wifi down radioN` before the
   reload gets no `wifi up` (each other radio gets its own `wifi up radioN`).
   `iw`, `wifi`, `rmmod`, `insmod`, `ubus` and the remoteproc/debugfs writes
   run with deadlines; an unload stuck in the kernel
   ends in step 4 instead of hanging the watchdog. The reload itself has been
   verified on hardware only from a *healthy* driver.
4. **Reboot** (~1 m 47 s).

It **skips straight to the reboot** once a user-PD stop has failed: the kernel
log shows `pd not stopped` or `can't stop rproc` with no later
`stopped remote processor` for that PD (checked before step 1 and after steps 1
and 2), or `pd-1`/`pd-2` is still not `offline` after ath11k has been unloaded
(for when the log has wrapped). Per the leak above, no in-place step can
restart such a PD.

Steps 1 and 2 are skipped when NSS Wi-Fi offload is configured
(`nss_offload=1` in the ath11k options in `/etc/modules.d` — decided from the
configuration, since `/sys/module/ath11k` is gone once the driver is
unloaded), and when ath11k is not loaded at all.

Only the affected radio is touched by steps 1 and 2: a fault on 5 GHz does not
cost 2.4 GHz clients a reset. At most 3 incidents per hour of uptime are
handled in place, however many steps each one takes, so a fault that needs
constant nursing gets a reboot rather than being papered over every couple of
minutes.

What that should mean for each failure on the current kernel — worked out from
the code and the 2026-09-13 logs; this version has not run on hardware:

| failure | expected |
|---|---|
| root-PD assert (7+ min after boot), default build | survey freeze after ~2 min; the `hw-restart` stop times out — 5 s for pd-2 and 16 s for pd-1 in the one logged run, measured on the NSS image; reboot. About 2.5 min plus the reboot. |
| root-PD assert (7+ min after boot), NSS Wi-Fi build | survey freeze after ~2 min; reload; the unload's PD stops time out and the PDs stay `running` (seen by hand at 6.8 min: unload 21 s); reboot with no `insmod`. |
| user PD stopped or crashed, firmware otherwise fine, default build | detected in ~60 s; the ath11k reset restarts it (observed on the bench with an earlier version) |
| user PD stopped or crashed, firmware otherwise fine, NSS Wi-Fi build | detected in ~60 s; steps 1–2 skipped, so a reload of both radios (~1–3 min without Wi-Fi on both) |
| silent death (survey flat, no fatal, no station frames) | steps 1–3 as far as needed (NSS: straight to 3), then reboot |
| survey entry stale on a working radio with stations passing frames | logged once, no action |
| survey entry stale on a working radio with no stations | treated as a silent death (a false positive) |
| radio never registers in a boot | detected in ~60 s once armed (~2 min of uptime); acted on from 10 min of uptime; reboot, and after a watchdog reboot the no-radio reboots (up to 3 in a row) |
| hostapd setup fails after a config change (`retry_setup_failed`) | logged once, no action |
| driver reload left a radio without its phy | detected in ~60 s; reload, or reboot if a PD stop failed |

Before touching anything it writes the evidence to `/overlay/rd03v2-watchdog/`,
one numbered `incident-NNNNNN-up<uptime>.log` per event (pruned to the last 20
at each start): remoteproc states, failed PD stops found in the kernel log, the `q6v5`
IRQ counters (these survive a log wrap and are the best forensic record), the
expected and registered radios, the ath11k `nss_offload` value and boot
options, survey values, meminfo, and the tail of `dmesg`.

**Reboot guards.** None of them uses the wall clock: the box has no RTC and
often no NTP, and its clock can run backwards across a reboot. A reboot the
watchdog requests leaves a marker (`/overlay/rd03v2-watchdog/rebooted`); the
boot that finds it is a *watchdog boot*.

- No reboot within the first 10 minutes of uptime.
- In a watchdog boot, no second reboot before 1 hour of uptime — so a
  persistent fault cannot turn into a boot loop.
- Except when **no radio is serving at all** (no interface whose PDs are
  running and whose survey counter moves): then the 10 minutes suffice, for up
  to 3 such reboots in a row, counted in `/overlay/rd03v2-watchdog/dead-reboots`
  and cleared after an hour of uptime without incidents.
- A reboot that has to wait is remembered: it happens as soon as it may,
  unless the radios are healthy again by then. A failed recovery can no longer
  leave the box without WiFi and without a pending reboot.

**Verification.** The runs on hardware predate this version:

| test | result |
|---|---|
| `pd-2` stopped by hand | detected in ~60 s, healed by ath11k reset, **no reboot** (spawn-ack 26→27) |
| same, checking blast radius | only `phy1-ap0` reset; the 2.4 GHz radio untouched |
| in-place recovery unavailable | falls through to a reboot, as designed |
| root-PD assert, v1.8 default (2026-09-13) | survey freeze caught after ~2 min, in-place recovery failed, reboot; ~3.5 min without WiFi |

An earlier table also listed "real firmware assert: the driver recovers in
~1 s and the watchdog correctly does nothing"; like the withdrawn log above, it
was not reproduced. The current version has been run only against a stubbed
sysfs/procfs with shimmed `iw`, `wifi`, `ubus`, `rmmod`, `insmod` and `dmesg`,
under dash and BusyBox ash (including the OpenWrt target's BusyBox 1.38 under
qemu): the NSS and default escalation paths, a reload failing on
`pd not stopped` and on PDs that stay up with the log wrapped, an assert-like
state where the first `hw-restart` stop fails, a lost phy while every rproc
reads `running`, radios taken down on purpose, an empty radio set, hung
`rmmod` and `iw`, a clock that runs backwards, the reboot limits, two
interfaces on one radio, duplicate `wifi-device` sections, a bridged network
taken down, `retry_setup_failed` with a moving and with a flat survey, a reload
with one radio stopped by hand, radios that never register, and a stale survey
with and without station traffic.

### With the user-PD respawn kernel (0823)

With `qcom_q6v5_mpd.respawn_userpds=1` (patch 0823, in the integration branch)
the kernel restarts pd-1 and pd-2 after a root PD crash, and ath11k recovers
both radios in place in about a second.

An in-place recovery re-installs the stations' keys, but the firmware starts
its transmit packet numbers again from zero. A client that enforces CCMP
replay protection in its own firmware stays associated and drops every frame
from the AP as a replay. It stays deaf until the AP has sent it as many frames
as before the crash. On the bench a BCM43455 (Raspberry Pi 4) stayed deaf
through 50k frames and came back after 150k. A QCA9377 and an RT3070 were not
affected: their drivers skip the check. Setting the counter in the key install
command does not help, the firmware ignores it. ath11k patch 960 therefore
reports every station of a restarted radio as lost when the restart completes,
and hostapd disassociates them (`disassoc_low_ack`, on by default; with it
off the stations stay associated and deaf). They rejoin with fresh keys a few
seconds later. The watchdog used to deauthenticate them itself; 960 replaces
that.

**Known issue: a root PD crash can reset the board on the default build.**
The reset leaves no kernel log. The last line that reaches another host comes
80-150 ms after the fatal error, while the root's crash stop runs. Rates for an
assert of the QCN6122 firmware:

- the first assert of the station test, right after 200k frames to a 5 GHz
  client: 4 of 4 gate runs; the same assert from a fresh boot, 1 of 4;
- asserts taken while the host flooded that client: about 1 in 6;
- the v1.8 image: 0 of 12; the NSS Wi-Fi image: not seen.

It still happened with ath11k at v1.8 (patches 955-963 removed: 1 of 8), so it
comes from the user PD teardown in the root's crash stop, which v1.8 doesn't
have. Every order that powers the internal radio down before `pas_shutdown`
reset the board: with the MSA regions unlocked before or after it, 2 s after
the fatal error, or after the crashed firmware acknowledged a stop request.
With both SCM calls after `pas_shutdown` there was no reset in 14 crashes, but
pd-1 did not come back from the respawn. The crashed firmware likely still runs
until `pas_shutdown`, and faults when the internal radio is powered down under
it. The end result matches the image without 0823: there a root crash leaves
both radios down until the watchdog reboots the board.

The watchdog still has to **notice a suppressed respawn**. 0823 stops
respawning after 6 respawns in an hour, or after a root crash within 60 s of
the last recovery, and logs `respawn suppressed after repeated root PD
crashes`. pd-1 and pd-2 keep reading `running` then, so the remoteproc check is
blind. Only the survey freeze would catch it, after about 2.5 minutes. The
watchdog counts that kernel line too and raises an incident at the next sample.

Hardware results (K1/K2: NSS Wi-Fi build, D2: default build; 2026-09-13/14):

| test | result |
|---|---|
| root-PD assert, respawn on, watchdog armed | kernel respawned both PDs; the watchdog did nothing for 4 min; no incident |
| 7 asserts ~95 s apart, watchdog off | 6 recovered in place; the 7th was suppressed and both radios went dead with every rproc `running` |
| same dead state, then the watchdog (before the suppression check) | survey freeze detected ~2 min after arming; driver reload **recovered** both radios (the first reload from a crashed driver on hardware); clients rejoined |
| assert into suppression, with the suppression check | detected at the next sample (~30 s); driver reload recovered; all 3 clients back |
| assert with a BCM43455 client made deaf by the packet-number reset (K1, watchdog kick) | watchdog deauthenticated 2 + 1 stations; the client came back without traffic |
| 3 asserts (2 through the QCN6122, 1 through the internal radio) and a QCN6122 hw-restart, with 960, watchdog off (K2) | 3, 2, 3 and 3 stations reported lost and disassociated; the BCM43455, QCA9377 and RT3070 clients rejoined and answered ARP every time |
| double crash (an assert, then a root PD crash 100-170 ms after its recovery: respawn suppressed, one or both radios' reconfigure failed), then pd-2 and pd-1 stop/start through sysfs, watchdog off (K2) | Without ath11k 961 (D2 image) the pd-1 start oopsed in `ath11k_core_restart` on the HAL the failed recovery had freed, and panic_on_oops rebooted the board. With 961: no oops in 3 runs, but the radios stayed down, because the retried recovery disabled the interrupts a second time (962). One more run panicked when a WMI command, which mac80211 sent every 6 s, hit the recovery's ring set-up window (963). With 961-963: both radios recovered after the PD restarts and all 3 clients came back |
| the same double crash with the watchdog armed (K2, 3 runs) | suppression detected at the next sample, PD steps skipped (NSS), driver reload cold-booted the root PD: RECOVERED 130-140 s after the crash, all 3 clients back, no reboot |
| double crash, then pd-2 and pd-1 stop/start, default build with 961-963 (D2) | 2/2: no reset, no oops, both radios recovered, all 3 clients back |
| the same double crash with the watchdog armed, default build (D2) | suppression detected, step 1 (ath11k reset of both radios) recovered them: RECOVERED 70 s after the crash, all 3 clients back, no reboot |

Still to check on hardware: a channel switch (CSA, or a DFS channel change) and
a scan on 5 GHz must not leave the `[in use]` survey entry frozen, or if they
do, the incident file shows its frequency differing from the interface's
channel.

To turn it off:

```sh
touch /etc/rd03v2-watchdog.disable   # takes effect on next start; or
/etc/init.d/rd03v2-watchdog disable && /etc/init.d/rd03v2-watchdog stop
```

Disable it before doing any deliberate crash testing or unloading ath11k by
hand, or it will act on it — up to rebooting the box out from under you.

## Diagnosing an event after the fact

```sh
ls /overlay/rd03v2-watchdog/          # incident-NNNNNN-up<uptime>.log per event
grep q6v5 /proc/interrupts            # fatal/ready/stop-ack/spawn-ack counters
for r in /sys/class/remoteproc/remoteproc*; do
        echo "$(cat $r/name) $(cat $r/state)"
done
dmesg | grep -E 'pd not stopped|can.t stop rproc|stopped remote processor|is now up'
```

`q6v5 fatal` incrementing while the `userpd1`/`userpd2` spawn-ack counters do
not is a root-PD assert whose user PDs were never respawned — the radios will
not come back without a reboot. A `userpd1_fatal`/`userpd2_fatal` increment is
a user-PD crash, which goes through the remoteproc core's recovery of that PD
instead (not observed on this board so far). All counters at their boot values
while a radio is dead means the *silent* variant instead.

The box has no RTC and, as an AP, often no reachable NTP server, so the dates
inside incident files can be wrong — `uptime` is recorded alongside them and in
the file name, and is the trustworthy clock.

Recovering by hand after a root-PD assert does not work on a shipped build,
and is worth knowing so you don't chase it: `echo stop >
/sys/class/remoteproc/remoteprocN/state` times out after 5 s or more
(`pd not stopped`, `-110`) with the state still `running`; and once an ath11k
reset has tried and failed, the stop returns at once and does nothing (the
leaked power count). Reboot.
