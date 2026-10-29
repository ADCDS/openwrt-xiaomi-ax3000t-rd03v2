# OpenWrt for Xiaomi AX3000T (RD03v2)

OpenWrt for the **RD03v2 hardware revision** of the Xiaomi AX3000T: Qualcomm IPQ5018 with a
QCN6122 5 GHz radio, 256 MB RAM and 128 MB NAND. It installs permanently on NAND and
supports all four Ethernet ports, both Wi-Fi bands, the status LED, the NFC tag and LuCI,
with Qualcomm NSS hardware offload for routing and Wi-Fi.

**RD03v2 only.** The MediaTek RD03/RD23 revisions use different hardware and incompatible
firmware. Check your hardware revision before flashing.

The image is a pinned commit of
[kuncy7/openwrt-nss-edma](https://github.com/kuncy7/openwrt-nss-edma) (kernel 6.18, NSS on
mainline stmmac; v2.1.0 pins his branch head of 2026-10-27, after his `ipq50xx-2026.10.23`) with [this port's additions](docs/what-this-port-adds.md) on top, and
OpenWrt's own snapshot package feeds. Releases are on the
[releases page](https://github.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2/releases); what was
tested on hardware, and what was not, is in [VALIDATION.md](VALIDATION.md).

## Installation

- **From stock firmware:** run `python3 install.py` from
  [xiaomi-openwrt-install](https://github.com/ADCDS/xiaomi-openwrt-install). It installs the
  latest release over Ethernet or Wi-Fi **without opening the case or connecting UART**,
  validates the board and NAND, and verifies the images it writes. Its `--wifi-ssid`,
  `--wifi-key`, `--wifi-country` and `--root-password` options set up the installed system.
- **From an installed OpenWrt, v1.x included:** boot the release's RAM installer and run
  `sysupgrade` from there, never in place ([updating without UART](docs/no-uart-reflash.md)).
  Keeping settings carries a v1.x configuration over ([upgrading from v1.x](docs/upgrading-from-v1.md)).
- **Back to stock:** `revert.py` from xiaomi-openwrt-install.

## After installing

- Connect to a LAN port and open **http://192.168.1.1** for LuCI. Set a root password.
  Wi-Fi stays off until it is configured, unless the installer was given Wi-Fi settings.
- **Every flash, including updates, runs from the RAM installer.** `sysupgrade` from the
  installed NAND system is refused.
- Packages: `apk update`, then `apk add <package>`. Userspace comes from OpenWrt's snapshot
  feeds; kernel modules (`kmod-*`) and AmneziaWG come from this port's signed repository for
  the release ([packages](docs/packages.md)). A sysupgrade keeps the configuration but not
  added packages: add them again afterwards.
- The first boot clears the NFC tag, which still holds the Wi-Fi name and password stock
  last wrote to it. To share a network by tapping a phone, see [NFC tag](docs/nfc.md).

## Known issues

- **802.11s mesh needs host Wi-Fi mode** (`nss.general.wifi_offload='0'`). With NSS Wi-Fi
  offload on, a mesh interface does not come up and takes its radio's AP down until it is
  removed. v2.0.0 resets in host mode whenever a device connects: use v2.0.1 or later (#47).
  Host Wi-Fi mode leaves less memory free: under sustained Wi-Fi traffic about 20 MB less
  than NSS mode (20-26 MB available on the bench, against 40-42).
- **From v2.1.0 a client (station) interface stays on the NSS path**, also on an upgrade
  from v2.0.1 or v2.0.2, which put Wi-Fi in host mode whenever a station existed. On this
  base a station sends full-size frames against HE and HT-only APs (#48 no longer
  reproduces); a VHT-only (Wi-Fi 5) 5 GHz AP was not tested. `nss.general.wifi_offload_sta='0'`
  (or `off`) keeps Wi-Fi on the host path while one is configured, from the next boot;
  `nss-status` says when a reboot is needed.
- **On v2.0.0 to v2.0.2, routed UDP into a Wi-Fi client can crash the Wi-Fi firmware in host
  Wi-Fi mode** (#52): a station on v2.0.1 and v2.0.2, or `nss.general.wifi_offload='0'`.
  YouTube over QUIC did it within seconds on 5 GHz. ECM gave reply packets an uninitialised
  priority, which the driver passed on as an invalid traffic ID. Fixed in v2.1.0; on an older
  release, `echo 0 > /proc/sys/net/ecm/unidir_accel_en` avoids it and keeps wired offload
  until the next reboot (put it in `/etc/rc.local` to keep it).
- **On v2.0.0 to v2.0.2, a Wi-Fi client that sends fragmented frames can stop its radio**
  (#53): after 63 received 802.11 fragments that radio receives nothing more, its clients
  drop off and cannot rejoin, and its memory runs out over the following days. Few clients
  ever fragment; a v2.0.2 AP stopped after 42 hours. Only a reboot clears it. Fixed in
  v2.1.0. With NSS Wi-Fi offload (the default) fragments are reassembled normally (tested on
  2.4 GHz; the 5 GHz radio gets the same setting, no fragmenting 5 GHz client was
  tried). In host Wi-Fi mode the radio no longer stops, but most fragmented frames are lost
  (large ones entirely).
- **With NSS Wi-Fi offload, reloading the Wi-Fi driver breaks Wi-Fi until a reboot**: the radios
  come back, but no client or station completes the WPA handshake on either radio, with or
  without a station configured. The
  watchdog reloaded the driver as a recovery step on v2.0.0 to v2.0.2; from v2.1.0 it reboots
  instead with offload on. Do not `rmmod`/`modprobe` ath11k by hand with offload on; host Wi-Fi
  mode reloads cleanly.
- **A pairwise key rekey reconnects the client** (`wpa_deny_ptk0_rekey`, default 1, #49).
  Neither radio can replace the key in place: as an AP, a rekey stalled traffic for 16-31 s
  and ended in a deauthentication. With the option the client reconnects instead, in about a
  second. As a client of an AP that rekeys, the router reconnects by itself, in about 5 s,
  instead of waiting for the AP to give up on the handshake.
- **On v2.0.0 and v2.0.1, every LuCI login leaks about 175 KiB of `rpcd` memory** (json-c
  0.19, #50), until `rpcd` restarts. Fixed in v2.0.2.
- **The CPU runs at up to 1296 MHz** (from v2.1.0, kuncy7's change), 29 % above the IPQ5018's
  rated 1008 MHz at the same fixed voltage, and about 25 % faster on CPU-bound work. One unit
  held a 4-hour full-load soak at 59 °C with no computation error; no longer runs, no boot
  cycling and no Wi-Fi or NSS load at that clock were tested. To keep the rated clock:
  `echo 1008000 > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq` (in `/etc/rc.local`).
- **No multi-day soak yet.** The longest runs: 6.3 hours of CPU load at 1008 and 1296 MHz;
  on v2.1.0, 30 minutes of fragmented Wi-Fi traffic in each Wi-Fi mode; on v2.0.0, 100
  minutes of Wi-Fi traffic, firmware-crash recoveries and driver reloads.
- **2.4 GHz signal readings are checked to about ±10 dB only.** 5 GHz agrees with the test
  client within 3 dB.
- `n2h_rx_queue[0]_drops` rise during offloaded PPPoE uploads: that NSS queue has 256 entries
  on 256 MB boards.

Details are in [VALIDATION.md](VALIDATION.md).

## Documentation

- [What this port adds to kuncy7's release](docs/what-this-port-adds.md), and what it no
  longer carries because his tree has it
- [Packages](docs/packages.md): the repositories, kernel modules and pinned packages
- [AmneziaWG](docs/amneziawg.md): install, LuCI import, full tunnel
- [Upgrading from v1.x](docs/upgrading-from-v1.md)
- [Building](docs/building.md)
- [VALIDATION.md](VALIDATION.md): what was tested on hardware, and what was not
- [NFC tag](docs/nfc.md)
- [Updating without UART](docs/no-uart-reflash.md)
- [UK 5.8 GHz channels and the firmware's regulatory database](docs/regulatory-gb-5ghz.md)

## v1.x

The v1.x releases (kernel 6.12, v1.0 to v1.14) are on branch `v1` and no longer developed.
Their `standard` image is the one without NSS offload.

## Credits and contributing

Thanks to [kuncy7](https://github.com/kuncy7) for openwrt-nss-edma and its NSS stack for
IPQ50xx, which v2 is built on;
[csharper2005](https://github.com/csharper2005/openwrt) for the AN8855 integration and base
device tree; Min Yao / Airoha and Christian Marangi for the driver work; thmalmeida, Edrikk
and the
[OpenWrt forum contributors](https://forum.openwrt.org/t/adding-support-for-xiaomi-ax3000t-rd03v2/235136)
for the hardware and recovery groundwork; and
[Ziyang Huang](https://github.com/hzyitc) for ath11k smallbuffers support.

Contributions are welcome, especially help upstreaming the port to OpenWrt.
Licensed under [GPL-2.0-only](LICENSE); patches retain their original attribution.
