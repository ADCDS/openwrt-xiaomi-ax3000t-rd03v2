#!/usr/bin/env python3
"""Check HTT argument units after all ath11k patches have been applied."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
rx, tx = (root / 'dp_rx.c').read_text(), (root / 'dp_tx.c').read_text()
mac = (root / 'mac.c').read_text()
nss, debugfs = (root / 'nss.c').read_text(), (root / 'debugfs.c').read_text()
header = (root / 'dp.h').read_text()
profiles = '\n'.join(p.read_text() for p in root.glob('*.h'))
flags = {name: 1 << int(bit) for name, bit in re.findall(
    r'(HTT_RX_FILTER_TLV_FLAGS_\w+)\s*=\s*BIT\((\d+)\)', header)}
default = re.search(r'ath11k_mac_mon_status_filter_default\s*=\s*\{\s*\.rx_filter\s*=\s*([^,]+)', mac)
helper = re.search(r'void ath11k_nss_ext_rx_stats\([^}]+?if \(ab->nss.enabled\)\s*'
                   r'tlv_filter->rx_filter \|= ([^;]+);\s*else\s*'
                   r'tlv_filter->rx_filter \|= ([^;]+);', nss)
hw = (root / 'hw.c').read_text()
ipq5018 = re.search(r'const struct ath11k_hw_ops ipq5018_ops = \{(.*?)\n\};', hw, re.S)
ipq5018 = ipq5018[1] if ipq5018 else ''
dot11_called = [op for op in ('rx_desc_get_mpdu_frame_ctl', 'rx_desc_dot11_hdr_fields_valid',
                              'rx_desc_get_dot11_hdr', 'rx_desc_get_crypto_header')
                if re.search(r'hw_ops->' + op + r'\(', rx)]
def mask(expression):
    result = 0
    for name in expression.split('|'):
        result |= flags[name.strip()]
    return result
try:
    base = mask(default[1])
    nss_mask, host_mask = base | mask(helper[1]), base | mask(helper[2])
except (KeyError, TypeError):
    nss_mask = host_mask = -1
def restores(source, expected):
    copies = re.findall(r'tlv_filter = ath11k_mac_mon_status_filter_default;([^}]{0,240})', source)
    return len(copies) == expected and all('ath11k_nss_ext_rx_stats(' in copy.split('\n\n')[0]
                                          for copy in copies)
checks = [
    ('host filter matches measured 0x1f01 mask', host_mask == 0x1f01),
    ('NSS filter remains 0x1601', nss_mask == 0x1601),
    ('monitor reset restores runtime metadata', restores(tx, 1)),
    ('debug resets restore runtime metadata', restores(debugfs, 3)),
    ('host monitor supplies peer RX metadata', bool(re.search(
        r'ath11k_mac_mon_status_filter_default\s*=\s*\{[^}]+HTT_RX_FILTER_TLV_FLAGS_PPDU_END_USER_STATS\b', mac))),
    ('host RX filter uses bytes', bool(re.search(
        r'if \(!ar->ab->nss.enabled\)\s+ret = ath11k_dp_tx_htt_rx_filter_setup\([^;]+HAL_RXDMA_BUF,\s+DP_RX_BUFFER_SIZE,', rx))),
    ('compact NSS RX size preserved', bool(re.search(
        r'else\s+ret = ath11k_dp_tx_htt_rx_filter_setup\([^;]+HAL_RXDMA_BUF,\s+DP_RXDMA_NSS_REFILL_RING_SIZE,', rx))),
    ('monitor packet buffer uses bytes', bool(re.search(r'HAL_RXDMA_MONITOR_BUF,\s+DP_RX_BUFFER_SIZE,', tx))),
    ('monitor status buffer uses bytes', bool(re.search(r'HAL_RXDMA_MONITOR_STATUS,\s+DP_RX_BUFFER_SIZE,', tx))),
    ('host buffer remains 2048 bytes', bool(re.search(r'#define\s+DP_RX_BUFFER_SIZE\s+2048\b', header))),
    ('compact NSS buffer remains 1816 bytes', bool(re.search(r'#define\s+ATH11K_DP_RXDMA_NSS_REFILL_RING_SIZE\s+1816\b', profiles))),
    ('low-memory ring remains 512 entries', bool(re.search(r'#define\s+ATH11K_DP_RXDMA_REFILL_RING_SIZE\s+512\b', profiles))),
    # his NSS set (999-233) rebuilds the 802.11 header from the RX descriptor through these ops
    # and calls them unguarded; a NULL one in ipq5018_ops oopses on the first EAPOL frame in
    # host Wi-Fi mode (987, rd03v2 #47)
    ('IPQ5018 ops fill the 802.11 header ops the RX path calls',
     all(re.search(r'\.' + op + r'\s*=', ipq5018) for op in dot11_called) if ipq5018 else False),
]
for label, okay in checks:
    print(('PASS ' if okay else 'FAIL ') + label)
raise SystemExit(sum(not okay for _, okay in checks))
