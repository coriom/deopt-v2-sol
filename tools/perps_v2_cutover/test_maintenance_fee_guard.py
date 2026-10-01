"""Focused boundary and no-send tests for the continuation fee guard."""

import tempfile
from pathlib import Path
import unittest

from maintenance_fee_guard import FeeGuardStop, decide, guarded_send


BLOCK = {'number': 47494795, 'hash': '0x' + '12' * 32, 'timestamp': 1789900000}
POLICY = {'oracleUnsignedTxSizeBytes': 512, 'l2GasEstimate': 36905,
          'gasLimit': 47977, 'maxFeePerGasWei': 11000000,
          'maxPriorityFeePerGasWei': 1000000, 'l1BoundMultiplierNumerator': 2,
          'l1BoundMultiplierDenominator': 1, 'l1AllowanceWei': 100,
          'additionalFeeAllowanceWei': 0,
          'totalPlanningBudgetWei': 47977 * 11000000 + 100}
OBSERVED = {'observed_base_fee_wei': 5000000,
            'observed_priority_fee_wei': 1000000,
            'observed_gas_price_wei': 6000000,
            'observed_gas_estimate': 36905}


class FeeGuardTests(unittest.TestCase):
    def test_below(self):
        self.assertEqual(decide(block=BLOCK, quote=49, additional_fee_quote_wei=0,
                                **OBSERVED, policy=POLICY,
                                balance_wei=10**15)['result'], 'PASS')

    def test_equal(self):
        self.assertEqual(decide(block=BLOCK, quote=50, additional_fee_quote_wei=0,
                                **OBSERVED, policy=POLICY,
                                balance_wei=10**15)['result'], 'PASS')

    def test_above(self):
        result = decide(block=BLOCK, quote=51, additional_fee_quote_wei=0,
                        **OBSERVED, policy=POLICY, balance_wei=10**15)
        self.assertEqual(result['reason'], 'L1_BOUND_EXCEEDS_APPROVED_ALLOWANCE')
        self.assertEqual(result['scaledL1BoundWei'], 102)

    def test_additional_fee_above_allowance(self):
        result = decide(block=BLOCK, quote=49, additional_fee_quote_wei=1,
                        **OBSERVED, policy=POLICY, balance_wei=10**15)
        self.assertEqual(result['reason'], 'ADDITIONAL_FEE_EXCEEDS_APPROVED_ALLOWANCE')

    def test_missing_or_malformed_quote(self):
        for value in (None, '50', -1, 50.0):
            with self.subTest(value=value):
                self.assertEqual(decide(block=BLOCK, quote=value, additional_fee_quote_wei=0,
                                        **OBSERVED, policy=POLICY,
                                        balance_wei=10**15)['reason'], 'MALFORMED_FEE_INPUT')

    def test_failure_never_invokes_send_and_persists_stop(self):
        with tempfile.TemporaryDirectory() as directory:
            called = []
            path = Path(directory) / 'decision.json'
            with self.assertRaises(FeeGuardStop):
                guarded_send(path=path, block=BLOCK, quote=51, additional_fee_quote_wei=0,
                             **OBSERVED, policy=POLICY,
                             balance_wei=10**15, send=lambda: called.append(True))
            self.assertEqual(called, [])
            self.assertIn('L1_BOUND_EXCEEDS_APPROVED_ALLOWANCE', path.read_text())

    def test_persist_failure_never_invokes_send(self):
        with tempfile.TemporaryDirectory() as directory:
            called = []
            with self.assertRaises(FeeGuardStop):
                guarded_send(path=Path(directory) / 'missing' / 'decision.json',
                             block=BLOCK, quote=49, additional_fee_quote_wei=0,
                             **OBSERVED, policy=POLICY, balance_wei=10**15,
                             send=lambda: called.append(True))
            self.assertEqual(called, [])

    def test_network_price_drift_stops(self):
        observed = {**OBSERVED, 'observed_base_fee_wei': 6000000}
        result = decide(block=BLOCK, quote=49, additional_fee_quote_wei=0,
                        **observed, policy=POLICY, balance_wei=10**15)
        self.assertEqual(result['reason'], 'NETWORK_GAS_PRICE_EXCEEDS_APPROVED_CAP')


if __name__ == '__main__':
    unittest.main()
