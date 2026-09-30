"""Offline receipt-boundary tests. Fixtures are not public transaction evidence."""
import copy
import json
import unittest

from migration_reseal_execute import OUT, OWNER, NEW, SNAPSHOT, validate_receipt


class SealReceiptTests(unittest.TestCase):
    def setUp(self):
        self.preview = json.loads((OUT/'transaction_preview.json').read_text())
        self.event = json.loads((OUT/'preflight.json').read_text())['expectedEvent']
        self.tx_hash = 'unit-test-fixture-not-a-public-transaction'
        self.tx = {'hash': self.tx_hash, 'from': OWNER, 'to': NEW, 'nonce': hex(807),
                   'chainId': hex(84532), 'value': '0x0', 'input': self.preview['calldata'],
                   'gas': hex(75000), 'maxFeePerGas': hex(11000000),
                   'maxPriorityFeePerGas': hex(1000000), 'blockHash': '0x01', 'blockNumber': '0x01'}
        self.receipt = {'transactionHash': self.tx_hash, 'status': '0x1', 'from': OWNER, 'to': NEW,
                        'blockHash': '0x01', 'blockNumber': '0x01',
                        'logs': [{'address': NEW, 'topics': self.event['topics'], 'data': SNAPSHOT}]}
        self.block = {'hash': '0x01', 'number': '0x01', 'transactions': [self.tx_hash]}

    def check(self, receipt, tx):
        validate_receipt(receipt, tx, self.block, self.tx_hash, self.preview, self.event)

    def test_accepts_exact_boundary_fixture(self):
        self.check(self.receipt, self.tx)

    def test_rejects_fourteen_transaction_receipt_or_event_mutations(self):
        cases = [('tx', 'from', NEW), ('tx', 'to', OWNER), ('tx', 'nonce', hex(808)),
                 ('tx', 'chainId', hex(1)), ('tx', 'value', '0x1'), ('tx', 'input', '0x00'),
                 ('tx', 'gas', hex(75001)), ('tx', 'maxFeePerGas', hex(12000000)),
                 ('receipt', 'status', '0x0'), ('receipt', 'blockHash', '0x00'),
                 ('receipt', 'logs', []),
                 ('receipt', 'logs', [{'address': OWNER, 'topics': self.event['topics'], 'data': SNAPSHOT}]),
                 ('receipt', 'logs', [{'address': NEW, 'topics': self.event['topics'], 'data': '0x00'}]),
                 ('receipt', 'logs', [{'address': NEW, 'topics': [self.event['topics'][0], '0x00'], 'data': SNAPSHOT}])]
        for index, (target, key, value) in enumerate(cases):
            with self.subTest(case=index, target=target, field=key):
                receipt, tx = copy.deepcopy(self.receipt), copy.deepcopy(self.tx)
                (tx if target == 'tx' else receipt)[key] = value
                with self.assertRaises(AssertionError): self.check(receipt, tx)


if __name__ == '__main__':
    unittest.main()
