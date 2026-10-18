# Upgrading from v1.x

Boot the release's RAM installer and run `sysupgrade` from there, keeping settings
([updating without UART](no-uart-reflash.md)). Such a sysupgrade carries v1.x files that do not
fit kuncy7's NSS stack, which the release is built on. On the first boot,
`00-rd03v2-migrate-v1x` runs before every other first-boot script:

- It defuses v1.x's `/etc/uci-defaults/10_disable_services`, which v1.x `-nss` config
  backups carry. That script disables `qca-nss-ecm`, which loads ECM on his stack.
- It unsets `nss.general.topology`, so his `99-nss-topology` sets up the NSS plane as on a
  fresh install. The other `nss` options are the same on both.
- It removes `options ecm front_end_selection=0` from `/etc/modules.conf`.
- It removes the boot-flag and NSS-knob blocks from `/etc/rc.local` when they are unchanged.

It then sets `rd03v2.v2.migrated`, so later v2 upgrades skip it. The radio paths
(`platform/soc@0/c000000.wifi`, `.../b00a040.wifi`) and port names are the same in both trees.

Signal readings drop by 31 dB on 2.4 GHz and 24 dB on 5 GHz against v1.x, for stations,
scan results and the probe signal alike: v1.x reads high (see [Not carried](what-this-port-adds.md#not-carried)).
Thresholds set against v1.x numbers (`rssi_reject_assoc_rssi`, `rssi_ignore_probe_request`,
usteer or DAWN settings, scripts) need the same amount taken off.

## Back to v1.x

The same route in the other direction: boot a v1.x RAM installer and run `sysupgrade` with a
v1.x image from there ([updating without UART](no-uart-reflash.md)). Restore a v1.x
configuration backup, not one taken on v2. The v1.x `standard` image is the one without NSS
offload.

## Compared with v1.x

| | v1.x (branch `v1`) | v2 |
|---|---|---|
| Kernel | 6.12 | 6.18 (his release) |
| NSS | qosmio's stack, 12.5 firmware, maintained here | his stack on mainline stmmac, 12.5 firmware |
| Userspace packages | built here from a pinned OpenWrt snapshot; drifts from OpenWrt's feeds | OpenWrt's snapshot feeds, like his images |
| Kernel modules | release archive | our package repository for each release (`v2/<tag>/`) |
| Wi-Fi | NSS offload or host | NSS offload (default) or host; host mode is fixed here (965-967, tree patch 0005) |
