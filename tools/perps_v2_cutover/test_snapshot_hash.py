"""Hash regression tests; read canonical CBOR without regenerating it."""
import hashlib
from pathlib import Path
import unittest
from unittest.mock import patch

from snapshot_hash import keccak256


class EthereumHashTest(unittest.TestCase):
    def test_ethereum_golden_vectors(self):
        for data, expected in [
            (b"", "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"),
            (b"abc", "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"),
        ]:
            with self.subTest(data=data):
                self.assertEqual(keccak256(data).hex(), expected)
                self.assertNotEqual(keccak256(data), hashlib.sha3_256(data).digest())

    def test_cast_fallback_without_python_hash_packages(self):
        with patch.dict("sys.modules", {"sha3": None, "Crypto": None}):
            self.assertEqual(
                keccak256(b"").hex(),
                "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
            )

    def test_missing_ethereum_provider_fails_closed(self):
        with patch.dict("sys.modules", {"sha3": None, "Crypto": None}):
            with patch("snapshot_hash.subprocess.run", side_effect=FileNotFoundError):
                with self.assertRaises(RuntimeError):
                    keccak256(b"abc")

    def test_existing_canonical_cbor(self):
        path = Path(__file__).resolve().parents[2] / "artifacts/perps_v2_final_snapshot/manifest.cbor"
        self.assertEqual(
            keccak256(path.read_bytes()).hex(),
            "039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d",
        )


if __name__ == "__main__":
    unittest.main()
