#!/usr/bin/env python3
"""Exercise the real packet-buffer service's board default and UCI overrides."""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
args = parser.parse_args()
source = args.source.read_text()
start = source.index('set_stats_disable() {')
end = source.index('\nset_scaling_governor()', start)
function = source[start:end]
function = function.replace('/tmp/sysinfo/board_name', '"$PBUF_TEST_DIR/board_name"')
function = function.replace('/sys/kernel/debug/ath11k', '"$PBUF_TEST_DIR/ath11k"')
prefix = '''config_load() { :; }
config_get() {
  case "$PBUF_TEST_OVERRIDE" in
    unset) eval "$1=\\\"$4\\\"";;
    0|1) eval "$1=$PBUF_TEST_OVERRIDE";;
    *) exit 64;;
  esac
}
logger() { :; }
'''
cases = [('RD03v2 default', 'xiaomi,mi-router-ax3000t-v2', 'unset', '0'),
         ('RD03v2 explicit disable', 'xiaomi,mi-router-ax3000t-v2', '1', '1'),
         ('RD03v2 explicit enable', 'xiaomi,mi-router-ax3000t-v2', '0', '0'),
         ('other board default', 'glinet,gl-b3000', 'unset', '1'),
         ('other board explicit enable', 'glinet,gl-b3000', '0', '0'),
         ('other board explicit disable', 'glinet,gl-b3000', '1', '1'),
         ('missing board identity', None, 'unset', '1')]
with tempfile.TemporaryDirectory(prefix='pbuf-policy-') as temporary:
    root = Path(temporary)
    files = [root / 'ath11k' / device / 'stats_disable' for device in ('ipq', 'qcn')]
    for file in files:
        file.parent.mkdir(parents=True)
    for name, board, override, expected in cases:
        identity = root / 'board_name'
        if board is None:
            identity.unlink(missing_ok=True)
        else:
            identity.write_text(board + '\n')
        for file in files:
            file.write_text('unchanged\n')
        result = subprocess.run(['sh'], input=prefix + function + '\nset_stats_disable\n',
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env={**os.environ, 'PBUF_TEST_DIR': str(root),
                                     'PBUF_TEST_OVERRIDE': override})
        assert result.returncode == 0, (name, result.stderr)
        assert all(file.read_text().strip() == expected for file in files), name
        print('PASS ' + name)
