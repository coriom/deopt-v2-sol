#!/usr/bin/env python3
"""Read-only Stage A for the one-call V1 maintenance continuation."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
import maintenance_fee_guard as fee_guard
import maintenance_lock_execute as prior_execution
import maintenance_lock_preflight as prior_audit
import migration_reseal_preflight as reseal

ROOT = prior_audit.ROOT
PRIOR = prior_audit.OUT
OUT = ROOT / 'artifacts/perps_v2_recovery_maintenance_lock_finish'
ORIGINAL_HASH = prior_execution.APPROVED
OWNER = prior_execution.OWNER
V1 = '0xc6C592100723Fe0C66343A16e95eC34cC0c2141c'


def save(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n')


def _int_bytes(number):
    return number.to_bytes((number.bit_length() + 7) // 8, 'big') if number else b''


def _rlp(item):
    if isinstance(item, int):
        return _rlp(_int_bytes(item))
    if isinstance(item, list):
        payload = b''.join(_rlp(value) for value in item)
        prefix = 0xc0
    else:
        payload = bytes(item)
        if len(payload) == 1 and payload[0] < 0x80:
            return payload
        prefix = 0x80
    if len(payload) < 56:
        return bytes([prefix + len(payload)]) + payload
    length = _int_bytes(len(payload))
    return bytes([prefix + 55 + len(length)]) + length + payload


def unsigned_type2_length(chain, nonce, priority, max_fee, gas_limit, target, value, calldata):
    fields = [chain, nonce, priority, max_fee, gas_limit, bytes.fromhex(target[2:]),
              value, bytes.fromhex(calldata[2:]), []]
    return len(b'\x02' + _rlp(fields))


def main():
    assert not sys.flags.optimize
    if OUT.exists():
        assert not (OUT / 'execution_journal.json').exists(), 'Continuation execution exists; no Stage-A refresh'
        assert not (OUT / 'fee_decision_broadcast.json').exists(), 'Broadcast fee decision exists; no Stage-A refresh'
    original_bytes = (PRIOR / 'execution_package.json').read_bytes()
    assert hashlib.sha256(original_bytes).hexdigest() == ORIGINAL_HASH
    original = json.loads(original_bytes)
    step = original['transactions'][3]
    assert len(original['transactions']) == 4 and step['ordinal'] == 4
    assert step['sender'].lower() == OWNER.lower() and step['target'].lower() == V1.lower()
    assert step['chainId'] == 84532 and step['nonce'] == 811 and step['value'] == 0
    assert step['function'] == 'setEmergencyModes(bool,bool,bool,bool)'
    assert step['decodedArguments'] == [True] * 4
    assert step['pauseFlagsBefore'] == [0, 1, 0, 0] and step['pauseFlagsAfter'] == [1, 1, 1, 1]
    assert len(step['calldata']) == 2 + 8 + 64 * 4
    assert step['calldata'][:10] == step['selector']
    assert [int(step['calldata'][10+i*64:10+(i+1)*64], 16) for i in range(4)] == [1]*4

    journal = json.loads((PRIOR / 'execution_journal.json').read_text())
    assert journal['status'] == 'HALTED' and journal['publicSendInvocations'] == 3
    assert len(journal['transactions']) == 3
    assert [x['nonce'] for x in journal['transactions']] == [808, 809, 810]
    assert all(x['status'] == 'VERIFIED' and x['submissionAttempts'] == 1 for x in journal['transactions'])
    assert not (PRIOR / 'receipt_4.json').exists()
    assert not prior_execution.PW.exists()
    inventory = json.loads((PRIOR / 'entry_inventory.json').read_text())
    for name, digest in inventory['preservedBlockedRebindFiles'].items():
        assert hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest
    preflight = json.loads((PRIOR / 'preflight.json').read_text())
    previous = json.loads((reseal.OUT / 'postflight.json').read_text())
    assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip() == preflight['solHead']
    backend = ROOT.parent / 'deopt-v2-backend'
    assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=backend, text=True).strip() == preflight['backendHead']
    assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=backend, text=True).strip()
    ctx = reseal.prepare_context()
    rpc = ctx['live']
    assert int(rpc('eth_chainId', []), 16) == 84532
    ctx['checks'] = [(label, address, sig, 1 if sig == 'migrationState()' else ctx['SNAPSHOT'], args)
                     if address.lower() == ctx['NEW'].lower() and sig in ('migrationState()', 'migrationSnapshotHash()')
                     else (label, address, sig, want, args)
                     for label, address, sig, want, args in ctx['checks']]
    block = rpc('eth_getBlockByNumber', ['latest', False])
    tag = block['number']
    assert int(block['hash'], 16) != 0
    assert rpc('eth_getBlockByNumber', [hex(ctx['manifest']['snapshotBlockNumber']), False])['hash'] == ctx['manifest']['snapshotBlockHash']
    confirmed = int(rpc('eth_getTransactionCount', [OWNER, 'latest']), 16)
    pending = int(rpc('eth_getTransactionCount', [OWNER, 'pending']), 16)
    assert (confirmed, pending) == (811, 811), 'Nonce drift; no continuation preview'
    controls = {name: list(values) for name, values in preflight['controls'].items()}
    receipts = []
    for row in journal['transactions']:
        approved_step = original['transactions'][row['ordinal']-1]
        receipt = rpc('eth_getTransactionReceipt', [row['hash']])
        tx = rpc('eth_getTransactionByHash', [row['hash']])
        included = rpc('eth_getBlockByNumber', [receipt['blockNumber'], False])
        prior_execution.validate_receipt(ctx, receipt, tx, included, row['hash'], approved_step)
        assert receipt['blockHash'] == row['receiptBlockHash']
        assert int(receipt['blockNumber'], 16) == row['receiptBlock']
        assert hashlib.sha256((PRIOR / ('receipt_' + str(row['ordinal']) + '.json')).read_bytes()).hexdigest()
        controls[row['name']] = approved_step['pauseFlagsAfter']
        receipts.append({'ordinal': row['ordinal'], 'hash': row['hash'], 'block': row['receiptBlock'],
                         'blockHash': row['receiptBlockHash'], 'status': 1,
                         'senderTargetNonceInputEventsVerified': True})
    assert prior_execution.control_state(ctx, rpc, tag) == controls
    prior_execution.invariant(ctx, preflight, previous, rpc, tag, controls)
    logs = prior_execution.scan_unexpected(ctx, rpc, journal['preBlock']+1,
                                           int(tag, 16), [row['hash'] for row in journal['transactions']])
    assert len(logs) == 11
    assert ctx['call'](rpc, ctx['PME1'], 'paused()', tag=tag)[0] == 1
    assert ctx['call'](rpc, V1, 'owner()', tag=tag)[0] == int(OWNER, 16)
    assert '0x' + ctx['keccak256'](step['function'].encode())[:4].hex() == step['selector']
    abi = json.loads((ROOT / 'out/PerpEngine.sol/PerpEngine.json').read_text())['abi']
    fn = [x for x in abi if x['type'] == 'function' and x['name'] == 'setEmergencyModes']
    assert len(fn) == 1 and [x['type'] for x in fn[0]['inputs']] == ['bool'] * 4
    call_tx = {'from': OWNER, 'to': V1, 'data': step['calldata'], 'value': '0x0'}
    assert rpc('eth_call', [call_tx, tag]) == '0x', 'OWNER-context simulation failed'

    estimate_tx = {**call_tx, 'gas': hex(500000)}
    gas_estimate = int(rpc('eth_estimateGas', [estimate_tx, tag]), 16)
    proposed_gas_limit = max(step['gasLimit'], (gas_estimate * 130 + 99) // 100)
    base_fee = int(block['baseFeePerGas'], 16)
    suggested_priority = int(rpc('eth_maxPriorityFeePerGas', []), 16)
    rpc_gas_price = int(rpc('eth_gasPrice', []), 16)
    proposed_priority = step['maxPriorityFeePerGasWei']
    proposed_max_fee = step['maxFeePerGasWei']
    assert suggested_priority <= proposed_priority
    assert max(2 * base_fee + suggested_priority, rpc_gas_price) <= proposed_max_fee
    unsigned_size = unsigned_type2_length(84532, 811, proposed_priority,
                                          proposed_max_fee, proposed_gas_limit, V1, 0, step['calldata'])
    assert unsigned_size <= 512, 'Prior oracle size assumption too small'
    oracle = '0x420000000000000000000000000000000000000F'
    # The oracle itself adds 68 bytes for the missing signature. Do not add it here.
    actual_size_bound = ctx['call'](rpc, oracle, 'getL1FeeUpperBound(uint256)', [unsigned_size], tag)[0]
    size_512_bound = ctx['call'](rpc, oracle, 'getL1FeeUpperBound(uint256)', [512], tag)[0]
    assert size_512_bound >= actual_size_bound
    # Preserve the former 2x quote policy, then add a documented 25% quote-volatility reserve.
    proposed_l1_allowance = max(step['l1FeeAllowanceWei'], (size_512_bound * 5 + 1) // 2)
    operator_estimate = ctx['call'](rpc, oracle, 'getOperatorFee(uint256)', [gas_estimate], tag)[0]
    operator_limit = ctx['call'](rpc, oracle, 'getOperatorFee(uint256)', [proposed_gas_limit], tag)[0]
    assert operator_limit >= operator_estimate
    operator_allowance = (operator_limit * 5 + 3) // 4
    policy = {'oracleUnsignedTxSizeBytes': 512, 'l2GasEstimate': gas_estimate,
              'gasLimit': proposed_gas_limit, 'maxFeePerGasWei': proposed_max_fee,
              'maxPriorityFeePerGasWei': proposed_priority,
              'l1BoundMultiplierNumerator': 2, 'l1BoundMultiplierDenominator': 1,
              'l1AllowanceWei': proposed_l1_allowance,
              'additionalFeeAllowanceWei': operator_allowance,
              'totalPlanningBudgetWei': proposed_gas_limit * proposed_max_fee
                                        + proposed_l1_allowance + operator_allowance}
    owner_balance = int(rpc('eth_getBalance', [OWNER, tag]), 16)
    fee_decision = fee_guard.decide(block={'number': int(tag, 16), 'hash': block['hash'],
                                           'timestamp': int(block['timestamp'], 16)},
                                    quote=size_512_bound, additional_fee_quote_wei=operator_limit,
                                    observed_base_fee_wei=base_fee,
                                    observed_priority_fee_wei=suggested_priority,
                                    observed_gas_price_wei=rpc_gas_price,
                                    observed_gas_estimate=gas_estimate,
                                    policy=policy, balance_wei=owner_balance)
    assert fee_decision['result'] == 'PASS', 'Current fee envelope not sufficient'
    continuation = {'milestone': 'PERPS_V2_BASE_SEPOLIA_RECOVERY_MAINTENANCE_LOCK_V1_FINISH',
                    'chainId': 84532, 'originalPackageSha256': ORIGINAL_HASH,
                    'originalOrdinal': 4, 'sender': OWNER, 'target': V1,
                    'nonce': 811, 'expectedFinalNonce': 812, 'value': 0,
                    'function': step['function'], 'selector': step['selector'],
                    'decodedArguments': step['decodedArguments'], 'calldata': step['calldata'],
                    'pauseFlagsBefore': step['pauseFlagsBefore'],
                    'pauseFlagsAfter': step['pauseFlagsAfter'],
                    'expectedEvents': step['expectedEvents'], 'feePolicy': policy}
    OUT.mkdir(exist_ok=True)
    save(OUT / 'execution_package.json', continuation)
    digest = hashlib.sha256((OUT / 'execution_package.json').read_bytes()).hexdigest()
    save(OUT / 'fee_decision_preview.json', fee_decision)
    report = {'status': 'PERPS_V2_BASE_SEPOLIA_RECOVERY_MAINTENANCE_LOCK_V1_FINISH_READY_TO_BROADCAST',
              'publicWrites': 0, 'keystoreUnlocked': False,
              'solHead': preflight['solHead'], 'backendHead': preflight['backendHead'],
              'comparisonBlock': int(tag, 16), 'comparisonBlockHash': block['hash'],
              'comparisonTimestamp': int(block['timestamp'], 16), 'chainId': 84532,
              'ownerNonceConfirmed': confirmed, 'ownerNoncePending': pending,
              'ownerBalanceWei': owner_balance, 'prefixReceipts': receipts,
              'scopedExpectedEventsSincePrefix': len(logs), 'economicChecks': 114,
              'seedFlagsChecked': len(preflight['seedFlags']),
              'positionIndexesChecked': len(preflight['positionIndexes']),
              'pmeTraderNoncesChecked': len(preflight['pmeV2Nonces']),
              'controls': controls, 'simulation': {'method': 'eth_call', 'from': OWNER,
               'to': V1, 'result': '0x', 'block': int(tag, 16),
               'priorLocalFourStepRehearsal': 'artifacts/perps_v2_recovery_maintenance_lock/fork_simulation.json'},
              'oracle': {'address': oracle, 'method': 'getL1FeeUpperBound(uint256)',
                         'unsignedRlpType2SizeBytes': unsigned_size,
                         'conservativeInputBytes': 512,
                         'boundAtActualUnsignedSizeWei': actual_size_bound,
                         'boundAt512BytesWei': size_512_bound,
                         'adds68BytesItself': True,
                         'getOperatorFeeAtEstimateWei': operator_estimate,
                         'getOperatorFeeAtGasLimitWei': operator_limit},
              'feeDecision': fee_decision,
              'oldVsProposed': {'gasEstimate': [step['gasEstimate'], gas_estimate],
                                'gasLimit': [step['gasLimit'], proposed_gas_limit],
                                'maxFeePerGasWei': [step['maxFeePerGasWei'], proposed_max_fee],
                                'maxPriorityFeePerGasWei': [step['maxPriorityFeePerGasWei'], proposed_priority],
                                'l1AllowanceWei': [step['l1FeeAllowanceWei'], proposed_l1_allowance],
                                'additionalOperatorFeeAllowanceWei': [0, operator_allowance]},
              'originalPackageSha256': ORIGINAL_HASH,
              'continuationPackageSha256': digest,
              'historicalTriggerValue': 'UNKNOWN_NOT_RECORDED',
              'backendRuntimeState': 'STOPPED',
              'noStep4RecordedOrNonceConsumed': True,
              'noPublicWritePerformed': True}
    save(OUT / 'stage_a.json', report)
    print(json.dumps({key: report[key] for key in ('status', 'comparisonBlock',
          'ownerNonceConfirmed', 'ownerNoncePending', 'ownerBalanceWei',
          'continuationPackageSha256', 'oldVsProposed', 'oracle')}, indent=2), flush=True)


if __name__ == '__main__':
    main()
