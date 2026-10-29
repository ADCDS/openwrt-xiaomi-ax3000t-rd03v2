#!/usr/bin/env python3
"""Run the v1.x settings migration (00-rd03v2-migrate-v1x) against fixture roots (#51).

uci and logger are stubs; with --env target the script runs under the image's BusyBox
(qemu-aarch64), and so do the applets it calls (grep, sed, tr, mv, date, touch).
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / 'overlay/target/linux/qualcommax/ipq50xx/base-files/etc/uci-defaults/00-rd03v2-migrate-v1x'
SHELL = ['/bin/sh']
RFS = None
APPLETS = ('grep', 'sed', 'tr', 'mv', 'date', 'touch', 'awk', 'rm')

# what sysupgrade -b writes for a v1.x -nss dumb AP (dnsmasq, firewall, odhcpd disabled)
DUMB_AP = ('/etc/init.d/dnsmasq disable\n/etc/init.d/firewall disable\n/etc/init.d/odhcpd disable\n'
           '/etc/init.d/qca-nss-drv disable\n/etc/init.d/qca-nss-ecm disable\n\nexit 0\n')
NSS_ONLY = '/etc/init.d/qca-nss-drv disable\n/etc/init.d/qca-nss-ecm disable\n\nexit 0\n'


class Migrate(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='v2-migrate-fixture-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / 'bin'
        self.state = self.root / 'state'
        for path in (self.bin, self.state, self.root / 'etc/uci-defaults', self.root / 'etc/config'):
            path.mkdir(parents=True, exist_ok=True)
        uci = self.bin / 'uci'
        uci.write_text('#!/bin/sh\n'
                       'echo "$*" >> "$ROOT/state/uci.calls"\n'
                       'case "$*" in\n'
                       '"-q get rd03v2.v2.migrated") cat "$ROOT/state/migrated" 2>/dev/null || exit 1;;\n'
                       '"-q get nss.general.topology") cat "$ROOT/state/topology" 2>/dev/null || exit 1;;\n'
                       '"-q batch") cat >> "$ROOT/state/uci.batch";;\n'
                       'esac\nexit 0\n')
        logger = self.bin / 'logger'
        logger.write_text('#!/bin/sh\necho "$*" >> "$ROOT/state/logger.calls"\n')
        for stub in (uci, logger):
            stub.chmod(0o755)
        if RFS:
            for name in APPLETS:
                path = self.bin / name
                path.write_text('#!/bin/sh\nexec qemu-aarch64 "$QEMU_LD_PREFIX/bin/busybox" ' + name + ' "$@"\n')
                path.chmod(0o755)

    def disable_file(self, text=None):
        path = self.root / 'etc/uci-defaults/10_disable_services'
        if text is not None:
            path.write_text(text)
        return path

    def run_script(self):
        environment = {**os.environ, 'ROOT': str(self.root), 'PATH': str(self.bin) + ':/usr/bin:/bin'}
        if RFS:
            environment['QEMU_LD_PREFIX'] = str(RFS)
        result = subprocess.run(SHELL + [str(SCRIPT)], env=environment,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')

    def log(self):
        path = self.root / 'etc/rd03v2-migrate.log'
        return path.read_text() if path.exists() else ''

    def marked(self):
        path = self.state / 'uci.batch'
        return path.exists() and "set rd03v2.v2.migrated='1'" in path.read_text()

    def test_dumb_ap_keeps_its_services_disabled(self):
        f = self.disable_file(DUMB_AP)
        self.run_script()
        self.assertEqual(f.read_text(), DUMB_AP.replace('/etc/init.d/qca-nss-ecm disable\n', ''))
        self.assertIn('removed qca-nss-ecm from /etc/uci-defaults/10_disable_services; '
                      'kept disabled: dnsmasq firewall odhcpd qca-nss-drv', self.log())
        self.assertTrue(self.marked())
        self.assertFalse((self.root / 'etc/uci-defaults/10_disable_services.rd03v2').exists())

    def test_v1_nss_only_file(self):
        f = self.disable_file(NSS_ONLY)
        self.run_script()
        self.assertEqual(f.read_text(), '/etc/init.d/qca-nss-drv disable\n\nexit 0\n')
        self.assertIn('kept disabled: qca-nss-drv', self.log())
        self.assertTrue(self.marked())

    def test_ecm_line_variants(self):
        f = self.disable_file('  /etc/init.d/qca-nss-ecm   disable 2>/dev/null\n'
                              '/etc/init.d/qca-nss-ecm disable\n/etc/init.d/uhttpd disable\nexit 0\n')
        self.run_script()
        self.assertEqual(f.read_text(), '/etc/init.d/uhttpd disable\nexit 0\n')
        self.assertIn('kept disabled: uhttpd', self.log())

    def test_only_the_ecm_line(self):
        f = self.disable_file('/etc/init.d/qca-nss-ecm disable\n')
        self.run_script()
        self.assertEqual(f.read_text(), '')
        self.assertIn('kept disabled: nothing', self.log())

    def test_file_without_ecm_is_left_alone(self):
        text = '/etc/init.d/dnsmasq disable\n/etc/init.d/odhcpd disable\n\nexit 0\n'
        f = self.disable_file(text)
        self.run_script()
        self.assertEqual(f.read_text(), text)
        self.assertNotIn('qca-nss-ecm', self.log())
        self.assertIn('nothing from v1.x to migrate', self.log())

    def test_no_file(self):
        self.run_script()
        self.assertFalse(self.disable_file().exists())
        self.assertIn('nothing from v1.x to migrate', self.log())
        self.assertTrue(self.marked())

    def test_already_migrated_changes_nothing(self):
        (self.state / 'migrated').write_text('1\n')
        f = self.disable_file(DUMB_AP)
        self.run_script()
        self.assertEqual(f.read_text(), DUMB_AP)
        self.assertEqual(self.log(), '')
        self.assertFalse(self.marked())

    def test_logger_still_called(self):
        self.disable_file(DUMB_AP)
        self.run_script()
        calls = (self.state / 'logger.calls').read_text()
        self.assertIn('-t rd03v2-migrate removed qca-nss-ecm', calls)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--script', type=Path, default=SCRIPT)
    parser.add_argument('--env', choices=('host', 'target'), default='host')
    parser.add_argument('--rootfs', type=Path)
    args = parser.parse_args()
    SCRIPT = args.script.resolve()
    if args.env == 'target':
        if not args.rootfs:
            parser.error('target shell requires an extracted --rootfs')
        RFS = args.rootfs.resolve()
        SHELL = ['qemu-aarch64', str(RFS / 'bin/busybox'), 'sh']
    unittest.main(argv=[__file__], verbosity=2)
