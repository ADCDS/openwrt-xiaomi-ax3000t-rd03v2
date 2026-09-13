#!/usr/bin/env python3
"""Opt-in RD03v2 NSS Wi-Fi integration; does not flash a router."""
import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DONOR_REV = "92a2d104145c8d265851c4b388a41bd8e9c21cd9"
ENABLED = (
    "ATH11K_NSS_SUPPORT", "PACKAGE_MAC80211_NSS_SUPPORT",
    "NSS_DRV_WIFIOFFLOAD_ENABLE", "NSS_DRV_WIFI_EXT_VDEV_ENABLE",
    "NSS_FIRMWARE_VERSION_12_5", "PACKAGE_kmod-ath11k-smallbuffers",
    "PACKAGE_kmod-qca-nss-drv", "PACKAGE_kmod-qca-nss-ecm",
    "NSS_MEM_PROFILE_LOW",
)
DISABLED = (
    "ATH11K_NSS_MESH_SUPPORT", "PACKAGE_MAC80211_NSS_REDIRECT",
    "NSS_FIRMWARE_VERSION_11_4", "ATH11K_MEM_PROFILE_512M",
    "ATH11K_MEM_PROFILE_256M", "PACKAGE_kmod-ath11k",
    "NSS_MEM_PROFILE_HIGH", "NSS_MEM_PROFILE_MEDIUM",
)


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Expected one integration anchor: {old!r}")
    return text.replace(old, new, 1)


def check_config(tree):
    lines = set((tree / ".config").read_text().splitlines())
    bad = [key for key in ENABLED if f"CONFIG_{key}=y" not in lines]
    bad += [key for key in DISABLED if any(
        f"CONFIG_{key}={value}" in lines for value in ("y", "m"))]
    if bad:
        raise SystemExit("Unexpected final config: " + ", ".join(bad))
    print("NSS Wi-Fi configuration checked; see docs/nss-wifi-validation.md for test scope.")


def integrate(tree, donor):
    rev = subprocess.check_output(["git", "-C", str(donor), "rev-parse", "HEAD"], text=True).strip()
    dirty = subprocess.check_output(["git", "-C", str(donor), "status", "--porcelain"], text=True)
    if rev != DONOR_REV or dirty:
        raise SystemExit("Donor must be a clean checkout of " + DONOR_REV)
    package = tree / "package/kernel/mac80211"
    source = REPO / "files/package/kernel/mac80211"
    for filename in ("Makefile", "ath.mk"):
        if (package / filename).read_bytes() != (source / filename).read_bytes():
            raise SystemExit("Unexpected or already integrated package file: " + filename)
    target = package / "patches/nss"
    if target.exists():
        raise SystemExit("NSS patch directory already exists; refusing overwrite")
    mk = (package / "Makefile").read_text()
    ath = (package / "ath.mk").read_text()
    mk = replace_once(mk, "\tCONFIG_PACKAGE_MAC80211_TRACING \\\n", "\tCONFIG_PACKAGE_MAC80211_TRACING \\\n\tCONFIG_PACKAGE_MAC80211_NSS_SUPPORT \\\n")
    mk = replace_once(mk, "+hostapd-common\n", "+hostapd-common +ATH11K_NSS_SUPPORT:kmod-qca-nss-drv\n")
    options = '''
\tconfig ATH11K_NSS_SUPPORT
\t\tbool "Experimental RD03v2 ath11k NSS offload"
\t\tdepends on TARGET_qualcommax_ipq50xx
\t\tselect PACKAGE_MAC80211_NSS_SUPPORT
\t\tdefault n

\tconfig PACKAGE_MAC80211_NSS_SUPPORT
\t\tbool
\t\tdefault n

'''
    mk = replace_once(mk, "  if PACKAGE_kmod-mac80211\n", options + "  if PACKAGE_kmod-mac80211\n")
    mk = replace_once(mk, "MAKE_OPTS:= \\\n", """ifdef CONFIG_ATH11K_NSS_SUPPORT
\tIREMAP_CFLAGS+=-I$(STAGING_DIR)/usr/include/qca-nss-drv -I$(STAGING_DIR)/usr/include/qca-nss-clients
endif
config-$(CONFIG_PACKAGE_MAC80211_NSS_SUPPORT) += MAC80211_NSS_SUPPORT

MAKE_OPTS:= \\
""")
    anchor = "\t$(if $(QUILT),touch $(PKG_BUILD_DIR)/.quilt_used)"
    series = "ifdef CONFIG_ATH11K_NSS_SUPPORT\n" + "".join(
        f"\t$(call PatchDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/nss/{group},nss/{group}/)\n"
        for group in ("subsys", "ath10k", "ath11k")) + "endif\n"
    mk = replace_once(mk, anchor, series + anchor)
    ath = replace_once(ath, "\tCONFIG_ATH_USER_REGD\n", "\tCONFIG_ATH_USER_REGD \\\n\tCONFIG_ATH11K_NSS_SUPPORT\n")
    ath = replace_once(ath, "config-$(CONFIG_ATH11K_THERMAL) += ATH11K_THERMAL\n", "config-$(CONFIG_ATH11K_THERMAL) += ATH11K_THERMAL\nconfig-$(CONFIG_ATH11K_NSS_SUPPORT) += ATH11K_NSS_SUPPORT\n")
    ath = replace_once(ath, "+ATH11K_THERMAL:kmod-thermal +kmod-qcom-qmi-helpers\n", "+ATH11K_THERMAL:kmod-thermal +kmod-qcom-qmi-helpers \\\n  +ATH11K_NSS_SUPPORT:kmod-qca-nss-drv \\\n  +@(ATH11K_NSS_SUPPORT):NSS_DRV_WIFIOFFLOAD_ENABLE \\\n  +@(ATH11K_NSS_SUPPORT):NSS_DRV_WIFI_EXT_VDEV_ENABLE\n")
    ath = replace_once(ath, "  PROVIDES:=kmod-ath11k\n", """ifdef CONFIG_ATH11K_NSS_SUPPORT
  AUTOLOAD:=$(call AutoProbe,ath11k)
  MODPARAMS.ath11k:=nss_offload=1 frame_mode=2
endif
  PROVIDES:=kmod-ath11k
""")
    # This board always uses smallbuffers. Name the provider explicitly to
    # avoid package metadata generating a self-referential virtual dependency.
    ath = replace_once(ath, "+kmod-ath11k +kmod-qrtr-smd", "+kmod-ath11k-smallbuffers +kmod-qrtr-smd")
    ath = replace_once(ath, "+kmod-qrtr-mhi +kmod-ath11k\n", "+kmod-qrtr-mhi +kmod-ath11k-smallbuffers\n")
    # All anchors validated before writing anything. Keep the device's firmware
    # memory-mode handling; the donor 256M option currently has no C consumers.
    shutil.copytree(donor / "package/kernel/mac80211/patches/nss", target)
    shutil.copytree(REPO / "experimental/wifi-nss/patch-overrides", target, dirs_exist_ok=True)
    (package / "Makefile").write_text(mk)
    (package / "ath.mk").write_text(ath)
    with (tree / ".config").open("a") as config:
        config.write("\n# Experimental RD03v2 NSS Wi-Fi; hardware test scope is documented\n")
        config.writelines(f"CONFIG_{key}=y\n" for key in ENABLED)
        config.writelines(f"# CONFIG_{key} is not set\n" for key in DISABLED)
    manifest = {str(p.relative_to(package)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted(target.rglob("*.patch"))}
    (tree / "wifi-nss-integration.json").write_text(json.dumps({
        "donor_commit": DONOR_REV, "status": "experimental", "patches": manifest,
        "memory_profile": "NSS LOW, ath11k SMALLBUFFERS, existing firmware memory mode",
        "validation_reference": "docs/nss-wifi-validation.md",
    }, indent=2) + "\n")
    print("Integrated experimental NSS Wi-Fi with existing SMALLBUFFERS and NSS LOW.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-config", action="store_true")
    parser.add_argument("tree", type=Path)
    parser.add_argument("donor", type=Path, nargs="?")
    args = parser.parse_args()
    if args.check_config:
        check_config(args.tree.resolve())
    elif args.donor:
        integrate(args.tree.resolve(), args.donor.resolve())
    else:
        parser.error("donor checkout is required for integration")
