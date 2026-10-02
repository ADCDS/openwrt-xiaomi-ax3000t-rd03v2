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
a block. Its memory map follows the Type 2 tag layout:

| Address | Content |
|---|---|
| `0x000-0x00f` | UID, static lock bytes (`ff ff`), capability container `e1 10 6d 00` |
| `0x010-0x377` | NDEF data area, 872 bytes (`0x6d` × 8, per the capability container) |
| `0x378-0x3ff` | chip-specific data, outside the NDEF area; never written |

The tag is not read-only: the router writes it over I2C, and stock rewrites
the data area on every boot. The static lock bytes do lock blocks 3-15
(`0x00c-0x03f`, which hold the capability container and the first 48 bytes of
the data area) against RF writes, so a phone cannot rewrite the start of a
record. Whether the rest of the data area can be written over RF depends on
chip-specific lock bits that have not been examined, and no RF write has been
tried.

`ipq5018.dtsi` names this QUP's BAM pipes the wrong way round (9 = tx,
8 = rx). Stock and the neighbouring `blsp1_spi1` (4 = tx, 5 = rx) use the
even-tx order, so the board DTS overrides it. The driver uses DMA only for
transfers larger than the QUP FIFO.

Reads have a catch. A read is an address write followed by the read itself.
When the read comes late, the chip drops the address and answers from address
0, and the transfer still succeeds. At idle even a separate address write and
read, run as two `i2ctransfer` calls, work. This is inferred from what the
reads return; the bus itself was not captured. In FIFO mode, i2c-qup sends
the two parts as separate steps, so under CPU load the read can come much
later.

On the bench, with two busy loops at `nice -15`:
- 16-byte reads came back with the header row in bursts: 245 of the 630
  reads away from address 0 in one run, 100 of 100 in another.
- A separate address write and read failed the same way.
- DMA queues both parts at once. Interleaved with the 100 failing reads, 100
  of 100 whole-area reads were right.

The same fault happened at boot on the NSS image, where the first `nfc update`
then rewrote blocks that were already right. So `nfc` reads each range in one
transfer: 16 bytes for the header, the whole data area, or all 1 KB for
`dump`.

## What stock does

`misc.nfc.nfc_support=1` turns the feature on for this board. Every boot
(`/etc/init.d/nfc`, S43) and every `wifi update` or `wifi reload`
(`/sbin/wifi`) runs `/usr/sbin/nfc.lua`. That calls
`XQNfcUtil.nfc_update()`, which builds the record and hands it to
`/sbin/nfc update`, which writes it with `i2ctransfer`.

- Before the setup wizard has run, the tag holds a hidden `<ssid>_nfc` PSK2
  network created for it.
- After setup it holds the active network: 5 GHz if it is up, else 2.4 GHz.
- WPA3 is announced as WPA2-Personal: the WSC authentication table maps
  "SAE" to `0x0020`. The encryption type is always AES.
- Stock writes only the new record. It never clears what follows it, so the
  tails of longer, older records stay readable past the terminator.

None of this ran under OpenWrt until now, so a flashed router still holds
whatever stock wrote last. That is often the owner's stock-era SSID and
password, readable by any phone, even with the router switched off.

## What this port does

`/usr/sbin/nfc` (base-files) needs `i2c-tools`, which is in the image.
`/etc/init.d/nfc` starts `nfc update` in the background at boot and whenever
the `wireless` or `nfc` config changes, through procd reload triggers (LuCI
*Save & Apply*, `reload_config`). After a `uci commit wireless` from the
shell, run `nfc update` or `reload_config`. A transfer on a wedged bus costs
i2c-qup about 15 s, so neither the boot sequence nor procd's trigger queue,
which runs one task at a time for every service, waits for `nfc`. It logs
what it writes and any failure to syslog (`logread -e nfc`).

`/etc/config/nfc`:

```
config nfc 'main'
	option mode 'clear'        # off | clear | wifi
	#option iface 'guest'      # wifi-iface section to share in wifi mode
```

| mode | the tag holds |
|---|---|
| `off` | whatever is on it: `nfc update` does nothing, not even an I2C access. A missing config means `off`. |
| `clear` (default) | an empty NDEF message. This is what wipes the stock leftovers. |
| `wifi` | a Wi-Fi credential for `iface`. Without `iface`: the first enabled, broadcast AP on 5 GHz, else on 2.4 GHz. |

The RAM installer images run the same code with the default config, so just
booting an installer already clears the tag.

In `wifi` mode the record has the layout stock writes: an NDEF MIME record of
type `application/vnd.wfa.wsc` with one WSC Credential (SSID, authentication
type, encryption type, network key). For an open or WPA2/AES network it is
byte-identical to stock's. The encryption type follows the configured cipher,
where stock always writes AES. Tapping an Android phone offers to join the
network.

| `encryption` | announced as |
|---|---|
| `none` | open |
| `psk2*`, `sae*`, `psk3*` (with their `-mixed` forms) | WPA2-Personal (WSC has no WPA3 type; stock does the same) |
| `psk-mixed*` | WPA/WPA2-Personal |
| `psk*` | WPA-Personal |
| `owe`, `wep*`, `dpp`, `wpa*` (enterprise) | not shared; the tag is cleared instead |

Only WPA2 (`psk2`) has been tried with a phone. A `sae-mixed` network also
takes WPA2, so it should work the same way. With pure `sae`, the phone has to
upgrade the WPA2 credential to WPA3 by itself; that is untested.

A hidden AP is never picked automatically: the credential cannot say that the
SSID is hidden, so a phone may not find it. An `iface` that names a hidden AP
is shared anyway. If the selected interface is missing or disabled, or its
encryption cannot be shared, the tag is cleared rather than left advertising
an old network.

```
nfc status   # what the tag holds, and whether it matches /etc/config/nfc
nfc update   # apply /etc/config/nfc
nfc clear    # empty the tag now, whatever the mode
nfc dump     # hex dump of 0x000-0x3ff (a backup before experiments)
```

**Anyone who can tap the router can read a shared password**, so `wifi` is
opt-in. The password stays on the tag with the router off, and after a
reflash, until something clears it. A guest network is a good candidate for
`iface`.

## Safety rules in `nfc`

- It runs only on `xiaomi,mi-router-ax3000t-v2`, and only if the tag answers
  with UID byte 0 = `0x1d` and capability container `e1 10 6d`. Anything else
  is refused untouched.
- It writes only 4-byte blocks inside `0x010-0x377`. The UID, lock and
  capability-container bytes below that area, and the chip data above it,
  are never written. Lock bits are one-time programmable, so a stray write
  there could lock the tag for good.
- It manages the whole data area: the record, then zeros. It reads the area,
  writes only the blocks that differ, and reads it back. Re-running is free,
  and the EEPROM is not rewritten on every boot.
- While the rest changes, the first block (which holds the message length)
  is set to an empty message, and it gets its new value last. A phone that
  reads mid-update, or a run that fails half-way, finds an empty tag or the
  old record, never a mix of the two.
- A NACK (the chip busy programming a block) is retried up to 20 times. Any
  other I2C error fails the run at once.
- Each read is one transfer (see above). A read away from address 0 that
  contains the header row is retried after a 1 s pause, 10 reads in all; then
  the run fails and logs it.
- Runs are serialised on `/var/lock/nfc.lock`, waiting at most 2 minutes. The
  config is read once the lock is held, so a run that waited applies the
  newest one.

## Verified on the bench (2026-10-01)

Non-NSS build of this branch, run first as the RAM installer, then installed
to NAND with a kept config:

- `/dev/i2c-0` is the QUP at `78b7000`, with gpio25/26 muxed to `blsp2_i2c1`
  and no pull. A read-mode scan finds only `0x57`.
- On the first boot `nfc update` (mode `clear`) wiped the stock record and its
  leftovers: 30 blocks. The UID, lock bytes, capability container and chip
  data above the area read back identical to a dump taken before the change.
- A full Wi-Fi record takes 23 block writes and 1.4 s, including two full
  reads of the data area. No write needed a retry. A re-run writes nothing
  and takes 0.6 s.
- The BLSP BAM channels 8/9 are allocated as tx/rx. 16-byte reads stay in
  FIFO mode. 64- and 255-byte reads go through DMA and return the same data.
- Changing `nfc.main.mode` or the `wireless` config and running
  `reload_config` rewrites the tag through the procd triggers.
- Tapping an Android phone on the router offered to join the shared network
  (`psk2`).

A review then changed the script: background runs, the write order above,
NACK-only retries, `off` without I2C access, hidden and multi-radio
interfaces, and the `psk3` and cipher-order mapping.

## Verified on the bench (2026-10-02)

The v1.12 release images, both flavours, installed to NAND with a kept
config:
- The boot-time update runs in the background, after procd's "init complete".
- `off` makes no I2C transfer, whether from a trigger or a manual run.
- `reload_config` returns at once, and the tag then follows a `wireless`
  change.
- 40 updates killed with `kill -9` during their writes each left an empty tag
  or a complete record, never a mix.
- A missing `option iface` clears the tag and logs a notice.
- The NSS core stays healthy, with offload on.

The read fault above was found on the NSS image, where it showed up at boot.
With one transfer per read:
- 4 boots in a row wrote nothing;
- under load, 10 of 10 `status` and `dump` runs were right, and updates wrote
  nothing;
- a full Wi-Fi record takes 28 transfers instead of 190.

Not verified: RF writes to the tag, and iOS, which does not act on WSC
records.

## xinfc

[xinfc](https://github.com/klirichek/xinfc) writes the same record over the
same protocol (address `0x57`, NDEF at `0x010`, 4-byte writes), so it should
work on this chip too. It was tested on the MediaTek RD03, not on this board.
`nfc` exists because the image needs more than a writer: it reads the
network from UCI, runs from procd triggers, checks the chip before writing,
skips unchanged blocks and clears stale data.
