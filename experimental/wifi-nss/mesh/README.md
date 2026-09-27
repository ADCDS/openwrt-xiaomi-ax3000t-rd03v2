# NSS 802.11s mesh offload (issue #21)

Every NSS Wi-Fi build (`NSS=1 WIFI_NSS_DONOR=...`) includes 802.11s mesh
offload. It turns on the donor's `ATH11K_NSS_MESH_SUPPORT`, builds the NSS mesh
manager (`kmod-qca-nss-drv-wifi-meshmgr`) into the image, and applies
`patches/` below after every other mac80211/ath11k patch. There is no separate
switch. A build without NSS keeps mainline ath11k, where mesh uses the host
data path.

It stays on the 12.5 NSS firmware (`NSS.FW.12.5-210-MP.R`). On IPQ5018 that
firmware accepts ath11k's mesh capability message and the mesh manager's
interface create on both radios. The 11.4 switch that other ports needed is
not needed here.

## patches/

- `999-937-mac80211-drop-the-hw-checksum-offload-on-an-offloaded-mesh-vdev.patch`
  comes from Julius Bairaktaris' openwrt-nss-edma, branch nss-edma-rework,
  commit ed0ec226379d, authorship kept. The offloaded mesh netdev advertised
  `NETIF_F_HW_CSUM`, and nothing behind the NSS mesh encap node completes the
  checksum. Every UDP datagram the router itself sent over the mesh (DHCP, DNS)
  went out with a bad checksum.
- `999-990-rd03v2-nss-mesh-unlink-only-own-vap.patch`: freeing one mesh vap
  unlinked every entry of the global `mesh_vaps` list. Only the debugfs link
  tooling (`dbg_infra/links`, `assoc_link`) used that list.
- `999-991-rd03v2-nss-mesh-authorize-keyless-peers.patch`: ath11k authorized a
  peer in NSS only when it installed a key, and NSS drops everything an
  unauthorized peer sends. An open mesh therefore peered but passed no data on
  either radio (NSS `peer_unauth_rx_pkt_drop`).
- `999-992-rd03v2-nss-mesh-flush-paths-on-restart.patch`: a firmware restart
  rebuilds the NSS mesh path table empty. mac80211 kept its paths and sent only
  UPDATEs, which NSS rejected, so the node stopped transmitting to its peers.
  The fix flushes the mesh paths on reconfig so they are added again.
- `999-993-rd03v2-nss-mesh-create-dbg-infra-once.patch`: the mesh debugfs
  directory `dbg_infra` holds module-wide files, but the donor created it at
  every radio's NSS init and after every firmware restart, and each repeat
  logged "already present". It is now created once.

## Verified on the bench (2026-09-26/27)

IPQ5018 radio (2.4 GHz) with an RT3070 peer; QCN6122 radio (5 GHz) with an
mt76 (MT7981) peer. Evidence: `stock-investigation/captures/v110-nss-mesh-12.5-bench.txt`.

- Open and SAE mesh on both radios, with the AP on the same radio still
  beaconing. Data runs through NSS: the mesh decap/encap
  counters move, and ECM accelerated a TCP flow on the 2.4 GHz radio.
- The router's own DHCP and DNS over the mesh work with no ethtool
  workaround.
- Firmware restart (hw-restart) with an open mesh: the peers come back and
  traffic resumes after path rediscovery (about 10 s on 2.4 GHz, 30-50 s on
  5 GHz with the mt76 peer).
- The final branch build (commit cb3bf85, with the #22-#24 fixes), on 5 GHz
  with the mt76 peer: open mesh peered and passed 10/10 at 64 and 1400 bytes.
  The peer is authorized in NSS and its inactive time is correct (40 ms). After
  a firmware restart, traffic came back in about 45 s, with no path update
  failures.
- The same build against v1.10 with AP clients on both radios: same
  throughput, bridged and routed with NAT, every flow accelerated, same restart
  recovery, same kernel memory. See "Regression check against v1.10" in
  `docs/nss-wifi-validation.md`.

## Not solved yet / caveats

- SAE mesh after an in-place firmware restart: the peer link stays up but
  traffic stops until the mesh is joined again. `rd03v2-watchdog` now does
  that: when ath11k logs an in-place recovery of a radio, it reloads that
  radio's encrypted mesh supplicants. The re-join logic was tested on both
  radios by sourcing the watchdog on the bench (RT3070 and mt76 peers;
  traffic back 10/10). The running watchdog was then tested on the final
  build: after a restart of the radio with the SAE mesh it logged the re-join
  and the mesh group started again; after a restart of an AP-only radio it did
  nothing. That run had no peer, so traffic recovery through the running
  watchdog rests on the sourced tests.
- `bench-safeboot/` is a test-only `PROFILE=` overlay; see its README.
