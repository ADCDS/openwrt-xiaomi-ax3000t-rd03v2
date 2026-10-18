#!/usr/bin/env python3
"""Compare selected board-data payloads independently of container aliases."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

MAGIC = b'QCA-ATH11K-BOARD\0'
VARIANT = 'Xiaomi-Mi-Router-AX3000T-v2'


def entries(data, position=0):
    while position < len(data):
        if len(data) - position < 8:
            if len(data) - position <= 3 and not any(data[position:]):
                return
            raise ValueError('truncated BDF header')
        kind, size = struct.unpack_from('<II', data, position)
        position += 8
        if position + size > len(data):
            raise ValueError('truncated BDF payload')
        yield kind, data[position:position + size]
        position += (size + 3) & ~3


def selected(path):
    raw = path.read_bytes()
    if not raw.startswith(MAGIC):
        raise ValueError('not an ath11k board-2 container')
    candidates = []
    for kind, record in entries(raw, (len(MAGIC) + 3) & ~3):
        if kind != 0:
            continue
        names, data = [], []
        for field, value in entries(record):
            if field == 0:
                names.append(value.rstrip(b'\0').decode())
            elif field == 1:
                data.append(value)
        if any(('variant=' + VARIANT) in name.split(',') for name in names):
            if len(data) != 1 or len(data[0]) != 128 * 1024:
                raise ValueError('selected calibration must be one 128 KiB payload')
            candidates.append({'aliases': names, 'payload_sha256': hashlib.sha256(data[0]).hexdigest(),
                               'payload_bytes': len(data[0])})
    if len(candidates) != 1:
        raise ValueError('container does not select exactly one board calibration')
    return {'path': str(path), 'container_sha256': hashlib.sha256(raw).hexdigest(), **candidates[0]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ours', type=Path, required=True, help='our ipq-wifi files directory')
    parser.add_argument('--donor-tree', type=Path, required=True, help='pinned donor ipq-wifi files directory')
    parser.add_argument('--donor-root', type=Path, required=True, help='archived donor image ath11k firmware directory')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    report = {'variant': VARIANT, 'radios': {}, 'evidence': 'offline calibration provenance only'}
    for radio in ('ipq5018', 'qcn6122'):
        name = 'board-xiaomi_mi-router-ax3000t-v2.' + radio
        records = {'ours': selected(args.ours / name), 'donor_tree': selected(args.donor_tree / name),
                   'donor_image': selected(args.donor_root / radio.upper() / 'hw1.0/board-2.bin')}
        if len({record['payload_sha256'] for record in records.values()}) != 1:
            raise ValueError('calibration payloads differ for ' + radio)
        report['radios'][radio] = records
    report['status'] = 'equivalent_calibration'
    args.out.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({radio: records['ours']['payload_sha256'] for radio, records in report['radios'].items()}, indent=2))


if __name__ == '__main__':
    main()
