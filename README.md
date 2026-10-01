# OpenWrt for Xiaomi AX3000T (RD03v2)

OpenWrt for the **RD03v2 hardware revision** with Qualcomm IPQ5018, 256 MB RAM
and 128 MB NAND. Supports permanent NAND installation, all four Ethernet ports,
both Wi-Fi bands, the status LED and LuCI.

**RD03v2 only.** The MediaTek RD03/RD23 revisions use different hardware and
incompatible firmware. Check your hardware revision before flashing.

This is a community snapshot port based on OpenWrt `25ee126` (kernel 6.12.94).
Treat it as beta.

## Installation

**Recommended: [xiaomi-openwrt-install](https://github.com/ADCDS/xiaomi-openwrt-install).**
Its `rd03v2` profile installs OpenWrt over Ethernet or Wi-Fi **without opening
the case or connecting UART**. It integrates the hardware-tested V1 → V2
stock-root chain, validates the board and NAND, downloads and verifies this
port's release images, pivots through the RAM initramfs, and runs the supported
NAND installation. Follow
the installer's README and run `python3 install.py standard`.

The [UART + TFTP guide](docs/installation-and-usage.md#uart-installation-guide)
remains available as an alternative, including board wiring and stock recovery images.

## Choosing an image

Start with the default build. The **`-nss` variant** adds experimental Qualcomm
NSS hardware offload for wired routing and Wi-Fi; see the
[NSS guide](docs/nss-offload.md) and [validation results](docs/nss-wifi-validation.md).

| Artifact | Purpose |
|---|---|
| `…-initramfs-factory.ubi` | Initramfs wrapped in UBI for installation without UART; follow the installation guide |
| `…-initramfs-uImage.itb` | RAM boot through UART + TFTP |
| `…-squashfs-sysupgrade.bin` | Permanent firmware, flashed from the RAM initramfs |
| `…-kmods.tar.gz` | Kernel modules matching the exact release and build variant |

See [all image variants and release notes](docs/installation-and-usage.md#release-images)
for the optional `-wifi` installers, NAND support and NSS upgrade notes.

## First boot and updates

- Connect to a LAN port and open **http://192.168.1.1** for LuCI.
- Set a root password. Wi-Fi starts disabled; configure encryption before enabling it.
- **Every flash, including updates, must run from the RAM initramfs.** In-place
  `sysupgrade` from the installed NAND system is unsupported and can leave the
  router unbootable. Follow [updating without UART](docs/no-uart-reflash.md).
- Use kernel modules from the **same release and variant** as your image.
  See [installing modules](docs/installation-and-usage.md#installing-kernel-modules).
- For recovery, see [returning to stock](docs/installation-and-usage.md#recovering--going-back-to-stock).
  Stock recovery images must be at least as new as the last stock firmware the router ran.
- The first boot clears the NFC tag, which still holds the Wi-Fi name and
  password stock last wrote to it. To share a network by tapping a phone, see
  [NFC tag](docs/installation-and-usage.md#nfc-tag-tap-to-join).

## Building and documentation

```sh
git clone https://github.com/ADCDS/openwrt-xiaomi-ax3000t-rd03v2.git
cd openwrt-xiaomi-ax3000t-rd03v2
./build.sh
```

Use `NSS=1 ./build.sh` for experimental offload or `KMODS=1 ./build.sh` to build
matching kernel module packages. See the [build and technical reference](docs/development.md)
for details, measurements and known limitations.

- [Troubleshooting](docs/installation-and-usage.md#quick-troubleshooting)
- [LED configuration](docs/installation-and-usage.md#controlling-the-leds)
- [NFC tag](docs/nfc.md)
- [File and patch manifest](MANIFEST.txt)

## Credits and contributing

Thanks to [csharper2005](https://github.com/csharper2005/openwrt) for the AN8855
integration and base device tree, Min Yao / Airoha and Christian Marangi for the
driver work, thmalmeida, Edrikk and the
[OpenWrt forum contributors](https://forum.openwrt.org/t/adding-support-for-xiaomi-ax3000t-rd03v2/235136)
for the hardware and recovery groundwork, and
[Ziyang Huang](https://github.com/hzyitc) for ath11k smallbuffers support.
[Full credits](docs/development.md#credits).

Contributions are welcome, especially help upstreaming the port to OpenWrt.
Licensed under [GPL-2.0-only](LICENSE); patches retain their original attribution.
