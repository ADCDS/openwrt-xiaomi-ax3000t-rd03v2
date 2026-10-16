# In-place user-PD reload experiments (not shipped)

None of these is in `v2/overlay`, and `v2/build.sh` does not apply them. They are the
patches behind the local diagnostic candidates b10d1-b10d6, kept so the experiment can be
repeated. They tried to reload one user PD on the root PD that had run it. What the shipped
v2 does instead is v1.x's sequence: restart the root PD and spawn the user PDs on the fresh
one (overlay 975), in host Wi-Fi mode; with NSS Wi-Fi offload a Q6 crash is recovered by the
watchdog reloading ath11k (978). None of the patches here is needed for either.

| patch | applies to | what it does |
|---|---|---|
| `0919-private-qcom-userpd-secure-reload.patch` | kernel (`patches-6.18`) | ASID-scoped PAS segment reload of one user PD in `qcom_q6v5_wcss_sec.c`, MSA lock/unlock calls (a no-op on IPQ5018), root boot generation helpers for ath11k |
| `0921-private-qcom-mdt-load-the-whole-segment-securely.patch` | kernel, after 0919 | loads `p_memsz` through the secure loader so a reloaded PD gets a cleared bss (a host memset of that memory resets the board, see `rejected/`) |
| `999-999-rd03v2-970-…-transition-trace.patch` | ath11k | `rd03v2 userpd trace:` info lines around every user-PD transition |
| `999-999-rd03v2-971-…-v1-order-experiment.patch` | ath11k, after 970 | re-arms the completions and powers the IPQ5018 radio on after the ready ack, as v1's remoteproc did |
| `999-999-rd03v2-972-…-secure-reload.patch` | ath11k, after 971 | carries stop failures into power-up and reloads the PD through 0919 before spawning it |
| `973-stacked-on-970-972-…` | ath11k, after 972 | the first form of the stop-handshake skip; the shipped form is `999-999-rd03v2-973` in the overlay, written against the clean `ahb.c` |
| `974-mac80211-…-superseded.patch` | mac80211 | released pending ack frames in `ieee80211_unregister_hw()`; superseded by the ath11k fix `999-999-rd03v2-974` in the overlay, which reports the in-flight frames where ath11k drops them |

What the experiment showed: with 0919 + 0921 + 970-972
a `hw-restart` reloads the PD (all four segments through the secure loader, the PD acks its
spawn), but the root PD then takes a fatal error and the reloaded PD never registers its QMI
service again. That is a limit of this tree's direct SMP2P user-PD path plus these patches,
not of the firmware: v1.x, with the same WLAN.HK.2.7.0.1-01744 firmware and its
`qcom_q6v5_mpd` user-PD remoteprocs, did recover in place (docs/q6-firmware-crash.md), by
restarting the root PD first - which is what 975 does in ath11k_ahb.
