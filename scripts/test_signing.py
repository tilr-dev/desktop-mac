"""Secure timestamp failures retry; permanent signing failures never do."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release


class SigningTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / 'release-packaging.json').write_text(json.dumps({
            'codesign_attempts': 3, 'codesign_retry_delay_seconds': 5,
        }))
        self.enterContext(patch.object(release, 'ROOT', self.root))
        self.log = self.enterContext(contextlib.redirect_stderr(io.StringIO()))
        self.sleep = self.enterContext(patch.object(release.time, 'sleep'))
        self.identity = 'Developer ID Application: Test (TEAM)'
        self.ok = subprocess.CompletedProcess([], 0, stderr='signed\n')

    def error(self, message):
        return subprocess.CalledProcessError(1, ['codesign'], stderr=message)

    def test_transient_timestamp_retries_identical_secure_command(self):
        with patch.object(release, 'run', side_effect=[
            self.error('Autoupdate: A timestamp was expected but was not found\n'), self.ok,
        ]) as run:
            release.sign(Path('Tilr.app'), self.identity, Path('Tilr.entitlements'))
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args_list[0], run.call_args_list[1])
        self.assertIn('--timestamp', run.call_args.args)
        self.assertIn('--entitlements', run.call_args.args)
        self.sleep.assert_called_once_with(5)
        self.assertIn('attempt 2/3', self.log.getvalue())
        self.assertIn('signed', self.log.getvalue())

    def test_timestamp_retries_are_bounded(self):
        error = self.error('A timestamp was expected but was not found')
        with patch.object(release, 'run', side_effect=error) as run:
            with self.assertRaises(subprocess.CalledProcessError) as caught:
                release.sign('Autoupdate', self.identity)
        self.assertIs(caught.exception, error)
        self.assertEqual(run.call_count, 3)
        self.assertEqual(self.sleep.call_count, 2)

    def test_identity_and_keychain_failures_are_not_retried(self):
        for message in ('The specified item could not be found in the keychain.',
                        'User interaction is not allowed.', 'code object is not signed at all'):
            with self.subTest(message=message), patch.object(release, 'run', side_effect=self.error(message)) as run:
                with self.assertRaises(subprocess.CalledProcessError):
                    release.sign('Autoupdate', self.identity)
                run.assert_called_once()
        self.sleep.assert_not_called()

    def test_success_does_not_retry(self):
        with patch.object(release, 'run', return_value=self.ok) as run:
            release.sign('Tilr.dmg', self.identity)
        run.assert_called_once()
        self.sleep.assert_not_called()

    def test_preview_remains_offline(self):
        (self.root / 'release-packaging.json').unlink()
        with patch.object(release, 'run') as run:
            release.sign('Tilr.app', '-')
        run.assert_called_once_with('codesign', '--force', '--sign', '-', 'Tilr.app')
        self.sleep.assert_not_called()

    def test_invalid_retry_policy_fails_before_signing(self):
        for attempts, delay in ((0, 5), (True, 5), (11, 5), (3, -1), (3, float('nan'))):
            (self.root / 'release-packaging.json').write_text(json.dumps({
                'codesign_attempts': attempts, 'codesign_retry_delay_seconds': delay,
            }))
            with self.subTest(attempts=attempts, delay=delay), patch.object(release, 'run') as run:
                with self.assertRaises(ValueError):
                    release.sign('Tilr.app', self.identity)
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
