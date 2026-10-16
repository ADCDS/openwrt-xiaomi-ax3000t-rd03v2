# OpenWrt for Xiaomi AX3000T (RD03v2)

OpenWrt for the **RD03v2 hardware revision** of the Xiaomi AX3000T: Qualcomm IPQ5018 with a
QCN6122 5 GHz radio, 256 MB RAM and 128 MB NAND. It installs permanently on NAND and
supports all four Ethernet ports, both Wi-Fi bands, the status LED, the NFC tag and LuCI,
with Qualcomm NSS hardware offload for routing and Wi-Fi.

**RD03v2 only.** The MediaTek RD03/RD23 revisions use different hardware and incompatible
firmware. Check your hardware revision before flashing.

This is v2 of the port: a pinned release of
[kuncy7/openwrt-nss-edma](https://github.com/kuncy7/openwrt-nss-edma) (kernel 6.18, NSS on
mainline stmmac) with this port's additions on top, and OpenWrt's own snapshot package
feeds. **Status: release candidate.**

- [v2/README.md](v2/README.md): what v2 adds to kuncy7's release, packages, upgrading from
  v1.x, known issues and building.
- [v2/VALIDATION.md](v2/VALIDATION.md): what was tested on hardware, and what was not.

## Installation

- **From stock firmware:** use
  [xiaomi-openwrt-install](https://github.com/ADCDS/xiaomi-openwrt-install):
  `python3 install.py nss-v2 --release <v2 tag>`. It installs over Ethernet or Wi-Fi
  **without opening the case or connecting UART**, validates the board and NAND, and verifies
  the images it writes. Its `--wifi-ssid`, `--wifi-key`, `--wifi-country` and
  `--root-password` options set up the installed system.
- **From v1.x or another OpenWrt build:** boot the v2 RAM installer and run `sysupgrade`
  from there ([updating without UART](docs/no-uart-reflash.md)). Keeping settings carries a
  v1.x configuration over; the first boot migrates it
  ([upgrading from v1.x](v2/README.md#upgrading-from-v1x)).
- **Back to stock:** `revert.py` from xiaomi-openwrt-install.

## After installing

- Connect to a LAN port and open **http://192.168.1.1** for LuCI. Set a root password.
  Wi-Fi stays off until it is configured, unless the installer was given Wi-Fi settings.
- **Every flash, including updates, runs from the RAM installer.** `sysupgrade` from the
  installed NAND system is refused.
- Packages: `apk update`, then `apk add <package>`. Userspace comes from OpenWrt's snapshot
  feeds; kernel modules (`kmod-*`) and AmneziaWG come from this port's signed repository for
  the release, listed first in `/etc/apk/repositories.d/distfeeds.list`
  ([packages](v2/README.md#packages)).
- The first boot clears the NFC tag, which still holds the Wi-Fi name and password stock
  last wrote to it. To share a network by tapping a phone, see [NFC tag](docs/nfc.md).

## Building

```sh
git clone https://github.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2.git
cd openwrt-xiaomi-ax3000t-rd03v2
TAG=DEV-<name> v2/build.sh
```

The build needs local mirrors of kuncy7's tree and nss feed next to the repository; see
[building](v2/README.md#building).

## Other documents

- [NFC tag](docs/nfc.md)
- [Updating without UART](docs/no-uart-reflash.md)
- [UK 5.8 GHz channels and the firmware's regulatory database](docs/regulatory-gb-5ghz.md)

## v1.x

The v1.x releases (OpenWrt kernel 6.12 with qosmio's NSS stack, v1.0 to v1.14) are on branch
`v1`. That line is no longer developed.

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
