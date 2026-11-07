# Countries BY, RU, UA and 802.11ax (issue #57)

> TL;DR — with country `RU` and an HE mode, which is this board's default, both radios stay off
> on v2.1.2, and nothing in the log says why. The firmware still carries an old mark from
> Qualcomm's regulatory database that forbids 802.11ax for Belarus, Russia and Ukraine, a mark
> Qualcomm itself removed in 2021. Two changes, not yet in a release, fix this: ath11k patch
> `993` ignores that mark for those three countries, and hostapd patch `994` starts an AP without
> HE wherever a regulatory rule forbids it, instead of leaving the radio off. On a released image,
> `HT20` and `VHT80` bring both radios up without Wi-Fi 6. Whichever you use, the firmware's
> channels and power limits for `RU` stay as they are, and [they go beyond Russia's published
> rules](#channels-and-power-are-not-changed).

## The failure

Reported on v2.1.2, where it happens on every boot with `RU`, and reproduced here on a second unit:

```
hostapd: phy0-ap0: interface state UNINITIALIZED->COUNTRY_UPDATE
hostapd: Failed to set beacon parameters
hostapd: Interface initialization failed
hostapd: phy0-ap0: AP-DISABLED
```

In the reporter's tests, `US` works with the same modules, switching back and forth. The firmware
accepts both countries (status 0 in its regulatory event): `US` is domain `0x16`, country 840, and
`RU` is domain `0x3d`, country 643. NSS Wi-Fi offload makes no difference. In the test VM below, the
same hostapd error comes from `-EOPNOTSUPP`, which hostapd only logs at debug level:

```
nl80211: Beacon set failed: -95 (Operation not supported)
```

## Why

1. Qualcomm's regulatory database marked Belarus, Russia and Ukraine
   `REGULATORY_PHYMODE_NO11AX` in [June 2020][qc2020] ("The following 3 countries will not
   support 802.11ax"). In that database, `ETSI8_WORLD` is `0x3D` and `FCC8_FCCA` is `0x16`, the
   domains the reporter's firmware sent for `RU` and `US`.
2. The firmware passes the mark on in the `phybitmap` of its regulatory event, and ath11k turns
   bit 5 (`NO11AX`) into `NL80211_RRF_NO_HE` on every rule. On v2.1.2 here, `iw reg get` under
   `RU` shows `NO-HE` on every rule of both radios.
3. cfg80211 refuses a beacon with an HE Operation element on such a channel.
4. hostapd does not read the flag, so an HE configuration sends one.
5. This board's default is `HE20` and `HE80`.

So the failure doesn't depend on the unit: it hits anyone on v2.1.2 who sets `RU` and keeps an HE
mode. Earlier releases weren't run. A country left unset never sends the firmware a request. The
channel tests for [#34](regulatory-gb-5ghz.md) included `RU`, but recorded only channel ranges and
power, not the other flags on each rule.

`BY`, `RU` and `UA` are the only countries with the mark. On the module before `993`, this firmware
accepted 196 of the 249 ISO 3166 codes. Those three had `NO-HE` on every rule of both radios, and no
other had it on any rule. Only `RU` was run with an HE mode on that module: the other two should
fail the same way.

### The mark looks out of date

- **Qualcomm took it off.** Regulatory database [v35, of June 2021][qc2021], says "Add 11ax
  support for Russia & Ukraine". The mark for Belarus went in [v37][qc2021b], and newer public
  copies of the database have none left. `WLAN.HK.2.7.0.1-01744`, the newest firmware for these
  chips when [#34](regulatory-gb-5ghz.md) checked, was built on 4 August 2022, but it behaves as
  before v35. Copies on branches without that update ([QSDK][qsdk], [CAF][caf]) still have the
  mark.
- **Russia's rules don't name Wi-Fi standards for these bands.** Annex 2 of GKRCh decision
  07-20-03-001 sets limits for 2400-2483.5, 5150-5350 and 5650-5850 MHz by modulation and power
  ([2018 edition][annex2018], [2023 edition][annex2023]). D-Link's Russian FAQs list 802.11ax
  for [2.4 GHz][faq616] and [5 GHz][faq617]. The other decision the 5 GHz FAQ cites,
  [22-65-05][garant], only adds 5925-6425 MHz for these devices. This is a reading of those
  texts, not legal advice.
- **Belarus and Ukraine are in on Qualcomm's word alone.** They carry the same mark and Qualcomm
  dropped it too, but their national rules were not read here.

wireless-regdb is no evidence either way: its format has no `NO-HE` flag, so no country there
can carry one.

## The fix

**ath11k, patch [`993`][p993].** A table of countries where the firmware's `NO11AX` is ignored:
`BY`, `RU` and `UA`. The firmware still chooses the channels and power limits.

This also changes stations on these countries, which mac80211 otherwise downgrades to VHT on a
`NO-HE` channel: a station that works at VHT today moves to HE after the update. Mesh doesn't
change: mac80211 doesn't check the flag for it, so a mesh on `RU` already advertises HE.

**hostapd, patch [`994`][p994].** hostapd reads `NL80211_FREQUENCY_ATTR_NO_HE`. When the channel
to use has it, HE (and EHT, which needs it) is turned off, and this is logged:

```
phy0-ap0: IEEE 802.11 Regulatory rules do not allow HE (802.11ax) on 2412 MHz: starting without it
```

VHT or HT then run at the configured width. This covers fixed channels, ACS, and DFS channels
(the CAC runs without HE), plus a reload, which reads `ieee80211ax=1` from the file again.
Multiple BSSID, FILS discovery and spatial reuse settings go with it: hostapd refuses the first
two without HE each time the interface is enabled, so an interface that gets disabled, by a DFS
restart for example, could not be enabled again. HE stays configured, and the AP still fails with
an error that says why, on 6 GHz, which requires HE, and for an AP MLD, which requires EHT. A mesh
is left alone: it isn't refused, and mac80211 builds its beacons.

With `993`, `BY`, `RU` and `UA` never reach this fallback, and no other country on this firmware
has the flag. It stays as a safety net for a firmware that marks another country: the radio comes
up, and the log says why.

## What was tested, and what was not

On real radios, a second unit of this board here (`WLAN.HK.2.7.0.1-01744`):

| | Result |
|---|---|
| v2.1.2, unmodified, `RU` with `HE20`/`HE80` | `NO-HE` on every rule of both radios, then the reported failure; the kernel logs nothing |
| v2.1.2, `RU` with `HT20`/`VHT80` | both radios up, no HE on the air |
| v2.1.2, `RU`, a station on 5 GHz to an HE AP | connects at VHT-MCS (the downgrade), 10 of 10 pings |
| The image with `993` and `994`, installed to NAND, on a home `BR` configuration | all 49 configuration files identical to the backup, both radios up (5 GHz after its CAC), HE in the 2.4 GHz beacons |
| The same, `RU` with `HE20`/`HE80`, channels 6 and 100, then 1 and 36 | no `NO-HE`, both radios up, HE and `RU` in the beacons (heard on channels 6, 1 and 36; the receiver is out of range of channel 100) |
| `BY` and `UA` with `HE20`/`HE80`, channels 6 and 100 | no `NO-HE`, both radios up after the CAC, HE and the country in the 2.4 GHz beacons |
| `RU`, a station on 5 GHz to an HE AP | 80 MHz, HE-MCS 3 both ways at -74 to -82 dBm, 30 Mbit/s offered and delivered each way. 6 of 10 pings right after joining, 10 of 10 after the traffic |
| `RU`, a station on 2.4 GHz to an HE AP | HE-MCS 7, 2 streams, on transmit, at -49 dBm. 10 Mbit/s offered and delivered, uplink, and 10 of 10 pings |
| `RU`, a client without HE (a 2.4 GHz 802.11n USB adapter, at about -80 dBm) | connects and passes traffic. The link is weak: 17-40% ping loss and about 1 Mbit/s over three runs, and three runs on `BR` overlap with that |
| `RU` already in the configuration, a reboot, then 15 minutes | both radios up throughout, no `NO-HE`, no fallback warning. On a second such reboot, HE and `RU` in the 2.4 GHz beacons. No client joined in that time |
| `RU`, `txpower` `20` and `23`, through `wifi reload` | the firmware reports 20 and 23 dBm. Nothing was measured on the air |
| `994` alone (v2.1.2's `ath11k.ko` on the image), `RU` with `HE20`/`HE80`, a reboot | the warning above on 2437 and 5500 MHz, both radios up, no HE and `RU` in the 2.4 GHz beacons |
| `994` on v2.1.2 (bound over `wpad`), `RU`, the same 802.11n client at -78 dBm, one run | connects, 5 of 20 pings, no data in 8 s of iperf. The later runs above did better on this link, but this one wasn't repeated and has no comparison |
| v2.1.2's `ath11k.ko` on the image, radios down, each of the 249 ISO 3166 codes | 196 accepted, 53 refused; `NO-HE` on every rule of `BY`, `RU` and `UA`, and on no rule of any other |

No firmware crash and no vdev start error in any of these.

Off target:

| | Result |
|---|---|
| Failure reproduced with hostapd before `994`, on real nl80211 (Debian 6.12, `mac80211_hwsim`, a served `NO-HE` domain) | `-95`, `AP-DISABLED`, both bands |
| The same configuration with `994` | AP up, a client associates, its scan shows no HE, width kept (80/40/20 MHz) |
| ACS, a DFS channel with its CAC, EHT, two BSSes, no country in the configuration, a country change, a reload | as above |
| A stop and start, then a reload, also with multiple BSSID | the AP comes back, no HE |
| `wpa_supplicant` AP mode | fails before `994`, starts without HE with it |
| A mesh with HE | joins and peers, same before and with `994` |
| FILS discovery | the setting no longer reaches the driver. `mac80211_hwsim` has no FILS discovery, so hostapd's refusal of it without HE is read from the code, not tested |
| HE where it is allowed, including turning it on with a reload | unchanged |
| 6 GHz and AP MLD on `NO-HE` | still fail, with the new error |
| The same tests on this tree's cfg80211 and mac80211 (7.2), built for that kernel with small compatibility edits | same results: this cfg80211 also checks beacon updates |
| `993`: the real `ath11k_reg_build_regd()` off target, under ASan and UBSan | `BY`, `RU` and `UA` have no `NO-HE`, other flags kept; `US` and `KZ` with the flag, and `964`'s `GB` rule, unchanged; fails on the code before `993` |
| Both patches apply to the v2.1.2 series without fuzz, and compile with its aarch64 toolchain | no warnings in the changed files |

**Not tested:**

- **A Wi-Fi 6 client on an AP on these countries.** None was at hand. The stations above show the
  firmware running HE peers on `RU`, but in the other role, so the AP side with an HE client is
  still open. A client without HE works.
- **A firmware slower than hostapd.** If the country hasn't changed yet when hostapd asks, it
  waits 5 s and then reads its channel list. If the firmware's rules land later than that, an AP
  in HE keeps running under rules that forbid it, and its beacon updates fail. With `993`, this
  only concerns countries that keep the flag.

## `00`, and two radios with different countries

The first report also had `Failed to set the requested Country regulatory setting` and
`failed to process regulatory info -22` on every boot for several hours after the install, on both
radios, with `RU`, `US` and `00`. Later boots of the same unit return status 0. Here:

- **This firmware refuses `00`**, on both radios, within about 7 ms, which gives exactly those two
  lines. [openwrt#26395](https://github.com/openwrt/openwrt/pull/26395) saw the same on another
  board. The radios keep the rules they had. hostapd rejects `00` as well
  (`Invalid country_code '00'`), and its configuration then fails.
- **It refuses 53 of the 249 ISO 3166 codes the same way:** AO AQ BI BJ BQ BV BW CC CD CG CU CV DJ
  EH ER FJ GA GM GN GQ GS GW IO IR KG KI KM KP LA LR LY MG ML MZ NE NR PN PS SB SC SD SL SO SS SY
  SZ TJ TK TL TM TO TV ZM. What an AP then does on one of those was not tested.
- **`RU` and `US` alone never produced those lines here.**
- **The radios share one country.** Each radio's `country` goes to the firmware in turn, and
  hostapd uses the last. With `00` on radio 0 and `RU` on radio 1, you get those kernel lines and
  the beacon failure in one `wifi up`, which looks just like the first report.

That would explain the first report, if `00` was on one of the radios at the time, but nobody
knows that it was. Neither patch here touches that check. Don't use `00` on this board, and set
the same country on both radios.

## Channels and power are not changed

`993` removes only the HE mark, and this is deliberate: channels and power stay the firmware's.
For `RU`, they go beyond the published rules. They were always in effect for anyone running `RU`
without HE. After `993`, a default configuration runs under them too, where it used to stay off.

| | This firmware, from `iw reg get` | Annex 2, [2023 edition][annex2023] | wireless-regdb |
|---|---|---|---|
| 2.4 GHz | 2402-2482 MHz, 33 dBm | 2400-2483.5 MHz, 100 mW EIRP (20 dBm), 10 mW/MHz | 2400-2483.5 MHz, 100 mW |
| 5 GHz | 5170-5250 MHz, 30 dBm | 5150-5350 MHz, 200 mW EIRP (23 dBm), 10 mW/MHz, indoors, listen-before-talk | 5150-5350 MHz, 100 mW, indoors |
| 5 GHz | 5250-5330 MHz, 23 dBm | as above | as above |
| 5 GHz | 5490-5730 MHz, 30 dBm | nothing below 5650 MHz | nothing below 5650 MHz |
| 5 GHz | 5735-5835 MHz, 30 dBm | 5650-5850 MHz, 200 mW EIRP (23 dBm), 10 mW/MHz, indoors, listen-before-talk | 5650-5850 MHz, 200 mW, indoors |

Also on `RU`:

- **No radar detection.** The firmware reports `DFS-UNSET` and no `DFS` flag on any rule, so
  channel 100 starts at once, with no CAC. Annex 2 doesn't ask for it.
- **Channels 100 to 128** are outside what Annex 2 lists.
- **The radios use most of that power.** With no `txpower` set, `iw` reports 30 dBm on 2.4 GHz and
  28 dBm on 5 GHz.

Annex 2's limits are EIRP, which includes antenna gain, with 10 mW/MHz as well. `txpower` sets the
firmware's limit, and `iw` shows the firmware's figure. This board's antenna gain isn't known here,
and nothing was measured on the air, so treat these as a ceiling to start from, and subtract your
antenna gain. Pick a channel from Annex 2's ranges too:

```
uci set wireless.radio0.txpower='20'
uci set wireless.radio1.txpower='23'
uci commit wireless
wifi reload
```

`BY` and `UA` keep the firmware's rules too (`DFS-ETSI`, with radar detection). `iw reg get` shows
what your firmware applies, and a radio's own rules can differ from a country's table
([the 2.4 GHz note for GB](regulatory-gb-5ghz.md#related-not-fixed-here-24-ghz-power-in-etsi-countries)).
Choosing a legal channel and power remains your responsibility, so check them against the rules
where you are.

## On a released image

```
uci set wireless.radio0.htmode='HT20'
uci set wireless.radio1.htmode='VHT80'
uci commit wireless
wifi reload
```

This keeps `RU` and brings both radios up without Wi-Fi 6, confirmed on v2.1.2. Don't use another
country's code instead: the AP would advertise the wrong country and use that country's channels
and power limits.

[qc2020]: https://github.com/sonyxperiadev/vendor-qcom-opensource-wlan-qca-wifi-host-cmn/commit/f682392d3e28
[qc2021]: https://github.com/sonyxperiadev/vendor-qcom-opensource-wlan-qca-wifi-host-cmn/commit/ea1b24f9e5d7
[qc2021b]: https://github.com/sonyxperiadev/vendor-qcom-opensource-wlan-qca-wifi-host-cmn/commit/a4ba2f1844b7
[qsdk]: https://github.com/FanFansfan/qsdk-5.4/blob/HEAD/qca/src/qca-wifi/cmn_dev/umac/regulatory/core/src/reg_db.c
[caf]: https://github.com/arter97-mirror/caf_qca-wifi-host-cmn/blob/HEAD/umac/regulatory/core/src/reg_db.c
[annex2018]: https://www.dlink.ru/up/support/FAQ/Wireless/PDF/Reshenie_GKRCH__07-20-03-001.pdf
[annex2023]: https://meganorm.ru/mega_doc/dop_norm_update_01032025/gost_r_71779-2024_natsionalnyy_standart_rossiyskoy/0/reshenie_gkrch_pri_mininformsvyazi_rossii_ot_07_05_2007_N.html
[faq616]: https://www.dlink.ru/ru/faq/111/616.html
[faq617]: https://www.dlink.ru/ru/faq/111/617.html
[garant]: https://base.garant.ru/406192695/
[p993]: ../overlay/package/kernel/mac80211/patches/nss-extra/ath11k/999-999-rd03v2-993-wifi-ath11k-ignore-the-no-11ax-mark-Qualcomm-dropped-from-its-regdb.patch
[p994]: ../overlay/package/network/services/hostapd/patches/994-ap-start-without-he-where-regulatory-rules-forbid-it.patch
