"""Fail-closed tests for the replay package, with no network or signing."""
import copy
import json
import unittest
from unittest.mock import patch

import migration_replay as replay


class ReplayPackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = json.loads((replay.SOURCE / 'seed_calldata.json').read_text())
        cls.manifest = json.loads((replay.SOURCE / 'manifest.json').read_text())
        cls.artifact = json.loads((replay.ROOT / 'out/PerpEngineV2.sol/PerpEngineV2.json').read_text())
        cls.package = json.loads((replay.DESTINATION / 'execution_package.json').read_text())

    def validate(self, package):
        return replay.validate_steps(self.original, package, self.manifest, self.artifact)

    def test_real_package_decodes_all_eight(self):
        rows = self.validate(self.package)
        self.assertEqual([r['nonce'] for r in rows], list(range(799, 807)))
        self.assertTrue(all(r['calldataIdentical'] for r in rows))

    def test_existing_cbor_semantically_matches_without_encoding(self):
        import cbor2
        with patch.object(cbor2, 'dumps', side_effect=AssertionError('CBOR regeneration forbidden')):
            manifest, _ = replay.verify_canonical()
        self.assertEqual(manifest, self.manifest)

    def test_rejects_wrong_chain(self):
        package = copy.deepcopy(self.package); package['chainId'] = 8453
        with self.assertRaises(ValueError): self.validate(package)

    def test_rejects_wrong_snapshot(self):
        package = copy.deepcopy(self.package); package['snapshotHash'] = '0x' + '00' * 32
        with self.assertRaises(ValueError): self.validate(package)

    def test_rejects_stale_nonce(self):
        package = copy.deepcopy(self.package); package['startingNonce'] = 790
        with self.assertRaises(ValueError): self.validate(package)

    def test_rejects_shared_dependency_target(self):
        package = copy.deepcopy(self.package); package['orderedSteps'][0]['target'] = replay.OLD
        with self.assertRaises(ValueError): self.validate(package)

    def test_rejects_value_transfer(self):
        package = copy.deepcopy(self.package); package['orderedSteps'][0]['value'] = 1
        with self.assertRaises(ValueError): self.validate(package)

    def test_rejects_changed_economic_calldata(self):
        package = copy.deepcopy(self.package)
        step = package['orderedSteps'][0]; step['calldata'] = step['calldata'][:-1] + 'b'
        with self.assertRaises(ValueError): self.validate(package)

    def test_rejects_seal_selector(self):
        package = copy.deepcopy(self.package); package['orderedSteps'][0]['signature'] = 'sealMigration(bytes32)'
        with self.assertRaises(ValueError): self.validate(package)

    def test_rejects_extra_or_missing_step(self):
        for length in [7, 9]:
            package = copy.deepcopy(self.package)
            package['orderedSteps'] = (package['orderedSteps'] * 2)[:length]
            with self.assertRaises(ValueError): self.validate(package)

    def test_rejects_wrong_source_block(self):
        package = copy.deepcopy(self.package); package['snapshotBlockNumber'] += 1
        with self.assertRaises(ValueError): self.validate(package)


if __name__ == '__main__':
    unittest.main()
