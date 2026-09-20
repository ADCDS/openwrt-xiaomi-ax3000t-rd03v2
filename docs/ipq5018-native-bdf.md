# Native IPQ5018 board data for the RD03v2

The original port used the generic WLAN.HK 2.7 IPQ5018 `board-id 255` entry.
It boots, but hardware testing with a weak/legacy SWT6621S client exposed a
real, channel-dependent receive defect:

- on channel 1, authentication and WPA complete normally;
- on channels 6 and 11, identical on-air frames are repeatedly missed by the
  AP, including ACK frames the independent monitor can see;
- an external RT2800 receiver measures the camera at about -73 dBm on both
  channels, ruling out a client TX-power drop;
- with the generic BDF, the AP reports the same client near -49 dBm on channel
  1 but -64 to -66 dBm on channel 6;
- disabling `cold_boot_cal`, disabling NSS Wi-Fi offload, changing rates, and
  changing the client driver/firmware do not remove the defect.

## The format conversion

Xiaomi's stock image contains its calibrated 128 KiB IPQ5018 BDF at:

```text
/lib/firmware/IPQ5018/WIFI_FW/bdwlan.bin
SHA256 8b7ceace14352fc6c226b650b15b1fe37ff46cd7f350d8aa79b66bcbe9115c2a
```

It targets WLAN.HK 2.5 and cannot be passed unchanged to the 2.7 firmware. The
accepted native QCN6122 conversion proves the common schema transition: byte
`0x45c` changes from `03` to `00`, followed by recomputation of the raw BDF's
16-bit XOR checksum (the XOR of all little-endian 16-bit words must be
`0xffff`). QCN6122 additionally expands 5 GHz power tables; those changes do
not apply to the integrated 2.4 GHz BDF, whose corresponding columns are
already populated.

[`tools/lift-ipq5018-bdf.py`](../tools/lift-ipq5018-bdf.py) performs only the
common schema conversion. It pins both stock input hashes, preserves all Xiaomi
calibration bytes, recomputes the checksum, and preserves the existing ath11k
container/name metadata.

Example, from an extracted Xiaomi stock rootfs:

```sh
python3 tools/lift-ipq5018-bdf.py \
  --stock-ipq5018 rootfs/lib/firmware/IPQ5018/WIFI_FW/bdwlan.bin \
  --stock-qcn6122 rootfs/lib/firmware/IPQ5018/WIFI_FW/qcn6122/bdwlan.bin \
  --output /tmp/board-xiaomi_mi-router-ax3000t-v2.ipq5018
```

Expected output container SHA256:

```text
8c2c5fd824de56dd2e096aac405d7784e17488c16c0526cfe7ec9b5084c59efa
```

## Hardware validation

The candidate was bind-mounted over `board-2.bin` and tested through a clean
ath11k unload/reload, so reboot still restored the published squashfs file.

- Q6 and both radios booted without BDF/calibration errors.
- IPQ5018's reported TX ceiling changed from 27 to 30 dBm.
- Channel 6 and channel 11 both completed WPA immediately.
- On channel 11, two 30-packet traffic runs completed with 0% loss.
- AP-side signal improved to about -33 to -36 dBm with zero TX retries or
  failures.

Packet captures from the matched pre-fix A/B showed a clean single auth and
association exchange on channel 1, versus dozens of retries in both directions
on channel 6 at the same externally measured RSSI. This demonstrates that the
fix changes effective receive calibration, not merely the RSSI displayed to
userspace.
