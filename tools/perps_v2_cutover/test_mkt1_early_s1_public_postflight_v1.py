"""Offline consistency checks for the independently fetched MKT1 S1 public evidence."""

import hashlib
import json
import unittest
from pathlib import Path

from eth_abi import encode
from eth_utils import keccak

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / 'artifacts/perps_v2_replacement_deployment'


def read(name):
    return json.loads((ART / name).read_text())


class Mkt1PublicPostflight(unittest.TestCase):
    def setUp(self):
        self.e = read('mkt1_inactive_early_s1_public_postflight_v1.json')
        self.review = read('mkt1_inactive_early_s1_final_review_v1.json')

    def test_identity_and_operation_hash_are_independent(self):
        e, r = self.e, self.review
        self.assertEqual(e['chainId'], 84532)
        self.assertEqual(e['receipt']['status'], 1)
        self.assertEqual(e['receipt']['blockHash'], e['canonicalBlock']['hash'])
        self.assertEqual(e['safe']['executionSuccessSafeTxHash'], r['safeTxHashConditionalAtObservedNonce'])
        self.assertEqual(e['safe']['executionFailureCount'], 0)
        self.assertTrue(e['safe']['oneCallToTimelock'])
        self.assertEqual(e['safe']['safeEventOuterCalldataKeccak256'],
                         '0x' + keccak(bytes.fromhex(r['outerCalldata'][2:])).hex())
        inner = bytes.fromhex(r['innerCalldata'][2:])
        operation = '0x' + keccak(encode(['address', 'uint256', 'bytes', 'uint256'],
                                        [r['target'], 0, inner, r['eta']])).hex()
        self.assertEqual(e['timelock']['operationId'], operation)
        self.assertEqual(e['timelock']['recomputedOperationId'], operation)
        self.assertEqual(e['timelock']['innerCalldataKeccak256'], '0x' + keccak(inner).hex())
        self.assertEqual(e['timelock']['schedulingMarginBeyondMinDelaySeconds'],
                         r['eta'] - e['canonicalBlock']['timestamp'] - e['timelock']['minDelaySeconds'])
        self.assertGreaterEqual(e['timelock']['schedulingMarginBeyondMinDelaySeconds'], 3600)

    def test_queued_without_economic_mutation(self):
        e = self.e
        self.assertEqual((e['safe']['preNonce'], e['safe']['postNonce'], e['safe']['reviewNonce']),
                         (42, 43, 43))
        self.assertEqual((e['timelock']['stateBefore'], e['timelock']['stateAtReceipt'],
                          e['timelock']['stateAtReview']),
                         ('ABSENT', 'QUEUED', 'QUEUED_NOT_READY_NOT_EXECUTED'))
        self.assertEqual(e['boundedEconomicNonDrift']['before'], e['boundedEconomicNonDrift']['atReceipt'])
        self.assertEqual(e['boundedEconomicNonDrift']['atReceipt'], e['boundedEconomicNonDrift']['atReview'])
        for key in ('before', 'atReceipt', 'atReview'):
            state = e['maintenance'][key]
            self.assertEqual(state['d1_total_markets'], 0)
            self.assertFalse(state['d1_market1_exists'])
            self.assertTrue(state['c02_queued'])
            self.assertTrue(all(state[f'd4_{mode}_paused'] for mode in
                                ('trading', 'liquidation', 'funding', 'collateral')))
            self.assertTrue(state['d6_paused'])
            self.assertFalse(state['vault_d4_authorized'] or state['insurance_d4_backstop'])
        self.assertFalse(e['nextGate']['publicActionAuthorized'])

    def test_artifact_integrity_and_conditional_s2_intents(self):
        e = self.e
        self.assertEqual(e['artifactIntegrity']['s1ReviewSha256'], hashlib.sha256(
            (ART / 'mkt1_inactive_early_s1_final_review_v1.json').read_bytes()).hexdigest())
        self.assertEqual(e['artifactIntegrity']['builderSha256'], hashlib.sha256(
            (ROOT / self.review['builderPath']).read_bytes()).hexdigest())
        self.assertEqual(e['artifactIntegrity']['approvedDagSha256'], hashlib.sha256(
            (ROOT / self.review['approvedDagPath']).read_bytes()).hexdigest())
        c02, mkt1 = e['conditionalFutureExecutionIntents']
        self.assertEqual(c02['operationId'], '0x9e10ee1c04280e36ba1d7144b5abd2d1a48b08fac54087bd5e7090d91030913e')
        self.assertEqual(mkt1['operationId'], self.review['operationId'])
        self.assertEqual(mkt1['eta'], self.review['eta'])
        self.assertTrue(all(item['authorization'] == 'NOT_AUTHORIZED_CONDITIONAL_INTENT_ONLY'
                            for item in (c02, mkt1)))


if __name__ == '__main__':
    unittest.main()
