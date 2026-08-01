#!/usr/bin/env bash
# Guard against the AN8855 driver silently diverging between the two builds.
#
# WHY THIS EXISTS
#   nss/overlay/ used to ship a full copy of an8855.c that replaced the files/
#   one. A fix to either copy never reached the other, and nothing in the build
#   said so. That cost issue #9 (and three more latent bugs found auditing it).
#   The fork is gone - files/ is the single source and the NSS delta is
#   999-2758..2762 - but two failure modes remain, and both are silent:
#
#     1. a base change lands in a region the NSS patches also touch, and the
#        patch still applies (with fuzz) but now means something different;
#     2. a patch stops applying to a function it used to change, so the NSS
#        build quietly reverts to base behaviour.
#
#   This reconstructs BOTH final drivers exactly as the build does, then
#   compares the SET OF FUNCTIONS that differ against a checked-in expectation.
#   A function that starts differing without being listed is a new accidental
#   gap; a listed function that becomes identical means a patch went missing.
#
# Needs only patch(1), awk and diff - no toolchain, runs in about a second.
#
#   ./tools/check-nss-divergence.sh            # check
#   ./tools/check-nss-divergence.sh --update   # re-bless the expected list
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECT="$REPO/tools/nss-divergence.expected"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BASE_SRC="$REPO/files/target/linux/qualcommax/files/drivers/net/dsa/an8855.c"
BASE_PATCHES="$REPO/files/target/linux/qualcommax/patches-6.12"
NSS_PATCHES="$REPO/nss/overlay/target/linux/qualcommax/patches-6.12"

[ -f "$BASE_SRC" ] || { echo "FAIL: base driver missing: $BASE_SRC" >&2; exit 1; }
if [ -f "$REPO/nss/overlay/target/linux/qualcommax/files/drivers/net/dsa/an8855.c" ]; then
    echo "FAIL: nss/overlay/ ships an an8855.c again - the fork is back." >&2
    echo "      files/ must be the only source; express NSS deltas as patches." >&2
    exit 1
fi

# Slice the an8855.c hunks out of a patch (patches may touch other files).
slice() { awk '/^--- a\/drivers\/net\/dsa\/an8855\.c$/{p=1}
                p && /^--- a\// && $0 !~ /an8855\.c$/ {p=0}
                p' "$1"; }

build() {  # build <outdir> <patch>...
    local out="$1"; shift
    mkdir -p "$out/drivers/net/dsa"
    cp "$BASE_SRC" "$out/drivers/net/dsa/an8855.c"
    local p
    for p in "$@"; do
        # An unmatched glob arrives here verbatim. Catch it: a missing patch
        # must fail the check loudly, never be skipped into a silent pass.
        [ -f "$p" ] || { echo "FAIL: patch not found: $p" >&2; exit 1; }
        check_hunks "$p"
        slice "$p" > "$WORK/slice"
        if [ -s "$WORK/slice" ]; then
            ( cd "$out" && patch -p1 -s -F0 --no-backup-if-mismatch < "$WORK/slice" ) \
                || { echo "FAIL: $(basename "$p") does not apply at zero fuzz" >&2; exit 1; }
        fi
    done
}

# The NSS delta must be exactly these, in this order. Pinning the list means a
# patch that is deleted, renamed or renumbered fails the check instead of
# quietly reducing the NSS build to base behaviour.
NSS_SET=(
    999-2758-nss-an8855-tag8021q-core.patch
    999-2759-nss-an8855-tag8021q-bridge-leave.patch
    999-2760-nss-an8855-tag8021q-host-fdb-vid.patch
    999-2761-nss-an8855-user-port-flood-default.patch
    999-2762-nss-an8855-vlan-filtering.patch
)

# Pinned hunk counts. Refreshing a patch regenerates it from the APPLIED
# result, so a hunk that failed to apply silently disappears from the patch
# instead of erroring. That actually happened: a refresh dropped 999-2757's
# an8855_port_set_pid -> an8855_port_set_pvid rename while the matching
# definition rename still applied, which would have shipped an undefined
# symbol. It was caught only because the count went 54 -> 53. Pin the counts
# so a refresh that loses work fails here instead.
declare -A HUNKS=(
    [999-2757-net-dsa-add-an8855-v2p0p1-and-netlink-support.patch]=54
    [999-2758-nss-an8855-tag8021q-core.patch]=20
    [999-2759-nss-an8855-tag8021q-bridge-leave.patch]=1
    [999-2760-nss-an8855-tag8021q-host-fdb-vid.patch]=7
    [999-2761-nss-an8855-user-port-flood-default.patch]=2
    [999-2762-nss-an8855-vlan-filtering.patch]=7
)
check_hunks() {  # check_hunks <patchfile>
    local f="$1" b n want
    b=$(basename "$f"); want=${HUNKS[$b]:-}
    [ -n "$want" ] || return 0
    n=$(grep -c '^@@' "$f")
    [ "$n" = "$want" ] || {
        echo "FAIL: $b has $n hunks, expected $want." >&2
        echo "      A refresh that drops a hunk looks exactly like this." >&2
        echo "      If the change is intentional, update HUNKS in $0." >&2
        exit 1
    }
}

# The 2757 rename must be complete: a half-applied rename compiles to an
# undefined symbol only at link time, long after this check would have run.
check_rename() {  # check_rename <built .c>
    local n; n=$(grep -c 'an8855_port_set_pid\b' "$1" || true)
    [ "$n" = 0 ] || {
        echo "FAIL: $n call(s) to an8855_port_set_pid survive 999-2757;" >&2
        echo "      its rename to an8855_port_set_pvid is incomplete." >&2
        exit 1
    }
}
have=$(cd "$NSS_PATCHES" && ls 999-27*.patch 2>/dev/null | sort | tr '\n' ' ')
want=$(printf '%s ' "${NSS_SET[@]}")
[ "$have" = "$want" ] || {
    echo "FAIL: NSS patch set changed." >&2
    echo "  have: $have" >&2
    echo "  want: $want" >&2
    echo "  If intentional, update NSS_SET in $0 and re-bless." >&2
    exit 1
}

BASE_2757="$BASE_PATCHES/999-2757-net-dsa-add-an8855-v2p0p1-and-netlink-support.patch"
build "$WORK/default" "$BASE_2757"
build "$WORK/nss"     "$BASE_2757" "${NSS_SET[@]/#/$NSS_PATCHES/}"
check_rename "$WORK/default/drivers/net/dsa/an8855.c"
check_rename "$WORK/nss/drivers/net/dsa/an8855.c"

# Split a .c into per-function files, keyed by function name. A top-level
# function starts at column 1, contains '(', does not end in ';', and its body
# opens with '{' at column 1; it closes on '}' at column 1. Signatures may span
# several lines (the continuations are indented, so they do not re-trigger).
#
# The name is the last identifier before the first '(' — do NOT use a greedy
# sub() here: on "static int foo(struct dsa_switch *ds, int port," a greedy
# match runs past the '*' in "*ds" and yields fragments like "ds," instead.
split_fns() {
    awk -v dir="$2" '
        function fname(sig,   n, a, nf) {
            n = sig; sub(/\(.*/, "", n)          # keep text before the first (
            gsub(/[^A-Za-z0-9_]/, " ", n)        # non-identifier chars -> space
            nf = split(n, a, " ")
            return nf ? a[nf] : ""               # last token = the symbol
        }
        /^[A-Za-z_]/ && /\(/ && !/;[ \t]*$/ && !/^#/ { if (!inf && pend == "") { pend = $0 } }
        /^\{/ { if (pend != "") { inf = 1; buf = pend "\n" $0 "\n"; name = fname(pend); pend = ""; next } }
        inf { buf = buf $0 "\n"
              if ($0 ~ /^\}/) {
                  if (name != "") { f = dir "/" name; printf "%s", buf > f; close(f) }
                  inf = 0; buf = ""; name = ""
              }
              next
            }
        # Drop a pending signature only on something that clearly is not a
        # continuation of it: a statement/declaration end, or a blank line.
        # Do NOT drop on indented lines - multi-line signatures are indented.
        { if (!inf && ($0 ~ /;[ \t]*$/ || $0 ~ /^[ \t]*$/)) pend = "" }
    ' "$1"
}
mkdir -p "$WORK/fn-default" "$WORK/fn-nss"
split_fns "$WORK/default/drivers/net/dsa/an8855.c" "$WORK/fn-default"
split_fns "$WORK/nss/drivers/net/dsa/an8855.c"     "$WORK/fn-nss"

# Set of function names that differ (present-in-one counts as differing).
{
    for f in "$WORK/fn-default"/*; do
        n=$(basename "$f")
        if [ ! -f "$WORK/fn-nss/$n" ] || ! cmp -s "$f" "$WORK/fn-nss/$n"; then echo "$n"; fi
    done
    for f in "$WORK/fn-nss"/*; do
        n=$(basename "$f")
        [ -f "$WORK/fn-default/$n" ] || echo "$n"
    done
} | sort -u > "$WORK/actual"

if [ "${1:-}" = "--update" ]; then
    cp "$WORK/actual" "$EXPECT"
    echo "blessed $(wc -l < "$EXPECT") diverging functions into $(basename "$EXPECT")"
    exit 0
fi

[ -f "$EXPECT" ] || { echo "FAIL: $EXPECT missing - run with --update once" >&2; exit 1; }

rc=0
if ! diff -q "$EXPECT" "$WORK/actual" >/dev/null; then
    while IFS= read -r line; do
        case "$line" in
            \>*) echo "NEW DIVERGENCE : ${line#> }  (base fix that never reached NSS? or vice versa)" ;;
            \<*) echo "LOST DIVERGENCE: ${line#< }  (an NSS patch stopped changing this - did it silently no-op?)" ;;
        esac
    done < <(diff "$EXPECT" "$WORK/actual" | grep -E '^[<>]')
    rc=1
fi

if [ $rc -eq 0 ]; then
    echo "OK: $(wc -l < "$WORK/actual") diverging functions, all expected; all patches apply at -F0"
else
    echo
    echo "If a change above is intentional, re-bless with: $0 --update"
fi
exit $rc
