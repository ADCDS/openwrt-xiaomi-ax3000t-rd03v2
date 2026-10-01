# NFC tag (tap to join)

> TL;DR — the AX3000T v2 has an NFC tag that phones read and the router
> writes. Stock MiWiFi keeps the active Wi-Fi SSID and password on it. This
> port manages it with `/usr/sbin/nfc`. By default it only **clears** the tag,
> wiping whatever stock left there. To share a network, set
> `uci set nfc.main.mode=wifi && uci commit nfc && nfc update`.

## The hardware

The tag is a dual-interface NFC Forum Type 2 tag of the Fudan FM11NT08x class.
Its UID starts with `1d`, the ISO/IEC 7816-6 manufacturer code of Shanghai
Fudan Microelectronics. Phones talk to it over RF. The SoC talks to it over
I2C:

| | |
|---|---|
| Controller | `blsp1_i2c3` (QUP3, `0x078b7000`), 100 kHz, stock settings |
| Pins | gpio25 = SCL, gpio26 = SDA, function `blsp2_i2c1`, external pull-ups |
| Address | `0x57`, the only device on the bus |
| Kernel driver | none: userspace through i2c-dev (`/dev/i2c-0`), as stock does |

The I2C side works like an EEPROM: a 2-byte memory address, then data.
Writes go one 4-byte block per transfer, and the chip NACKs while it programs
a block. Its memory map is the Type 2 tag layout:

| Address | Content |
|---|---|
| `0x000-0x00f` | UID, static lock bytes (`ff ff`), capability container `e1 10 6d 00` |
| `0x010-0x377` | NDEF data area, 872 bytes (`0x6d` × 8, per the capability container) |
| `0x378-0x3ff` | chip configuration |

The static lock bytes are set, so a **phone cannot rewrite the tag**. The
router can: stock rewrites the data area over I2C on every boot. That is where
the idea that the tag is read-only comes from; it is read-only only from the
RF side.

`ipq5018.dtsi` names this QUP's BAM pipes the wrong way round (9 = tx,
8 = rx). Stock and the neighbouring `blsp1_spi1` (4 = tx, 5 = rx) use the
even-tx order, so the board DTS overrides it. The driver uses DMA only for
transfers larger than the QUP FIFO; `nfc` itself reads 16 bytes at a time.

## What stock does

`misc.nfc.nfc_support=1` turns the feature on for this board. Every
`/sbin/wifi` up or reload and every boot (`/etc/init.d/nfc`, S43) runs
`/usr/sbin/nfc.lua`. That calls `XQNfcUtil.nfc_update()`, which builds the
record and hands it to `/sbin/nfc update`, which writes it with `i2ctransfer`.

- Before the setup wizard has run, the tag holds a hidden `<ssid>_nfc` PSK2
  network created for it.
- After setup it holds the active network: 5 GHz if it is up, else 2.4 GHz.
- WPA3 is announced as WPA2-Personal: the WSC authentication table maps
  "SAE" to `0x0020`.
- Stock writes only the new record. It never clears what follows it, so the
  tails of longer, older records stay readable past the terminator.

None of this ran under OpenWrt until now, so a flashed router still holds
whatever stock wrote last. That is often the owner's stock-era SSID and
password, readable by any phone, even with the router switched off.

## What this port does

`/usr/sbin/nfc` (base-files) needs `i2c-tools`, which is in the image.
`/etc/init.d/nfc` runs `nfc update` at boot and whenever the `wireless` or
`nfc` config changes, through procd reload triggers (LuCI *Save & Apply*,
`reload_config`). After a `uci commit wireless` from the shell, run
`nfc update` or `reload_config`.

`/etc/config/nfc`:

```
config nfc 'main'
	option mode 'clear'        # off | clear | wifi
	#option iface 'guest'      # wifi-iface section to share in wifi mode
```

| mode | the tag holds |
|---|---|
| `off` | whatever is on it; never written. A missing config means `off`. |
| `clear` (default) | an empty NDEF message. This is what wipes the stock leftovers. |
| `wifi` | a Wi-Fi credential for `iface`. Without `iface`: the first enabled AP on 5 GHz, else on 2.4 GHz. |

In `wifi` mode the record is the one stock writes, byte for byte: an NDEF
MIME record of type `application/vnd.wfa.wsc` with one WSC Credential (SSID,
authentication type, encryption type, network key). Tapping an Android phone
offers to join the network.

| `encryption` | announced as |
|---|---|
| `none` | open |
| `psk2*`, `sae`, `sae-mixed` | WPA2-Personal (WSC has no WPA3 type; stock does the same) |
| `psk-mixed*` | WPA/WPA2-Personal |
| `psk*` | WPA-Personal |
| `owe`, `wep*`, `wpa*` (enterprise) | cannot be shared; the tag is cleared instead |

`sae-mixed` works with any phone. With pure `sae`, the phone has to upgrade
the WPA2 credential to WPA3 by itself; recent Android versions do. If the
selected interface is missing or disabled, or its encryption cannot be
shared, the tag is cleared rather than left advertising an old network.

```
nfc status   # what the tag holds, and whether it matches /etc/config/nfc
nfc update   # apply /etc/config/nfc
nfc clear    # empty the tag now, whatever the mode
nfc dump     # hex dump of 0x000-0x3ff (a backup before experiments)
```

**Anyone who can tap the router can read a shared password**, so `wifi` is
opt-in. A guest network is a good candidate for `iface`.

## Safety rules in `nfc`

- It runs only on `xiaomi,mi-router-ax3000t-v2`, and only if the tag answers
  with UID byte 0 = `0x1d` and capability container `e1 10 6d`. Anything else
  is refused untouched.
- It writes only 4-byte blocks inside `0x010-0x377`. The UID, lock and
  capability-container bytes below that area, and the configuration above
  it, are never written. Lock bits are one-time programmable, so a stray
  write there could lock the tag for good.
- It manages the whole data area: the record, then zeros. It reads the area,
  writes only the blocks that differ, and reads it back. Re-running is free,
  and the EEPROM is not rewritten on every boot.
- It serialises on `/var/lock/nfc.lock`.

## Verified on the bench (2026-10-01)

Non-NSS build of this branch, run first as the RAM installer, then installed
to NAND with a kept config:

- `/dev/i2c-0` is the QUP at `78b7000`, with gpio25/26 muxed to `blsp2_i2c1`
  and no pull. A read-mode scan finds only `0x57`.
- On the first boot `nfc update` (mode `clear`) wiped the stock record and its
  leftovers: 30 blocks. The UID, lock bytes, capability container and
  configuration area read back identical to a dump taken before the change.
- A full Wi-Fi record takes 23 block writes and 1.4 s, including two full
  reads of the data area. No write needed a retry. A re-run writes nothing
  and takes 0.6 s.
- The BLSP BAM channels 8/9 are allocated as tx/rx. 16-byte reads stay in
  FIFO mode. 64- and 255-byte reads go through DMA and return the same data.
- Changing `nfc.main.mode` or the `wireless` config and running
  `reload_config` rewrites the tag through the procd triggers.
- Tapping an Android phone on the router offered to join the shared network.

Not verified: the NSS build (same DTS node and files), and iOS, which does not
act on WSC records.

## xinfc

[xinfc](https://github.com/klirichek/xinfc) writes the same record over the
same protocol (address `0x57`, NDEF at `0x010`, 4-byte writes), so it should
work on this chip too. It was tested on the MediaTek RD03, not on this board.
`nfc` exists because the image needs more than a writer: it reads the
network from UCI, runs from procd triggers, checks the chip before writing,
skips unchanged blocks and clears stale data.
