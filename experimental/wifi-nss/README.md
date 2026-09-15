# RD03v2 NSS Wi-Fi integration

See [build instructions, fixes and hardware validation](../../docs/nss-wifi-validation.md).

`patch-overrides/` replaces four patches from qosmio/openwrt-ipq at
`92a2d104145c8d265851c4b388a41bd8e9c21cd9` and adds the RD03v2 QCN6122
register-address fix and the crash-recovery ordering fix (`999-998`). The
original donor authorship headers are retained.
`999-996` fixes a `conf_mutex` leak in the donor's `sta_state` change.
The `999-999-rd03v2-nss-recovery-*` patches make in-place crash recovery work
with offload on.
`999-999-rd03v2-nss-vlan-eapol-to-pae-group` delivers EAPOL on VLAN-aware
bridges, and `999-999-rd03v2-reo-update-queue-noncoherent-free` fixes the
donor's REO update-queue free.
The switch-conduit RX-pause nss-dp patch is not part of this integration: it
lives in `files/package/kernel/qca-nss-dp/patches/` and applies to every build.
It was measured on the NSS Wi-Fi image with NSS Wi-Fi offload on and on the
default build; a real plain-NSS build is pending bench confirmation.
`ethtool -A eth1 rx off` turns it off without a rebuild (see the validation
doc).
The complete pinned series is imported only when `WIFI_NSS_DONOR` is supplied
with `NSS=1`; no donor binaries are reused.
