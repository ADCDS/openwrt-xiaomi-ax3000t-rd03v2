#!/usr/bin/env python3
"""Opt-in RD03v2 NSS Wi-Fi integration; does not flash a router."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DONOR_REV = "92a2d104145c8d265851c4b388a41bd8e9c21cd9"
# The NSS build defaults to MEDIUM. This used to be justified here with "LOW
# caps accelerated connections at 512 per family (1024 total), which is too few
# for the gateway this build is for" — but the live stock investigation
# contradicts the premise: stock RD03v2 (ROM 2.0.28) runs
# qca_nss_drv.max_ipv4_conn=512 / max_ipv6_conn=512, exactly the LOW numbers, on
# a consumer gateway. The numbers are in
# stock-investigation/captures/phase3-wifi.txt (module-parameters section),
# tabulated in notes/FINDINGS.md phase 4.
#
# That does not make LOW automatically right for us — a PPPoE gateway with many
# clients is not stock's bench case, and 512 is a hard cap on *accelerated*
# flows, with the rest falling back to the slow path. MEDIUM's 2048/2048 stays
# (nss_hlos_if.h: LOW 512, MEDIUM 2048, neither 4096).
#
# The reason to keep MEDIUM is the connection table, NOT the buffer pool. The
# profile ties the two together at build time, and the non-LOW default pool is
# expensive: 8704 buffers observed on our build (LOW is the only profile that
# clamps it, to NSS_LOW_MEM_EMPTY_POOL_BUF_SZ=4096) x CONFIG_SKB_RECYCLE_SIZE
# (2304 B), sitting in Linux slab permanently as pure SUnreclaim.
#
# Stock asks Linux for half as many (4096) and sets extra_pbuf_core0=802816.
# Do NOT read that as moving the buffering into the nss@40000000 carve-out: in
# nss-drv the extra pbuf pages are kzalloc(GFP_ATOMIC) + dma_map_single from
# HOST memory ("Add extra NSS bufs from host memory", nss_n2h.c; nss_core.h
# calls the accounting field "size of bufs allocated from host"). It is ~784 KiB
# of additional Linux memory, not a relocation out of Linux. Two further traps:
# the knob is write-once per boot (the handler returns -EPERM once
# buf_sz_allocated is set, so it is NOT runtime-reversible), and its allocation
# loop carries a BUG_ON if the very first atomic page fails — which interacts
# badly with any proposal to shrink vm.min_free_kbytes on the same box.
#
# The two are decoupled, and v1.9 ships that split: MEDIUM's connection table is
# selected here, while the smaller host pool is applied at runtime by
# files/target/linux/qualcommax/ipq50xx/base-files/etc/init.d/nss-bufpool
# (START=96, one write of n2h_empty_pool_buf_core0=4096). Nothing in the driver
# binds table size to pool size — the profile macro's only consumers are the
# connection counts and LOW's pool clamp — and it is measured, not assumed:
# SUnreclaim 44,576 -> ~38,200 kB on matched idle boots, about 6.3 MB.
#
# Note the init script sets ONLY the pool. It deliberately does not write
# extra_pbuf_core0, for the reasons above: that knob costs host memory rather
# than saving it, is write-once, and its GFP_ATOMIC allocator can BUG_ON at
# boot. See stock-investigation/notes/V1.9-TUNING.md finding #1, and the script's
# own header, before changing either knob.
#
# Note for anyone tempted to copy stock's /etc/sysctl.d/qca-nss-drv.conf: its
# dev.nss.ipv4cfg.ipv4_conn=4096 line is dead. That sysctl does not exist at
# runtime (only ipv4_accel_mode and ipv4_dscp_map are present); the module
# parameter max_ipv4_conn is what actually sizes the table.
#
# WIFI_NSS_MEM_PROFILE=LOW still switches the whole profile if RAM demands it.
MEM_PROFILE = os.environ.get("WIFI_NSS_MEM_PROFILE", "MEDIUM").upper()
if MEM_PROFILE not in ("LOW", "MEDIUM"):
    raise SystemExit("WIFI_NSS_MEM_PROFILE must be LOW or MEDIUM")
ENABLED = (
    "ATH11K_NSS_SUPPORT", "PACKAGE_MAC80211_NSS_SUPPORT",
    "NSS_DRV_WIFIOFFLOAD_ENABLE", "NSS_DRV_WIFI_EXT_VDEV_ENABLE",
    "NSS_FIRMWARE_VERSION_12_5", "PACKAGE_kmod-ath11k-smallbuffers",
    "PACKAGE_kmod-qca-nss-drv", "PACKAGE_kmod-qca-nss-ecm",
    "NSS_MEM_PROFILE_" + MEM_PROFILE,
)
DISABLED = (
    "ATH11K_NSS_MESH_SUPPORT", "PACKAGE_MAC80211_NSS_REDIRECT",
    "NSS_FIRMWARE_VERSION_11_4", "ATH11K_MEM_PROFILE_512M",
    "ATH11K_MEM_PROFILE_256M", "PACKAGE_kmod-ath11k",
    "NSS_MEM_PROFILE_HIGH",
    "NSS_MEM_PROFILE_" + ("MEDIUM" if MEM_PROFILE == "LOW" else "LOW"),
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
    # mac80211's Makefile `include ath.mk` but declares no SCAN_DEPS, so
    # tmp/info/.packageinfo-kernel_mac80211 does NOT depend on ath.mk: editing
    # ath.mk alone leaves stale package metadata, and .packagedeps - where
    # ALL_VARIANTS comes from - is then regenerated from it. The build still
    # works, because config_package is evaluated live at compile time rather
    # than read back from .packageinfo, but that is evaluation-order luck: an
    # incremental build can mix a new ath.mk with old metadata. Since this
    # integration edits ath.mk, declare the dependency so a rescan is forced.
    #
    # The glob MUST be relative. scan.mk greps this line out of the Makefile
    # into a generated file that is expanded at TOP LEVEL (scan.mk:81), and
    # scan.mk:48 then resolves each entry against $(SCAN_DIR)/$(2)/ only when
    # it is NOT absolute. An earlier attempt used $(wildcard $(CURDIR)/*.mk),
    # which expands against the openwrt topdir and captures rules.mk - not
    # ath.mk - so it silently did nothing. Verified with scan.mk's own
    # expression: "*.mk" -> 6 files (ath, broadcom, intel, marvell, ralink,
    # realtek); "$(CURDIR)/*.mk" -> 1 file (rules.mk).
    # package/firmware/linux-firmware/Makefile:20 uses this exact form.
    mk = replace_once(
        mk,
        "PKG_NAME:=mac80211\n",
        "PKG_NAME:=mac80211\nSCAN_DEPS = *.mk\n",
    )
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
    # ...and the bus packages have to move to that variant too, or they break a
    # KMODS=1 build. They carry no VARIANT line, so config_package falls back to
    # $(firstword $(ALL_VARIANTS)) - "regular". With kmod-ath11k (regular)
    # deselected by the line above, CPTCFG_ATH11K is unset in that variant, so
    # ath11k_ahb.ko and ath11k_pci.ko are never compiled and mac80211 fails
    # packaging them. Pinning both to smallbuffers puts them in the variant that
    # actually has ATH11K, alongside ath11k-smallbuffers itself.
    #
    # This only bites with KMODS=1, which is why it survived the original
    # validation: docs/nss-wifi-validation.md reproduces without it, and a
    # non-KMODS build leaves kmod-ath11k unset in both variants.
    for pkg, sym in (("ahb", "ATH11K_AHB"), ("pci", "ATH11K_PCI")):
        ath = replace_once(
            ath,
            "config-$(call config_package,ath11k-%s) += %s" % (pkg, sym),
            "config-$(call config_package,ath11k-%s,smallbuffers) += %s" % (pkg, sym),
        )
        ath = replace_once(
            ath,
            "  TITLE:=Qualcomm 802.11ax %s wireless chipset support\n"
            "  URL:=https://wireless.wiki.kernel.org/en/users/drivers/ath11k\n" % pkg.upper(),
            "  TITLE:=Qualcomm 802.11ax %s wireless chipset support\n"
            "  URL:=https://wireless.wiki.kernel.org/en/users/drivers/ath11k\n"
            "  VARIANT:=smallbuffers\n" % pkg.upper(),
        )
    ath = replace_once(ath, "+kmod-qrtr-mhi +kmod-ath11k\n", "+kmod-qrtr-mhi +kmod-ath11k-smallbuffers\n")
    # All anchors validated before writing anything. Both donor ath11k memory
    # profiles stay off: 256M has no C consumers, and 512M would also compile
    # the donor's rx-header/tx-limit variants, which this port has not tested.
    # The firmware memory mode still comes from the device tree.
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
        "memory_profile": f"NSS {MEM_PROFILE}, ath11k SMALLBUFFERS, existing firmware memory mode",
        "validation_reference": "docs/nss-wifi-validation.md",
    }, indent=2) + "\n")
    print(f"Integrated experimental NSS Wi-Fi with existing SMALLBUFFERS and NSS {MEM_PROFILE}.")


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
