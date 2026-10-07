#!/usr/bin/env python3
"""List the 5 GHz regulatory domains compiled into an ath11k Q6 firmware.

ath11k is a self-managed wiphy: the channels it offers for a country are the
rules the firmware's built-in regulatory database holds for that country.
This prints that database's 5 GHz rule table and domains so a firmware can be
checked without a board, e.g. for the UK 5725-5850 MHz band (issue #34):

    python3 tools/ath11k-fw-regdb.py /lib/firmware/ath11k/IPQ5018/hw1.0

It reads the q6_fw.bNN segments (or one file) and finds the tables by their
first two rules, 4910-4990 MHz @ 20 dBm and 4940-4990 MHz @ 33 dBm, the
start of reg_rules_5g[] in Qualcomm's regulatory database (reg_db.c in
qca-wifi-host-cmn uses the same layout). Each rule is 12 bytes: start, end
and max bandwidth (u16 MHz), flags (u16), power (u8 dBm), 3 bytes padding.
The domain table follows, 16 bytes per domain: CTL, DFS region, min
bandwidth, antenna gain, rule count (u16) and up to ten rule indices.
Domain 0 is empty.

The country -> domain map is not decoded; set a country on a router and
read `iw reg get` for that.
"""
import argparse
import glob
import os
import struct
import sys

RULE = struct.Struct("<HHHHB3x")
SIGNATURE = RULE.pack(4910, 4990, 20, 0, 20) + RULE.pack(4940, 4990, 20, 0, 33)
FLAGS = {0x2: "NO_IR", 0x8: "RADAR", 0x40: "NO_OFDM", 0x200: "INDOOR"}
CTL = {0x00: "-", 0x10: "FCC", 0x30: "ETSI", 0x40: "MKK", 0x50: "KOR",
       0x60: "CHN", 0xff: "NONE"}
DFS = ["UNINIT", "FCC", "ETSI", "MKK", "CN", "KR", "UNDEF"]


def flag_str(flags):
    return "|".join(name for bit, name in FLAGS.items() if flags & bit)


def decode(blob):
    """Return (offset, rules, domains) or None if blob has no table."""
    start = blob.find(SIGNATURE)
    if start < 0:
        return None
    rules = []
    off = start
    while off + RULE.size <= len(blob):
        lo, hi, bw, flags, power = RULE.unpack_from(blob, off)
        if not (4900 <= lo < hi <= 7125 and bw in (20, 40, 80, 160, 320)):
            break
        rules.append((lo, hi, bw, flags, power))
        off += RULE.size
    domains = []
    while off + 16 <= len(blob):
        ctl, dfs, _min_bw, ant_gain, count = struct.unpack_from("<BBBBH", blob, off)
        ids = list(blob[off + 6:off + 6 + count])
        if (ctl not in CTL or dfs >= len(DFS) or count > 10
                or any(i >= len(rules) for i in ids)
                or (not domains and (ctl, count) != (0, 0))):
            break
        domains.append((ctl, dfs, ant_gain, ids))
        off += 16
    return start, rules, domains


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("path", help="firmware directory (q6_fw.bNN) or one segment")
    ap.add_argument("--rules", action="store_true", help="also list every rule")
    args = ap.parse_args()

    files = (sorted(glob.glob(os.path.join(args.path, "q6_fw.b[0-9]*")))
             if os.path.isdir(args.path) else [args.path])
    seen = set()
    for path in files:
        blob = open(path, "rb").read()
        found = decode(blob)
        if not found:
            continue
        start, rules, domains = found
        key = (tuple(rules), tuple((c, d, a, tuple(i)) for c, d, a, i in domains))
        if key in seen:
            print("%s: same tables as above" % os.path.basename(path))
            continue
        seen.add(key)
        print("%s @ 0x%x: %d 5 GHz rules, %d domains"
              % (os.path.basename(path), start, len(rules), len(domains)))
        if args.rules:
            for i, (lo, hi, bw, flags, power) in enumerate(rules):
                print("  rule %2d  %d-%d @ %d  %2d dBm  %s"
                      % (i, lo, hi, bw, power, flag_str(flags)))
        for n, (ctl, dfs, ant_gain, ids) in enumerate(domains):
            spans = ["%d-%d/%d%s" % (rules[i][0], rules[i][1], rules[i][4],
                                     "/" + flag_str(rules[i][3]) if rules[i][3] else "")
                     for i in ids]
            print("  domain 0x%02x  %-4s dfs=%-6s  %s"
                  % (n, CTL[ctl], DFS[dfs], " ".join(spans)))
    if not seen:
        sys.exit("no 5 GHz regulatory table found in " + args.path)


if __name__ == "__main__":
    main()
