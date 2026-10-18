#!/usr/bin/env python3
"""Exercise init lifecycle cancellation with fake UCI/procd and real files."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
INIT = REPO / 'overlay/target/linux/qualcommax/ipq50xx/base-files/etc/init.d/rd03v2-watchdog'
SHELL = ['/bin/sh']
RFS = None


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='v2-init-fixture-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / 'tmp/rd03v2-watchdog'
        self.evidence = self.root / 'overlay/rd03v2-watchdog'
        self.options = self.root / 'options'
        self.bin = self.root / 'bin'
        for path in (self.state, self.evidence, self.options, self.bin, self.root / 'etc'):
            path.mkdir(parents=True, exist_ok=True)
        for name in ('reboot-pending', 'reboot-issued', 'hold-reason', 'q6-pending', 'q6-cursor', 'watchdog-boot'):
            (self.state / name).write_text('original-' + name)
        for name in ('rebooted', 'dead-reboots'):
            (self.evidence / name).write_text('original-' + name)
        (self.options / 'enabled').write_text('1')
        (self.options / 'dryrun').write_text('0')
        uci = self.bin / 'uci'
        uci.write_text('#!/bin/sh\ncase "$*" in\n*main.enabled) cat "$ROOT/options/enabled";;\n'
                       '*main.dryrun) cat "$ROOT/options/dryrun";;\n*) exit 2;;\nesac\n')
        uci.chmod(0o755)
        if RFS:
            for name in ('rm', 'mkdir', 'mv', 'sync'):
                path = self.bin / name
                path.write_text('#!/bin/sh\nexec qemu-aarch64 "$QEMU_LD_PREFIX/bin/busybox" ' + name + ' "$@"\n')
                path.chmod(0o755)

    def call(self, function='start_service', action='reload'):
        code = '''
procd_open_instance() { echo opened >> "$ROOT/procd.calls"; }
procd_set_param() { echo "$*" >> "$ROOT/procd.calls"; }
procd_close_instance() { echo closed >> "$ROOT/procd.calls"; }
procd_add_reload_trigger() { :; }
. "$INIT"
"$FUNCTION"
'''
        environment = {**os.environ, 'ROOT': str(self.root), 'INIT': str(INIT), 'FUNCTION': function,
                       'action': action, 'PATH': str(self.bin) + ':/usr/bin:/bin'}
        if RFS:
            environment['QEMU_LD_PREFIX'] = str(RFS)
        subprocess.run(SHELL + ['-c', code], env=environment, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def canceled(self, root_incident=False):
        for name in ('reboot-pending', 'reboot-issued', 'hold-reason'):
            self.assertFalse((self.state / name).exists(), name)
        self.assertFalse((self.evidence / 'rebooted').exists())
        self.assertEqual((self.state / 'q6-pending').exists(), not root_incident)
        self.assertEqual((self.state / 'q6-cursor').read_text(), 'original-q6-cursor')
        self.assertEqual((self.state / 'watchdog-boot').read_text(), 'original-watchdog-boot')
        self.assertEqual((self.evidence / 'dead-reboots').read_text(), 'original-dead-reboots')

    def test_disabled_config_reload_cancels_without_sample(self):
        (self.options / 'enabled').write_text('0'); self.call(); self.canceled(root_incident=True)
        self.assertFalse((self.root / 'procd.calls').exists())

    def test_dryrun_reload_cancels_reboot_keeps_diagnostics(self):
        (self.options / 'dryrun').write_text('1'); self.call(); self.canceled()
        self.assertIn('command /usr/sbin/rd03v2-watchdog', (self.root / 'procd.calls').read_text())

    def test_disable_file_cancels_before_instance_removal(self):
        (self.root / 'etc/rd03v2-watchdog.disable').touch(); self.call(); self.canceled(root_incident=True)
        self.assertFalse((self.root / 'procd.calls').exists())

    def test_explicit_stop_cancels_held_reboot(self):
        self.call('stop_service', 'stop'); self.canceled()

    def test_explicit_restart_cancels_held_reboot(self):
        self.call('stop_service', 'restart'); self.canceled()

    def test_shutdown_preserves_genuine_receipt_and_budgets(self):
        self.call('stop_service', 'shutdown')
        for name in ('reboot-pending', 'reboot-issued', 'hold-reason', 'q6-pending', 'q6-cursor', 'watchdog-boot'):
            self.assertEqual((self.state / name).read_text(), 'original-' + name)
        self.assertEqual((self.evidence / 'rebooted').read_text(), 'original-rebooted')
        self.assertEqual((self.evidence / 'dead-reboots').read_text(), 'original-dead-reboots')

    def test_live_respawn_preserves_pending_incident(self):
        self.call()
        self.assertTrue((self.state / 'reboot-pending').exists())
        self.assertTrue((self.state / 'q6-pending').exists())

    def test_reboot_receipt_consumed_even_when_disabled(self):
        (self.state / 'reboot-pending').unlink(); (self.state / 'reboot-issued').unlink()
        (self.options / 'enabled').write_text('0'); self.call()
        self.assertFalse((self.evidence / 'rebooted').exists())
        self.assertEqual((self.state / 'watchdog-boot').read_text(), 'original-rebooted')
        self.assertEqual((self.evidence / 'dead-reboots').read_text(), 'original-dead-reboots')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--init', type=Path, default=INIT)
    parser.add_argument('--env', choices=('host', 'target'), default='host')
    parser.add_argument('--rootfs', type=Path)
    args = parser.parse_args()
    INIT = args.init.resolve()
    if args.env == 'target':
        if not args.rootfs:
            parser.error('target shell requires an extracted --rootfs')
        RFS = args.rootfs.resolve()
        SHELL = ['qemu-aarch64', str(RFS / 'bin/busybox'), 'sh']
    unittest.main(argv=[__file__], verbosity=2)
