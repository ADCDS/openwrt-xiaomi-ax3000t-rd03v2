# RD03v2 NSS Wi-Fi integration

See [build instructions, fixes and hardware validation](../../docs/nss-wifi-validation.md).

`patch-overrides/` replaces four patches from qosmio/openwrt-ipq at
`92a2d104145c8d265851c4b388a41bd8e9c21cd9` and adds the RD03v2 QCN6122
register-address fix and the crash-recovery ordering fix (`999-998`). The
original donor authorship headers are retained.
The complete pinned series is imported only when `WIFI_NSS_DONOR` is supplied
with `NSS=1`; no donor binaries are reused.
