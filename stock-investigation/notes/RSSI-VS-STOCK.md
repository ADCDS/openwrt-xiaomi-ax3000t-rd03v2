# Did we actually fix the RSSI reporting? (issue #3, measured against stock)

Short answer: **the noise floor is fixed, 2.4 GHz is fixed, and 5 GHz now
over-reports by about 8 dB.** The ~31 dB "deaf receiver" is gone on both bands —
patch `952` was the right diagnosis — but the QCN6122 half of it looks
over-corrected.

This is the first time the fix has been checked against stock on the same
silicon rather than against an external reference.

Raw data and full derivation: `captures/rssi-reciprocity.txt`.

## What was being tested

`952-wifi-ath11k-fix-rx-signal-reporting-on-IPQ5018-QCN6122.patch` (shipped since
v1.5, present in v1.8) does two things:

- adds a per-`hw_rev` signal offset at every dB→dBm reporting site:
  **+31 dB for IPQ5018** (2.4 GHz) and **+24 dB for QCN6122** (5 GHz);
- implements the dormant `WMI_PDEV_GET_NFCAL_POWER` exchange and reports the
  firmware's calibrated per-channel noise floor instead of the generic
  `ATH11K_DEFAULT_NOISE_FLOOR`.

## Method: link reciprocity

Comparing two APs in different rooms cannot be done by putting a client next to
each — the path losses differ. Radio links are reciprocal, though, so path loss
cancels within a single AP↔client pair. For one link, in dB:

```
A = AP's reported RSSI of the client = P_client + G + off_ap
B = client's reported RSSI of the AP = P_ap     + G + off_client
D = A - B                            = P_client - P_ap + off_ap - off_client
```

Using the **same client** for both APs, `P_client` and `off_client` cancel:

```
off_v18 - off_stock = (D_v18 - D_stock) + (P_v18 - P_stock)
```

Reference client: **hal**, an ath9k card, fixed position, measured against all
four BSSes. Its TX power was pinned with `iw ... set txpower fixed` after
association, because the regulatory ceiling `iw` reports follows whatever the AP
advertises — it read 20, 23 and 30 dBm across the four BSSes, which would have
silently broken the algebra. Control was validated first: commanding 5 vs 15 dBm
moved the AP-side RSSI by a repeatable ~6.5 dB.

`tiny` (RPi4, brcmfmac43455) was evaluated and rejected: it hears stock's 2.4 GHz
at −7 dBm (receiver compression) and cannot hear the v1.8 AP's 5 GHz BSS at all,
so it cannot complete the 5 GHz pair.

## Results

| link | A (AP sees hal) | B (hal sees AP) | D | AP TX |
|---|---:|---:|---:|---:|
| stock 2.4 GHz ch6 | −57 | −48 | −9 | 30 dBm |
| v1.8 2.4 GHz ch11 | −60 | −51 | −9 | 27 dBm |
| stock 5 GHz ch48 | −67 | −81 | +14 | 28 dBm |
| v1.8 5 GHz ch149 | −45 | −67 | +22 | 28 dBm |

```
2.4 GHz:  off_v18 - off_stock = ( -9 -  -9) + (27 - 30) = -3 dB
5 GHz  :  off_v18 - off_stock = ( 22 -  14) + (28 - 28) = +8 dB
```

An earlier pass with hal's TX left at the regulatory ceiling — a different and
partly invalid experiment — gives **0 dB** and **+8 dB**. The 5 GHz result is the
same in both passes; the 2.4 GHz result brackets 0 to −3 dB.

### Noise floor — fixed, and this needs no assumptions

The noise floor is an absolute reading, so it is immune to every TX-power
question above:

| | stock | v1.8 | pre-patch |
|---|---:|---:|---:|
| 2.4 GHz | −96 dBm | −98 dBm | −110 dBm |
| 5 GHz | −91 dBm | −90 dBm | −113 dBm |

Within 2 dB and 1 dB of stock, from −14 and −22 dB out. Note the two arrive there
by different routes: stock reports a *board-data averaged* value (`iwconfig` says
so in as many words: "BDF averaged NF value in dBm"), while ours is the
firmware's calibrated per-channel `GET_NFCAL_POWER` answer. **The
`GET_NFCAL_POWER` half of patch 952 is confirmed correct against stock.**

### Sanity check on the absolute numbers

Stock, capture host's USB dongle at ~1.5 m on 2.4 GHz: `RSSI −28 dBm, SNR 68,
NF −96` — internally consistent (−96 + 68 = −28), and the dongle reported −23 dBm
for stock in the other direction. Our v1.8 AP reports its own live clients at
−46/−50/−56 dBm with acks at −36/−56. Both are in the range a working receiver
produces; neither shows anything like the old −85 dBm-for-an-in-room-client
behaviour.

## Reading the result

**2.4 GHz (IPQ5018, +31 dB): fixed.** 0 to −3 dB against stock, inside the
measurement error, and the residual is exactly the size of the declared TX-power
difference whose convention is unverified (below). Nothing to do.

**5 GHz (QCN6122, +24 dB): reads about 8 dB hot.** Reproducible across two
independent passes. If that holds, the constant should be nearer **+16** than
+24. I would not change it on this evidence alone — see the caveats — but it is
worth a deliberate re-measure.

Interesting corroboration for the 5 GHz number being real rather than noise:
**the band that agrees is the band where the two APs run the same channel
width.** Stock's 2.4 GHz is 20 MHz and ours is HE20 — matched, and they agree.
Stock's 5 GHz is **160 MHz on ch48** while ours is **80 MHz on ch149** — and that
is the band that disagrees. RSSI is an energy measurement; a driver that scales
it by receive bandwidth would produce exactly this kind of band-specific offset.

## Caveats that matter before anyone changes the constant

1. **Channel width is confounded with the result.** 160 MHz vs 80 MHz, as above.
   This is the single most likely explanation for the 8 dB and it is *not*
   controlled for. Matching the widths requires reconfiguring one of the two
   boxes — a flash write on the bench unit (against this investigation's ground
   rules) or a config change on the in-service AP.
2. **Per-chain vs total EIRP is unverified.** Both radios are 2×2. If one driver
   reports per-chain and the other total, every comparison involving unequal
   declared powers moves by 3 dB. It cancels for 5 GHz only if *both* use the
   same convention, which is assumed and not shown.
3. **The stock 5 GHz link was weak** — hal at −81 dBm, ~16 dB SNR. That is inside
   ath9k's linear range but it is the worst link in the set. hal's chain 1 also
   reads a constant −73 dBm on every band and is probably dead; only combined and
   beacon-average values were used.
4. **Direction is not established.** "Ours reads 8 dB above stock" could equally
   be stock reading 8 dB low on 5 GHz. Stock's 2.5-era firmware was taken as the
   reference in issue #3; this measurement does not independently re-verify that.

## The definitive test

Put a v1.9 build on the **bench** RD03v2 once this stock investigation is
finished, configured to stock's exact channel and width (ch48, 160 MHz), and
repeat the reciprocity measurement with the same client. Same silicon, same
antennas, same room, same width — every confound above disappears, and the
residual is the offset error. That is a far better experiment than anything
possible with two boxes in two rooms.

---

## Separately: TX power, the other kind of loudness

The question "are the antennas loud enough" also has a transmit side, and it is
worth recording what each box actually asks for:

| | stock | v1.8 | BR regulatory ceiling |
|---|---:|---:|---:|
| 2.4 GHz | 30 dBm | **27 dBm** | 30 dBm |
| 5 GHz (ch149) | 28 dBm (ch48) | **28 dBm** | 30 dBm on 5725–5850 |

- **Stock ignores the cfg80211 regulatory domain.** Its `iw reg get` reads
  `country 00: DFS-UNSET` with 20 dBm limits everywhere, while the QSDK driver
  transmits at 30 and 28 dBm from its own board data and `bdata CountryCode=CN`.
  Ours honours `country BR` properly. That is a compliance difference, not a bug
  on our side — stock is the one behaving badly.
- **On 2.4 GHz we ask for 27 dBm where BR allows 30.**
- **On ch149 we ask for 28 dBm where BR allows 30**, because ch149 sits in the
  5725–5850 block that BR permits at 30 dBm.

Both gaps are worth **checking**, not blindly raising: if ath11k reports
per-chain and the radio is 2×2, 27 dBm per chain already *is* 30 dBm EIRP and
there is nothing on the table. Resolving the per-chain-vs-total question
(caveat 2) settles the reporting comparison and this at the same time — it is the
highest-value follow-up here, and it is a code-reading exercise, not a bench one.
