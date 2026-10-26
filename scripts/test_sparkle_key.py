import base64
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import publish

# RFC 8032, section 7.1, test 1.
SEED = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
PUBLIC = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")


class SparkleKeyFileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.file = Path(self.temp.name) / "sparkle.key"

    def public_key(self, contents):
        self.file.write_text(base64.b64encode(contents).decode() + "\n")
        with patch.dict(os.environ, {"TILR_SPARKLE_KEY_FILE": str(self.file)}):
            return publish.sparkle_public_key(Path("/nonexistent"))

    def test_keychain_account_without_a_key_file(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("TILR_SPARKLE_KEY_FILE", None)
            self.assertEqual(publish.sparkle_key(), ["--account", "tilr-rexuni"])

    def test_key_file_replaces_the_keychain_account(self):
        with patch.dict(os.environ, {"TILR_SPARKLE_KEY_FILE": str(self.file)}):
            self.assertEqual(publish.sparkle_key(), ["--ed-key-file", str(self.file)])

    def test_public_key_of_a_seed_file(self):
        self.assertEqual(self.public_key(SEED), base64.b64encode(PUBLIC).decode())

    def test_public_key_of_a_legacy_expanded_key_file(self):
        self.assertEqual(self.public_key(bytes(64) + PUBLIC), base64.b64encode(PUBLIC).decode())


if __name__ == "__main__":
    unittest.main()
