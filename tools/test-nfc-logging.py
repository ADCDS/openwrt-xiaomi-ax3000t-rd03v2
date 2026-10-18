#!/usr/bin/env python3
"""Exercise the NFC transfer function with synthetic I2C failures, without hardware."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / 'overlay/target/linux/qualcommax/ipq50xx/base-files/usr/sbin/nfc'
TRANSFER = re.search(r'^xfer\(\) \{\n.*?^\}', SOURCE.read_text(), re.M | re.S).group()


class TransferLogging(unittest.TestCase):
    def run_transfer(self, implementation):
        with tempfile.TemporaryDirectory(prefix='nfc-log-test-') as directory:
            root = Path(directory)
            script = """BUS=0; ADDR=0x57
logger() { printf '%s\n' "$*" >> "$NFC_TEST_LOG"; }
""" + implementation + '\n' + TRANSFER + '\nxfer w6@0x57 0 16 0x50 0x53 0x4b 0x21\n'
            import os
            result = subprocess.run(['/bin/sh', '-c', script], text=True, capture_output=True,
                                    env={**os.environ, 'NFC_TEST_LOG': str(root / 'log'),
                                         'NFC_TEST_CALLS': str(root / 'calls')}, timeout=5)
            log = (root / 'log').read_text() if (root / 'log').exists() else ''
            calls = len((root / 'calls').read_text().splitlines())
            return result, log, calls

    def test_error_arguments_and_output_are_private(self):
        result, log, calls = self.run_transfer('''i2ctransfer() {
 echo called >> "$NFC_TEST_CALLS"
 echo "WIRELESS-PAYLOAD-TOKEN $*" >&2
 return 7
}''')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, 1)
        combined = result.stdout + result.stderr + log
        for secret in ('WIRELESS-PAYLOAD-TOKEN', '0x50', '0x53', 'w6@'):
            self.assertNotIn(secret, combined)
        self.assertIn('bus 0, address 0x57, status 7', combined)

    def test_nack_retry_is_bounded_and_redacted(self):
        result, log, calls = self.run_transfer('''i2ctransfer() {
 echo called >> "$NFC_TEST_CALLS"
 echo 'No such device or address: WIRELESS-PAYLOAD-TOKEN' >&2
 return 6
}''')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, 20)
        self.assertNotIn('WIRELESS-PAYLOAD-TOKEN', result.stderr + log)
        self.assertIn('status 6', log)

    def test_successful_read_output_is_preserved(self):
        result, log, calls = self.run_transfer('''i2ctransfer() {
 echo called >> "$NFC_TEST_CALLS"
 echo '0xe1 0x10 0x6d'
 return 0
}''')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), '0xe1 0x10 0x6d')
        self.assertEqual(calls, 1)
        self.assertEqual(log, '')


if __name__ == '__main__':
    unittest.main(verbosity=2)
