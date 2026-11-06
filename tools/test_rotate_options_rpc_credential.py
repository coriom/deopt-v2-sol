#!/usr/bin/env python3
"""Local tests; no real Alchemy endpoint is contacted."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import rotate_options_rpc_credential as rotation


class FakeResponse:
    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, *_args):
        return json.dumps({"result": rotation.CHAIN_ID}).encode()


class RotationTests(unittest.TestCase):
    def test_validation_rejects_wrong_host_and_inline_credentials(self):
        rotation.validate_url("https://base-sepolia.g.alchemy.com/v2/abcdefghijkl")
        for value in ("http://base-sepolia.g.alchemy.com/v2/abcdefghijkl",
                      "https://other.example/v2/abcdefghijkl",
                      "https://user:pass@base-sepolia.g.alchemy.com/v2/abcdefghijkl"):
            with self.assertRaises(ValueError):
                rotation.validate_url(value)

    def test_atomic_update_changes_only_rpc_and_stays_private(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / ".env.base-sepolia"
            original = "OTHER=value\nRPC_URL=old\nANOTHER=value\n"
            path.write_text(original)
            rotation.write_private(path, rotation.replace_rpc_line(original, "new"))
            self.assertEqual(path.read_text(), "OTHER=value\nRPC_URL=new\nANOTHER=value\n")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    @mock.patch.object(rotation.request, "urlopen", return_value=FakeResponse())
    def test_chain_id_check(self, _urlopen):
        self.assertEqual(rotation.rpc_status("https://base-sepolia.g.alchemy.com/v2/abcdefghijkl"), "PASS")


if __name__ == "__main__":
    unittest.main()
