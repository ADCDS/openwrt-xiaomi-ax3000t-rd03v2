#!/usr/bin/env python3
"""Build the RD03v2 native WLAN.HK 2.7 IPQ5018 board-data file.

Xiaomi ships a WLAN.HK 2.5 BDF.  The accepted QCN6122 conversion in this
repository proves that the common 2.5 -> 2.7 schema transition clears byte
0x45c and rebuilds the raw BDF checksum.  QCN6122 also expands 5 GHz power
tables, but IPQ5018's integrated 2.4 GHz BDF already has populated columns in
that area, so no QCN-specific power-table bytes are transplanted.

The stock inputs are not redistributed.  Their hashes are pinned so this tool
cannot silently generate board data from another device or firmware release.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import struct


PAYLOAD_SIZE = 128 * 1024
PAYLOAD_OFFSET = 168
CHECKSUM_OFFSET = 0x0A
SCHEMA_OFFSET = 0x45C

STOCK_IPQ5018_SHA256 = (
    "8b7ceace14352fc6c226b650b15b1fe37ff46cd7f350d8aa79b66bcbe9115c2a"
)
STOCK_QCN6122_SHA256 = (
    "c4dd29d71180a071556d53907a25533d669f1e7f5dd3482ac30a015b35451296"
)
NATIVE_CONTAINER_SHA256 = (
    "8c2c5fd824de56dd2e096aac405d7784e17488c16c0526cfe7ec9b5084c59efa"
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read(path: pathlib.Path) -> bytes:
    return path.read_bytes()


def board_payload(container: bytes) -> bytes:
    if not container.startswith(b"QCA-ATH11K-BOARD\0"):
        raise ValueError("template/reference is not an ath11k board-2 container")
    data = container[PAYLOAD_OFFSET:]
    if len(data) != PAYLOAD_SIZE:
        raise ValueError(f"unexpected board payload size: {len(data)}")
    return data


def xor16(data: bytes) -> int:
    if len(data) % 2:
        raise ValueError("raw BDF size must be even")
    result = 0
    for (word,) in struct.iter_unpack("<H", data):
        result ^= word
    return result


def require_hash(label: str, data: bytes, expected: str) -> None:
    actual = sha256(data)
    if actual != expected:
        raise ValueError(f"{label} SHA256 {actual}, expected {expected}")


def arguments() -> argparse.Namespace:
    repo = pathlib.Path(__file__).resolve().parent.parent
    firmware = repo / "files/package/firmware/ipq-wifi/files"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stock-ipq5018", required=True, type=pathlib.Path)
    parser.add_argument("--stock-qcn6122", required=True, type=pathlib.Path)
    parser.add_argument(
        "--template",
        type=pathlib.Path,
        default=firmware / "board-xiaomi_mi-router-ax3000t-v2.ipq5018",
        help="board-2 container whose name/header is preserved",
    )
    parser.add_argument(
        "--qcn6122-reference",
        type=pathlib.Path,
        default=firmware / "board-xiaomi_mi-router-ax3000t-v2.qcn6122",
        help="accepted native 2.7 conversion used to verify the schema byte",
    )
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--raw-output", type=pathlib.Path)
    return parser.parse_args()


def main() -> int:
    args = arguments()
    stock_ipq = read(args.stock_ipq5018)
    stock_qcn = read(args.stock_qcn6122)
    template = read(args.template)
    qcn_27 = board_payload(read(args.qcn6122_reference))

    if len(stock_ipq) != PAYLOAD_SIZE or len(stock_qcn) != PAYLOAD_SIZE:
        raise ValueError("stock BDF inputs must each be exactly 128 KiB")
    require_hash("stock IPQ5018", stock_ipq, STOCK_IPQ5018_SHA256)
    require_hash("stock QCN6122", stock_qcn, STOCK_QCN6122_SHA256)

    # The known-good QCN6122 lift establishes the common schema transition.
    if stock_qcn[SCHEMA_OFFSET] != 3 or qcn_27[SCHEMA_OFFSET] != 0:
        raise ValueError("QCN6122 reference no longer proves schema byte 03 -> 00")
    if stock_ipq[SCHEMA_OFFSET] != 3:
        raise ValueError("stock IPQ5018 schema byte is not the expected value 03")

    native = bytearray(stock_ipq)
    native[SCHEMA_OFFSET] = qcn_27[SCHEMA_OFFSET]
    native[CHECKSUM_OFFSET : CHECKSUM_OFFSET + 2] = b"\0\0"
    checksum = xor16(native) ^ 0xFFFF
    native[CHECKSUM_OFFSET : CHECKSUM_OFFSET + 2] = struct.pack("<H", checksum)
    if xor16(native) != 0xFFFF:
        raise AssertionError("raw BDF checksum invariant failed")

    native_bytes = bytes(native)
    output = template[:PAYLOAD_OFFSET] + native_bytes
    require_hash("generated native container", output, NATIVE_CONTAINER_SHA256)

    args.output.write_bytes(output)
    if args.raw_output:
        args.raw_output.write_bytes(native_bytes)

    changed = [
        index for index, (old, new) in enumerate(zip(stock_ipq, native_bytes))
        if old != new
    ]
    print(f"schema: 0x{SCHEMA_OFFSET:x}: 03 -> 00")
    print(f"checksum: 0x{checksum:04x}; xor16=0x{xor16(native_bytes):04x}")
    print("changed offsets: " + ", ".join(f"0x{i:x}" for i in changed))
    print(f"raw SHA256: {sha256(native_bytes)}")
    print(f"container SHA256: {sha256(output)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
