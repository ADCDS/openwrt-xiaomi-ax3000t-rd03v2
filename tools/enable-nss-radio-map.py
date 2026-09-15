#!/usr/bin/env python3
"""Assign NSS Wi-Fi radio priorities to the RD03v2 radios (IPQ5018 0, QCN6122 1)."""
from pathlib import Path
import sys

tree = Path(sys.argv[1]).resolve()
path = tree / "target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-nss.dtsi"
board = tree / "target/linux/qualcommax/dts/ipq5018-mi-router-ax3000t-v2.dts"
data = path.read_text()
marker = "// NOTE: upstream nss.dtsi added nss-radio-priority"
if data.count(marker) != 1:
    raise SystemExit("Expected unmodified RD03v2 NSS DTS comment; refusing change")
board_data = board.read_text()
if "&wifi {" not in board_data or "&wifi1 {" not in board_data:
    raise SystemExit("Unexpected RD03v2 radio labels")
data = data[:data.index(marker)] + '''// Experimental NSS Wi-Fi multi-radio scheduling, adapted from qosmio
// 92a2d104145c8d265851c4b388a41bd8e9c21cd9 ipq5018-nss.dtsi.
// RD03v2 uses &wifi for IPQ5018 and &wifi1 for external QCN6122.
&wifi {
    nss-radio-priority = <0>;
};

&wifi1 {
    nss-radio-priority = <1>;
};
'''
path.write_text(data)
print("Assigned NSS radio priorities: &wifi 0, &wifi1 1")
