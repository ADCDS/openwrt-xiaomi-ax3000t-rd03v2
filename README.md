# OpenWrt for Xiaomi AX3000T (RD03v2)

OpenWrt for the **RD03v2 hardware revision** of the Xiaomi AX3000T: Qualcomm IPQ5018 with a
QCN6122 5 GHz radio, 256 MB RAM and 128 MB NAND. It installs permanently on NAND and
supports all four Ethernet ports, both Wi-Fi bands, the status LED, the NFC tag and LuCI,
with Qualcomm NSS hardware offload for routing and Wi-Fi.

**RD03v2 only.** The MediaTek RD03/RD23 revisions use different hardware and incompatible
firmware. Check your hardware revision before flashing.

The image is a pinned release of
[kuncy7/openwrt-nss-edma](https://github.com/kuncy7/openwrt-nss-edma) (kernel 6.18, NSS on
mainline stmmac) with [this port's additions](docs/what-this-port-adds.md) on top, and
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
  removed.
- **No multi-day soak yet.** Memory held at 40-42 MB available through 100 minutes of Wi-Fi
  traffic, firmware-crash recoveries and driver reloads.
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
