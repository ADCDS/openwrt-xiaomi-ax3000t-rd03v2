#!/usr/bin/env python3
"""Ensure NSS memory-profile changes invalidate the driver build stamp."""
from pathlib import Path
import sys

tree = Path(sys.argv[1]).resolve()
path = tree / "feeds/nss_packages/qca-nss-drv/Makefile"
text = path.read_text()
marker = "include $(INCLUDE_DIR)/kernel.mk"
addition = ("PKG_CONFIG_DEPENDS += CONFIG_NSS_MEM_PROFILE_HIGH "
            "CONFIG_NSS_MEM_PROFILE_MEDIUM CONFIG_NSS_MEM_PROFILE_LOW\n\n")
if addition in text:
    print("NSS memory profiles already tracked")
elif text.count(marker) == 1 and "PKG_CONFIG_DEPENDS" in text:
    path.write_text(text.replace(marker, addition + marker, 1))
    print("NSS memory profiles now tracked as package config dependencies")
else:
    raise SystemExit("Unexpected NSS package Makefile; refusing modification")
