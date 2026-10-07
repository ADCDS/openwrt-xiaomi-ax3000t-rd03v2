# UK 5.8 GHz channels and the firmware's regulatory database (issue #34)

> TL;DR — with country `GB` the 5 GHz radio disables channels 144-177 and an
> AP configured on 149-165 never comes up. The UK permits 5725-5850 MHz for
> Wi-Fi indoors at 200 mW, and wireless-regdb says so, but ath11k takes its
> channel list from the regulatory database compiled into the Q6 firmware.
> `WLAN.HK.2.7.0.1-01744`, the newest IPQ5018/QCN6122 firmware, puts GB in the
> same ETSI domain as the EU, which stops at 5710 MHz. Patch `964` adds the UK
> band on top of the firmware's rules. Verified on the bench against v1.12:
> with the patch, an AP on channel 149 at 80 MHz comes up under `GB` at
> 23 dBm, carries traffic, and advertises 149-165 in its Country element.

## The failure

Reproduced on the bench on 2026-10-07 with v1.12 (`r35297-25ee12629e`, NSS
Wi-Fi image), the OpenWrt revision in the report. Country `GB` set on both
radios:

```
phy#1 (self-managed)
country GB: DFS-ETSI
	(2402 - 2482 @ 40), (N/A, 20), (N/A)
	(5170 - 5250 @ 80), (N/A, 23), (N/A), NO-OUTDOOR, AUTO-BW
	(5250 - 5330 @ 80), (N/A, 23), (0 ms), NO-OUTDOOR, DFS, AUTO-BW
	(5490 - 5590 @ 80), (N/A, 30), (0 ms), DFS, AUTO-BW
	(5590 - 5650 @ 40), (N/A, 30), (600000 ms), DFS, AUTO-BW
	(5650 - 5710 @ 40), (N/A, 30), (0 ms), DFS, AUTO-BW
	(6045 - 6425 @ 160), (N/A, 21), (N/A), NO-OUTDOOR, AUTO-BW

* 5720 MHz [144] (disabled)
* 5745 MHz [149] (disabled)
  ... 153, 157, 161, 165, 169, 173, 177 all (disabled)
```

These are the reporter's rules exactly. With `channel 149` the 5 GHz AP does
not fall back to another channel. It is not started at all:

```
hostapd: Frequency 5745 (primary) not allowed for AP mode, flags: 0x1
hostapd: phy1-ap0: IEEE 802.11 Configured channel (149) or frequency (5745) (secondary_channel=1) not found from the channel list of the current mode (2) IEEE 802.11a
hostapd: Could not select hw_mode and channel. (-3)
hostapd: phy1-ap0: AP-DISABLED
```

A scan from a second machine (hal, QCA9377) sees only the 2.4 GHz BSS.
Switching the same configuration to `US` brings the AP up on 149 at 80 MHz,
seen by hal at 5745 MHz and -36 dBm, so the radio and the board data are
fine. Only the regulatory rules differ.

## Why: the rules come from the firmware

ath11k registers its wiphys as self-managed (`REGULATORY_WIPHY_SELF_MANAGED`).
When hostapd sets a country, ath11k passes the code to the firmware
(`WMI_SET_INIT_COUNTRY`), the firmware looks it up in its own database and
answers with `WMI_REG_CHAN_LIST_CC`, and ath11k turns those rules into the
`phy#N (self-managed)` block above. wireless-regdb (the `global` block) does
not enter into it. OpenWrt's `905` patch already removed the intersection with
the board's default country, so nothing else narrows the rules either.

Setting 66 countries in turn on the bench (`iw reg set XX`, reading the
`phy#1` block) shows the firmware's grouping:

| firmware 5 GHz rules | countries |
|---|---|
| 5170-5330 and 5490-5710 MHz, nothing above | GB, IE, FR, DE, NL, BE, LU, ES, PT, IT, AT, CH, LI, NO, SE, DK, FI, IS, PL, CZ, SK, HU, RO, BG, GR, HR, SI, EE, LV, LT, MT, CY, TR |
| 5490-5730 MHz plus 5735-5855/5875 MHz at 14 dBm | AE, IL, KE |
| 5.8 GHz at 20-33 dBm | US, CA, MX, BR, AR, CL, CO, PE, AU, NZ, IN, CN, HK, TW, SG, MY, TH, PH, VN, ID, KR, UA, RU, SA, QA, ZA, NG, PK |
| no 5.8 GHz | JP, EG |

GB gets nothing the EU does not. The firmware's tables can be listed without a
router: [`tools/ath11k-fw-regdb.py`](../tools/ath11k-fw-regdb.py) finds the
5 GHz rule and domain tables in the Q6 image (they sit in each user PD's data
segment, `q6_fw.b10`/`b17`/`b22`) and decodes them. GB's rules are domain
`0x0e`:

```
domain 0x0e  ETSI dfs=ETSI    5170-5250/23/INDOOR 5250-5330/23/RADAR|INDOOR 5490-5710/30/NO_IR
```

None of the 50 non-empty domains is the UK's: the ETSI ones with 5.8 GHz
are the 14 dBm short-range-device allowance (`0x16`, AE and KE) or other
countries' 20-33 dBm rules. The UK rule is Ofcom IR 2030's band C:
licence-exempt RLANs in 5725-5850 MHz, indoors, up to 200 mW EIRP, without
DFS. wireless-regdb adopted that IR 2030 update in June 2021 (`42dfaf4`,
"update 5725-5850 MHz rule for GB"):

```
country GB: DFS-ETSI
	(5725 - 5850 @ 80), (200 mW), NO-OUTDOOR
```

Nothing in this tree can change what the firmware returns:

- **No newer firmware.** `WLAN.HK.2.7.0.1-01744` (built 2022-08-04) is the
  newest IPQ5018/QCN6122 build in Qualcomm's upstream-wifi-fw repository; the
  others are older 2.5/2.6 builds.
- **Not the board data.** The BDF holds calibration, CTL power tables and a
  default country. The country-to-rules map is compiled into Qualcomm's Q6
  image, and changing it would mean shipping a patched vendor binary.

## The fix: patch 964

[`964-wifi-ath11k-add-the-UK-5.8-GHz-band-missing-from-the-fw-regdb.patch`](../files/package/kernel/mac80211/patches/ath11k/964-wifi-ath11k-add-the-UK-5.8-GHz-band-missing-from-the-fw-regdb.patch)
adds a small table of bands a regulator permits and the firmware database
omits, and appends a matching entry to the rules ath11k builds from the
firmware event. The entry applies only:

- for its country (the alpha2 the firmware reports back),
- on a radio whose firmware rules include 5 GHz (the 2.4 GHz IPQ5018 radio is
  untouched),
- where no firmware rule overlaps it, so a firmware that learns the band
  later wins.

The only entry is the wireless-regdb rule for GB: 5725-5850 MHz, 80 MHz,
23 dBm EIRP, NO-OUTDOOR. Everything else the firmware reports is kept as is,
including its DFS ranges and power limits.

Left out on purpose:

- **EU 5725-5875 MHz at 25 mW.** wireless-regdb carries this short-range-
  device allowance for EU countries and the firmware omits it there too. At
  14 dBm it is a much weaker channel set that ACS and users would pick up
  everywhere in Europe. That is a separate decision from the 200 mW band the
  UK permits.
- **Channel 144 in GB.** wireless-regdb allows 5470-5730 MHz; the firmware's
  ETSI DFS rule stops at 5710. Adding it would put a DFS channel outside the
  firmware's radar rules, for one channel.

## Validation

**Rule building, off target.** The patched `ath11k_reg_build_regd()` was
compiled into a userspace harness under AddressSanitizer and UBSan and fed the
rules the firmware sends for GB. It reproduces the bench's `iw reg get`
exactly (including the weather-radar split) and appends
`5725-5850 @ 80, 23 dBm, NO-OUTDOOR` as the eighth rule, within the
allocation. With no 5 GHz rules (the 2.4 GHz radio), for DE and US, and for
a firmware that already reports 5735-5835 for GB, nothing is added.

**On the bench (2026-10-07).** The test isolates the patch on the v1.12
image itself. This tree was configured as the v1.12 NSS Wi-Fi release was
built (`KMODS=1 NSS=1`, pinned donor): the kernel vermagic came out
`b8b357d59665e168c40d5dd63a78dd3b`, the bench's, and the unpatched
`ath11k.ko` byte-identical to the installed one (md5 `128b8b99…`). The build
with 964 was loaded in its place on the running bench (`wifi down`,
`rmmod ath11k_ahb ath11k`, `insmod`, `wifi up`). A reload of the stock module
the same way was clean first. The configuration was the same for both runs:
country `GB` on both radios, 5 GHz on channel 149, HE80.

| | v1.12 | v1.12 + 964 |
|---|---|---|
| GB rules above 5710 MHz | none | `(5725 - 5850 @ 80), (N/A, 23), NO-OUTDOOR` |
| channels 149-165 | disabled | enabled, 23 dBm |
| channels 144, 169-177 | disabled | disabled |
| 5 GHz AP on 149 | `AP-DISABLED`, "not allowed for AP mode" | `AP-ENABLED`, 80 MHz, txpower 23 dBm |
| seen from hal | 2.4 GHz BSS only | 5745 MHz, -40/-41 dBm, Country `GB` with `[149 - 165] @ 23 dBm` |

With 964, hal (QCA9377, 1x1) associated on 149 at 80 MHz and
answered 30 of 30 pings (4 ms average). Three 8 MB HTTP downloads from the
router ran at about 24 MB/s at VHT-MCS 9, with no retries or failures. The
firmware started the vdev on 5745 MHz without an error, and it applies the
lower host limit: on the same channel hal measured -34/-36 dBm with `US`
(28 dBm) and -40/-41 dBm with `GB` (23 dBm).

With the patched module, `US` on 149, `BR` on 36 and `GB` on 36 behaved as
before: the firmware's own rules, plus the 5725-5850 MHz rule for GB only.
Raw output is in
[`stock-investigation/captures/issue34-gb-5ghz-bench.txt`](../stock-investigation/captures/issue34-gb-5ghz-bench.txt).

When a firmware with the UK band ships, its rule overlaps the table entry
and the entry stops applying. `tools/ath11k-fw-regdb.py` shows whether a new
firmware has it, before anyone removes the entry.

## Related, not fixed here: 2.4 GHz power in ETSI countries

The IPQ5018's own firmware rules for the 2.4 GHz radio come back as
`(2402 - 2482 @ 40), (N/A, 33)` for GB, DE and FR (30 dBm for BR), and that
AP runs at 30 dBm txpower in those countries. The QCN6122 firmware reports
20 dBm for the same band and country, which is the ETSI limit. This is the
stock v1.12 module, unaffected by 964. Whether the board data's ETSI CTL
holds the radiated power down was not measured.
