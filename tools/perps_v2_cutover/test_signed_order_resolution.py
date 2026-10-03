"""Pure, deterministic checks for signed-order reconstruction and expiry."""
import unittest

import signed_order_resolution as r


def fixture():
    return {
        'intent_id': '5f98818a-4db8-444c-a417-8056cf3279db',
        'buyer': '0x1111111111111111111111111111111111111111',
        'seller': '0x2222222222222222222222222222222222222222',
        'market_id': 1, 'size_1e8': '1000', 'price_1e8': '3000000',
        'max_execution_price_1e8': '0', 'min_execution_price_1e8': '0',
        'buyer_is_maker': True, 'buyer_nonce': 0, 'seller_nonce': 0,
        'deadline_ms': 1789967348000,
    }


class SignedOrderResolutionTest(unittest.TestCase):
    def test_exact_ms_to_seconds(self):
        self.assertEqual(r.payload(fixture())['deadline'], 1789967348)
        bad = fixture()
        bad['deadline_ms'] += 1
        with self.assertRaisesRegex(ValueError, 'whole seconds'):
            r.payload(bad)

    def test_zero_equality_expired_and_future(self):
        self.assertFalse(r.deadline_expired(0, 1900000000))
        self.assertFalse(r.deadline_expired(100, 100))
        self.assertFalse(r.deadline_expired(101, 100))
        self.assertTrue(r.deadline_expired(99, 100))

    def test_live_domain_and_payload_bind_digest(self):
        row = fixture()
        d = r.trade_digest(row, r.domain())
        self.assertNotEqual(d, r.trade_digest(row, r.domain(contract=row['buyer'])))
        self.assertNotEqual(d, r.trade_digest(row, r.domain(chain_id=1)))
        changed = fixture()
        changed['buyer_is_maker'] = False
        self.assertNotEqual(d, r.trade_digest(changed, r.domain()))

    def test_missing_required_field_fails_closed(self):
        row = fixture()
        del row['max_execution_price_1e8']
        with self.assertRaisesRegex(ValueError, 'UNRESOLVED_PAYLOAD'):
            r.payload(row)

    def test_nonce_relation_and_malformed_signature(self):
        self.assertEqual([r.nonce_relation(x, 2) for x in (1, 2, 3)],
                         ['PAST', 'MATCH', 'FUTURE'])
        self.assertIsNone(r.recover(b'\0'*32, '0x' + '00'*65))
        self.assertIsNone(r.recover(b'\0'*32, None))


if __name__ == '__main__':
    unittest.main()
