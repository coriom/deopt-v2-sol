#!/usr/bin/env python3
"""Read-only verification of the two operator-submitted Safe queue transactions.

Never signs, sends, touches the database, or persists Safe signature bytes.
Writes evidence only after all receipt, event, and state checks pass.
"""
import datetime as dt
import hashlib
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
import migration_reseal_preflight as migration
import maintenance_lock_preflight as maintenance
from governance_prepare import decoded_address_array, abi_words

ROOT = migration.ROOT
SOURCE = ROOT / 'artifacts/perps_v2_recovery_governance_prepare'
OUT = ROOT / 'artifacts/perps_v2_recovery_governance_queue'
SAFE = '0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46'
TIMELOCK = maintenance.TIMELOCK
TXS = (
    ('G1', 'g1_insurance_safe_review_manifest.json',
     '0x7b68dfe378952e2eae86915e1ae908027293506397443de5ba01b8de9fb68eb9',
     '0x98871782d3c1ca79e9e85504aff45f2974044054c00dc791a1b49f85afa90a51',
     47613107, 1790994502, 15, 'isBackstopCaller(address)'),
    ('G2', 'g2_vault_safe_review_manifest.json',
     '0x4bab77791496f15524f9a5a5b602e6e8369bbc636bef6400e3cfd73b332c354e',
     '0xfbcdb5ab155b4756f76d7d5ba329dd776b6dbd7807d9461d97708c4ff8ddc68f',
     47613842, 1790995972, 16, 'isAuthorizedEngine(address)'),
)
SAFE_SUCCESS = '0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e'
TIMELOCK_QUEUED = '0x4efebf40a8244d219085e74f928a18e8c9d17adc6b39270b8706cca0a92b648d'


def utc(value):
    return dt.datetime.fromtimestamp(value, dt.timezone.utc).isoformat()


def decode_safe_input(value):
    assert value[:10].lower() == '0x6a761202', 'Unexpected Safe selector'
    raw = bytes.fromhex(value[10:])
    assert len(raw) >= 320

    def number(index):
        return int.from_bytes(raw[32*index:32*(index+1)], 'big')

    def address(index):
        return '0x' + raw[32*index+12:32*(index+1)].hex()

    def dynamic_length(offset):
        assert offset % 32 == 0 and offset + 32 <= len(raw)
        length = int.from_bytes(raw[offset:offset+32], 'big')
        assert offset + 32 + length <= len(raw)
        return length

    data_offset = number(2)
    data_length = dynamic_length(data_offset)
    signature_offset = number(9)
    assert signature_offset > data_offset
    signature_length = dynamic_length(signature_offset)
    assert signature_length >= 65
    return {
        'to': address(0), 'value': number(1),
        'data': '0x' + raw[data_offset+32:data_offset+32+data_length].hex(),
        'operation': number(3), 'safeTxGas': number(4),
        'baseGas': number(5), 'gasPrice': number(6),
        'gasToken': address(7), 'refundReceiver': address(8),
    }


def verify_receipt(ctx, row):
    name, filename, tx_hash, expected_safe_hash, expected_block, expected_time, nonce, getter = row
    rpc, call, calldata = ctx['live'], ctx['call'], ctx['calldata']
    manifest = json.loads((SOURCE / filename).read_text())
    want = manifest['reviewedSafeTxFields']
    tx = rpc('eth_getTransactionByHash', [tx_hash])
    receipt = rpc('eth_getTransactionReceipt', [tx_hash])
    assert tx and receipt, name + ' transaction or receipt missing'
    block = rpc('eth_getBlockByNumber', [receipt['blockNumber'], False])
    assert block and int(block['hash'], 16) != 0
    assert tx['hash'].lower() == receipt['transactionHash'].lower() == tx_hash.lower()
    assert tx['blockHash'].lower() == receipt['blockHash'].lower() == block['hash'].lower()
    assert tx_hash.lower() in [x.lower() for x in block['transactions']]
    block_number = int(block['number'], 16)
    assert int(tx['blockNumber'], 16) == int(receipt['blockNumber'], 16) == block_number == expected_block
    assert int(block['timestamp'], 16) == expected_time
    assert int(receipt['status'], 16) == 1 and int(tx['chainId'], 16) == 84532
    assert tx['to'].lower() == receipt['to'].lower() == SAFE.lower() and int(tx['value'], 16) == 0
    actual = decode_safe_input(tx['input'])
    for field in ('to', 'data', 'gasToken', 'refundReceiver'):
        assert actual[field].lower() == want[field].lower(), name + ' Safe field drift: ' + field
    for field in ('value', 'operation', 'safeTxGas', 'baseGas', 'gasPrice'):
        assert actual[field] == int(want[field]), name + ' Safe field drift: ' + field
    assert nonce == want['nonce'] and actual['to'].lower() == TIMELOCK.lower()
    assert actual['operation'] == 0 and actual['data'].lower() == manifest['outerCalldata'].lower()
    logs = receipt['logs']
    assert len(logs) == 3, name + ' unexpected receipt log count'
    assert [x['address'].lower() for x in logs] == [SAFE.lower(), TIMELOCK.lower(), SAFE.lower()]
    assert logs[1]['topics'][0].lower() == TIMELOCK_QUEUED
    assert logs[2]['topics'][0].lower() == SAFE_SUCCESS
    safe_log = logs[2]
    assert len(safe_log['topics']) == 2 and safe_log['topics'][1].lower() == expected_safe_hash.lower()
    assert len(bytes.fromhex(safe_log['data'][2:])) == 32
    hash_signature = 'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)'
    hash_args = (want['to'], want['value'], want['data'], want['operation'], want['safeTxGas'],
                 want['baseGas'], want['gasPrice'], want['gasToken'], want['refundReceiver'], nonce)
    live_safe_hash = rpc('eth_call', [{'to': SAFE, 'data': calldata(hash_signature, hash_args)}, block['number']])
    assert live_safe_hash.lower() == expected_safe_hash.lower()
    assert call(rpc, SAFE, 'nonce()', tag=hex(block_number-1)) == [nonce]
    assert call(rpc, SAFE, 'nonce()', tag=block['number']) == [nonce+1]

    queued_log = logs[1]
    assert len(queued_log['topics']) == 3
    assert queued_log['topics'][1].lower() == manifest['operationId'].lower()
    assert int(queued_log['topics'][2], 16) == int(manifest['target'], 16)
    data = bytes.fromhex(queued_log['data'][2:])
    assert len(data) >= 128 and int.from_bytes(data[32:64], 'big') == 96
    value = int.from_bytes(data[:32], 'big')
    eta = int.from_bytes(data[64:96], 'big')
    inner_length = int.from_bytes(data[96:128], 'big')
    inner = '0x' + data[128:128+inner_length].hex()
    assert value == 0 and eta == manifest['eta'] == 1791086934
    assert inner.lower() == manifest['innerCalldata'].lower()
    assert len(data) == 96 + 32 + ((inner_length + 31)//32)*32
    encoded = subprocess.check_output(['cast', 'abi-encode', 'f(address,uint256,bytes,uint256)',
                                       manifest['target'], '0', inner, str(eta)], text=True).strip()
    local_id = '0x' + ctx['keccak256'](bytes.fromhex(encoded[2:])).hex()
    assert local_id.lower() == manifest['operationId'].lower()
    chain_id = rpc('eth_call', [{'to': TIMELOCK, 'data': calldata(
        'hashOperation(address,uint256,bytes,uint256)', (manifest['target'], 0, inner, eta))}, block['number']])
    assert chain_id.lower() == local_id.lower()
    delay = call(rpc, TIMELOCK, 'minDelay()', tag=block['number'])[0]
    assert eta >= expected_time + delay and delay == 86400
    assert call(rpc, TIMELOCK, 'queuedTransactions(bytes32)', [local_id], block['number']) == [1]
    assert call(rpc, manifest['target'], getter, [ctx['NEW']], block['number']) == [0]
    return {
        'operation': name, 'publicTxHash': tx_hash, 'safeNonceConsumed': nonce,
        'safeTxHash': expected_safe_hash, 'safeInputFieldsMatchManifest': True,
        'safeSuccessEvent': True, 'canonicalBlock': block_number,
        'canonicalBlockHash': block['hash'], 'blockTimestamp': expected_time,
        'blockUTC': utc(expected_time), 'receiptStatus': 1,
        'transactionReceiptBlockHashesMatch': True, 'transactionInCanonicalBlock': True,
        'timelockEvent': 'TransactionQueued', 'operationId': local_id,
        'target': manifest['target'], 'valueWei': value, 'innerCalldataMatches': True,
        'eta': eta, 'queueDeadline': eta-delay,
        'inclusionMarginSeconds': eta-delay-expected_time,
        'minDelaySeconds': delay, 'queuedAtReceiptBlock': True,
        'targetAuthorizationAtReceiptBlock': False,
        'executionEventAbsent': True, 'safeNonceBefore': nonce,
        'safeNonceAfter': nonce+1, 'receiptLogs': 3,
    }


def main():
    assert not sys.flags.optimize
    assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip() == 'd6e7dbb4ccf10bd7422c0e74f94d7e7c1dca135f'
    report = (ROOT/'docs/PERPS_V2_BASE_SEPOLIA_RECOVERY_GOVERNANCE_PREPARE_V1.md').read_text()
    file_hashes = {}
    for name in ('g1_insurance_safe_review_manifest.json', 'g2_vault_safe_review_manifest.json',
                 'g1_insurance_safe_builder.json', 'g2_vault_safe_builder.json'):
        path = SOURCE/name
        sha = hashlib.sha256(path.read_bytes()).hexdigest()
        assert f'| `{name}` | `{sha}` |' in report, name + ' differs from approved review'
        file_hashes[name] = sha
    ctx = migration.prepare_context()
    rpc, call = ctx['live'], ctx['call']
    assert int(rpc('eth_chainId', []), 16) == 84532
    results = [verify_receipt(ctx, row) for row in TXS]
    assert results[0]['canonicalBlock'] < results[1]['canonicalBlock']
    latest = rpc('eth_getBlockByNumber', ['latest', False])
    tag = latest['number']
    assert int(latest['hash'], 16) != 0
    g1_id, g2_id = [x['operationId'] for x in results]
    assert call(rpc, TIMELOCK, 'queuedTransactions(bytes32)', [g1_id], tag) == [1]
    assert call(rpc, TIMELOCK, 'queuedTransactions(bytes32)', [g2_id], tag) == [1]
    assert call(rpc, ctx['deps']['insuranceFund()'], 'isBackstopCaller(address)', [ctx['NEW']], tag) == [0]
    assert call(rpc, ctx['VAULT'], 'isAuthorizedEngine(address)', [ctx['NEW']], tag) == [0]
    assert call(rpc, ctx['deps']['feesManagerV2()'], 'isFeeConsumer(address)', [ctx['NEW']], tag) == [0]
    current_safe_nonce = call(rpc, SAFE, 'nonce()', tag=tag)[0]
    assert current_safe_nonce >= 17
    assert call(rpc, TIMELOCK, 'minDelay()', tag=tag) == [86400]
    grace = call(rpc, TIMELOCK, 'GRACE_PERIOD()', tag=tag)[0]
    assert grace == 14*86400

    prior = json.loads((migration.OUT/'postflight.json').read_text())
    ctx['checks'] = [(label, addr, sig, 1 if sig == 'migrationState()' else ctx['SNAPSHOT'], args)
                     if addr.lower() == ctx['NEW'].lower() and sig in ('migrationState()', 'migrationSnapshotHash()')
                     else (label, addr, sig, expected, args)
                     for label, addr, sig, expected, args in ctx['checks']]
    state = migration.reconcile_state(ctx, tag, prior)
    state['checks'] = [{**row, 'args': list(row['args'])} for row in state['checks']]
    for key in ('checks', 'seedFlags', 'positionIndexes', 'pmeV2Nonces'):
        assert state[key] == prior[key], key + ' drift'
    assert len(state['checks']) == 114
    for name in ('PME', 'PME1'):
        assert call(rpc, ctx[name], 'paused()', tag=tag) == [1]
    controls = {name: [call(rpc, ctx[name], sig, tag=tag)[0] for sig in maintenance.FLAGS]
                for name in ('NEW', 'OLD', 'V1')}
    assert all(value == [1, 1, 1, 1] for value in controls.values())
    assert call(rpc, ctx['PME'], 'perpEngine()', tag=tag) == [int(ctx['OLD'], 16)]
    assert call(rpc, ctx['RISK'], 'perpEngine()', tag=tag) == [int(ctx['OLD'], 16)]
    assert call(rpc, ctx['VAULT'], 'balances(address,address)',
                [ctx['deps']['clearingAccount()'], ctx['TOKEN']], tag) == [1000000000]
    assert ctx['backend_stopped']()['backend_runtime_state'] == 'STOPPED'

    # Only the bounded window around the two operator-submitted queue calls.
    addresses = [ctx[x] for x in ('NEW', 'OLD', 'V1', 'PME', 'PME1', 'RISK', 'VAULT', 'PMR')]
    addresses += [ctx['deps']['feesManagerV2()'], ctx['deps']['insuranceFund()'], TIMELOCK, SAFE]
    first = 47612564
    last = int(tag, 16)
    logs = []
    for start in range(first, last+1, 2000):
        logs.extend(rpc('eth_getLogs', [{'address': addresses, 'fromBlock': hex(start),
                                         'toBlock': hex(min(start+1999, last))}]))
    assert len(logs) == 6, 'Unexpected relevant event count in bounded queue window'
    expected_hashes = {x['publicTxHash'].lower() for x in results}
    assert all(x['transactionHash'].lower() in expected_hashes for x in logs)
    assert all(x['address'].lower() in (SAFE.lower(), TIMELOCK.lower()) for x in logs)

    payload = {
        'milestone': 'PERPS_V2_BASE_SEPOLIA_RECOVERY_GOVERNANCE_QUEUE_V1',
        'result': 'RECOVERY_GOVERNANCE_BOTH_OPERATIONS_QUEUED',
        'chainId': 84532, 'sourceCommit': 'd6e7dbb4ccf10bd7422c0e74f94d7e7c1dca135f',
        'approvedFileSha256': file_hashes, 'transactions': results,
        'comparisonBlock': last, 'comparisonBlockHash': latest['hash'],
        'comparisonTimestamp': int(latest['timestamp'], 16),
        'comparisonUTC': utc(int(latest['timestamp'], 16)),
        'currentSafeNonce': current_safe_nonce,
        'safeNonceProgression': '15 -> 16 -> 17',
        'G1Queued': True, 'G2Queued': True,
        'newInsuranceAuthorized': False, 'newVaultAuthorized': False,
        'newFeeConsumerAuthorized': False,
        'migrationHashesCanonical': True, 'economicChecks': 114,
        'seedFlags': len(state['seedFlags']),
        'positionIndexes': len(state['positionIndexes']),
        'pmeTraderNonces': len(state['pmeV2Nonces']),
        'maintenanceControls': controls,
        'clearingBalanceNative': 1000000000,
        'sharedPointersStillOld': True,
        'scopedEventScan': {'fromBlock': first, 'toBlock': last,
                            'eventCount': len(logs), 'onlyG1AndG2SafeTimelockEvents': True},
        'eta': results[0]['eta'], 'minDelay': 86400, 'gracePeriod': grace,
        'executionWindowStartUTC': utc(results[0]['eta']),
        'executionWindowEndUTC': utc(results[0]['eta']+grace),
        'backendLocalRuntimeState': 'STOPPED',
        'signedOrderInventory': 'UNRESOLVED',
        'keystoreAccess': False, 'signaturesGenerated': False,
        'publicWritesByThisVerifier': 0, 'databaseWrites': 0,
    }
    assert current_safe_nonce == 17, 'Extra Safe transaction since G2; reconcile before finalizing report'
    OUT.mkdir(exist_ok=True)
    (OUT/'postflight.json').write_text(json.dumps(payload, indent=2, sort_keys=True)+'\n')
    print(json.dumps({'result': payload['result'], 'blocks': [x['canonicalBlock'] for x in results],
                      'safeNonce': current_safe_nonce, 'economicChecks': 114,
                      'scopedEvents': len(logs), 'postflight': str(OUT/'postflight.json')}))


if __name__ == '__main__':
    main()
