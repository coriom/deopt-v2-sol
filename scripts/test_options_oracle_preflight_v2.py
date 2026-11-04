#!/usr/bin/env python3
"""Regression checks for pinned Options oracle preflight arithmetic and fail-closed rules."""

import unittest

from options_oracle_preflight_v2 import SELECTORS, deviation_bps, direct_expected, normalize_1e8, signed, words


class OraclePreflightTests(unittest.TestCase):
    def test_selectors_match_router_and_adapters(self):
        self.assertEqual(SELECTORS["getFeed"], "d2edb6dd")
        self.assertEqual(SELECTORS["getPriceUnsafe"], "96834ad3")
        self.assertEqual(SELECTORS["pyth"], "f98d06f0")
        self.assertEqual(SELECTORS["priceId"], "31189334")

    def test_v1_divergence_fail_closed(self):
        self.assertEqual(deviation_bps(243815000000, 239814700144), 166)
        self.assertEqual(deviation_bps(8007280000000, 7908869148801), 124)
        self.assertEqual(direct_expected(243815000000, 1793804697, 239814700144,
                                         1793804581, 1793804706, 1500, 100, True, False),
                         (0, 0, False))

    def test_v2_convergence_accepts_normal_feed(self):
        self.assertEqual(deviation_bps(243219440504, 243167907196), 2)
        self.assertEqual(direct_expected(243219440504, 1793806105, 243167907196,
                                         1793806100, 1793806153, 1500, 100, True, False),
                         (243219440504, 1793806100, True))

    def test_exact_100_bps_boundary_matches_router(self):
        self.assertEqual(deviation_bps(10_100, 10_000), 100)
        self.assertEqual(deviation_bps(10_101, 10_000), 101)
        self.assertTrue(direct_expected(10_100, 99, 10_000, 99, 100, 30, 100, True, False)[2])
        self.assertFalse(direct_expected(10_101, 99, 10_000, 99, 100, 30, 100, True, False)[2])

    def test_stale_future_paused_and_fallback(self):
        self.assertEqual(direct_expected(100, 10, 101, 200, 2000, 1500, 100,
                                         True, False), (0, 0, False))
        self.assertEqual(direct_expected(100, 2001, 101, 1999, 2000, 1500, 100,
                                         True, False), (101, 1999, True))
        self.assertEqual(direct_expected(100, 1999, 101, 1999, 2000, 1500, 100,
                                         True, True), (0, 0, False))

    def test_signed_pyth_fields_and_malformed_abi(self):
        self.assertEqual(normalize_1e8(243167907196, -8), 243167907196)
        self.assertEqual(normalize_1e8(24316790719600, -10), 243167907196)
        self.assertEqual(normalize_1e8(2431679071, -6), 243167907100)
        self.assertEqual(signed("f" * 64, 32), -1)
        self.assertEqual(signed("f" * 64, 64), -1)
        with self.assertRaises(ValueError):
            words("0x1234")


if __name__ == "__main__":
    unittest.main()
