#!/usr/bin/env python3
"""Read-only preparation of the three conditional OWNER V2 rebind calls."""

import hashlib
import json
from pathlib import Path
import sys

from eth_abi import decode
from eth_utils import keccak

sys.dont_write_bytecode = True
import maintenance_lock_preflight as maintenance
import migration_reseal_preflight as migration

ROOT = migration.ROOT
OUT = ROOT / 'artifacts/perps_v2_rebind_owner_only'
OWNER = '0xc35F7A8A103A9A4464adfaa76B9B514093D23C27'
TIMELOCK = maintenance.TIMELOCK
G1 = '0x824bc77bb68ff4878d2e477478ed4d120abab89ce27b181a7c8ecc5ba7cfa3f6'
G2 = '0x02705011c0ee36d4928843bfb5641ff90aebf658162735668774768a7bc3e846'
E2_TX = '0x57ba5e2bf1c52fc5a39aa56336c66192445e68b42b5272f069903802f6dd146a'
ENGINE_HASH = '0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a'


def save(name, data):
    path = OUT / name
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
    return hashlib.sha256(path.read_bytes()).hexdigest()


def encode_call(calldata_helper, signature, args):
    return calldata_helper(signature, tuple(str(value).lower() if isinstance(value, bool)
                                            else value for value in args))


def main():
    assert not sys.flags.optimize
    ctx = migration.prepare_context()
    rpc, call, cd = ctx['live'], ctx['call'], ctx['calldata']
    assert int(rpc('eth_chainId', []), 16) == 84532
    block = rpc('eth_getBlockByNumber', ['latest', False])
    tag, block_number = block['number'], int(block['number'], 16)
    assert int(block['hash'], 16) != 0
    receipt = rpc('eth_getTransactionReceipt', [E2_TX])
    assert receipt and int(receipt['status'], 16) == 1
    assert block_number >= int(receipt['blockNumber'], 16)

    confirmed = int(rpc('eth_getTransactionCount', [OWNER, 'latest']), 16)
    pending = int(rpc('eth_getTransactionCount', [OWNER, 'pending']), 16)
    assert confirmed == pending, 'OWNER pending nonce differs from confirmed'
    assert call(rpc, TIMELOCK, 'queuedTransactions(bytes32)', [G1], tag) == [0]
    assert call(rpc, TIMELOCK, 'queuedTransactions(bytes32)', [G2], tag) == [0]
    insurance = ctx['deps']['insuranceFund()']
    fmv2 = ctx['deps']['feesManagerV2()']
    assert call(rpc, insurance, 'isBackstopCaller(address)', [ctx['NEW']], tag) == [1]
    assert call(rpc, ctx['VAULT'], 'isAuthorizedEngine(address)', [ctx['NEW']], tag) == [1]
    assert call(rpc, fmv2, 'isFeeConsumer(address)', [ctx['NEW']], tag) == [0]
    assert call(rpc, ctx['RISK'], 'perpEngine()', tag=tag) == [int(ctx['OLD'], 16)]
    assert call(rpc, ctx['PME'], 'perpEngine()', tag=tag) == [int(ctx['OLD'], 16)]
    for address in (fmv2, ctx['RISK'], ctx['PME']):
        assert call(rpc, address, 'owner()', tag=tag) == [int(OWNER, 16)]
        assert rpc('eth_getCode', [address, tag]) != '0x'
    code = bytes.fromhex(rpc('eth_getCode', [ctx['NEW'], tag])[2:])
    assert len(code) == 24321 and '0x' + keccak(code).hex() == ENGINE_HASH
    assert call(rpc, ctx['NEW'], 'migrationState()', tag=tag) == [1]
    assert call(rpc, ctx['NEW'], 'migrationSnapshotHash()', tag=tag) == [int(ctx['SNAPSHOT'], 16)]
    assert call(rpc, ctx['OLD'], 'migrationState()', tag=tag) == [1]
    assert call(rpc, ctx['OLD'], 'migrationSnapshotHash()', tag=tag) == [int(ctx['SNAPSHOT'], 16)]
    assert call(rpc, ctx['PME'], 'paused()', tag=tag) == [1]
    assert call(rpc, ctx['PME1'], 'paused()', tag=tag) == [1]
    flags = {name: [call(rpc, ctx[name], sig, tag=tag)[0] for sig in maintenance.FLAGS]
             for name in ('V1', 'OLD', 'NEW')}
    assert all(value == [1, 1, 1, 1] for value in flags.values())
    assert call(rpc, ctx['VAULT'], 'balances(address,address)',
                [ctx['deps']['clearingAccount()'], ctx['TOKEN']], tag) == [1000000000]
    assert ctx['backend_stopped']()['backend_runtime_state'] == 'STOPPED'

    previous = json.loads((migration.OUT / 'postflight.json').read_text())
    def expected(address, signature, value, args):
        if address.lower() == ctx['NEW'].lower() and signature == 'migrationState()':
            return 1
        if address.lower() == ctx['NEW'].lower() and signature == 'migrationSnapshotHash()':
            return ctx['SNAPSHOT']
        if signature in ('isAuthorizedEngine(address)', 'isBackstopCaller(address)') \
                and args and args[0].lower() == ctx['NEW'].lower():
            return 1
        return value
    ctx['checks'] = [(label, address, sig, expected(address, sig, value, args), args)
                     for label, address, sig, value, args in ctx['checks']]
    state = migration.reconcile_state(ctx, tag, previous)
    state['checks'] = [{**row, 'args': list(row['args'])} for row in state['checks']]
    prior = [{**row, 'value': expected(row['address'], row['function'], row['value'], row['args'])}
             for row in previous['checks']]
    assert state['checks'] == prior, 'economic/dependency drift'
    for key in ('seedFlags', 'positionIndexes', 'pmeV2Nonces'):
        assert state[key] == previous[key], key + ' drift'
    assert len(state['checks']) == 114 and len(state['seedFlags']) == 14
    assert len(state['positionIndexes']) == len(state['pmeV2Nonces']) == 6

    # This scan is deliberately bounded to the interval after E2, not the full history.
    emitters = list(dict.fromkeys([ctx[name] for name in ('NEW', 'OLD', 'V1', 'PME', 'PME1', 'RISK')]
                                  + [fmv2, ctx['VAULT'], insurance]))
    events = []
    first = int(receipt['blockNumber'], 16) + 1
    for start in range(first, block_number + 1, 2000):
        events += rpc('eth_getLogs', [{'address': emitters, 'fromBlock': hex(start),
                                      'toBlock': hex(min(start + 1999, block_number))}])
    assert not events, 'unexpected protocol event since E2'

    specs = [
        ('r1_fmv2_review.json', fmv2, 'setFeeConsumer(address,bool)',
         (ctx['NEW'], True), (ctx['NEW'], False), 'FeeConsumerSet(address,bool)',
         'isFeeConsumer(NEW_ENGINE)=true; Risk/PME remain OLD_ENGINE'),
        ('r2_risk_review.json', ctx['RISK'], 'setPerpEngine(address)',
         (ctx['NEW'],), (ctx['OLD'],), 'PerpEngineSet(address,address)',
         'Risk=NEW_ENGINE; PME=OLD_ENGINE; OLD_ENGINE still fully paused'),
        ('r3_pme_review.json', ctx['PME'], 'setEngine(address)',
         (ctx['NEW'],), (ctx['OLD'],), 'EngineSet(address,address)',
         'PME=NEW_ENGINE; Risk=NEW_ENGINE; maintenance remains active'),
    ]
    reviews = []
    for i, (name, target, signature, args, rollback_args, event, after) in enumerate(specs):
        calldata = encode_call(cd, signature, args)
        assert calldata[:10] == '0x' + keccak(text=signature)[:4].hex()
        types = ['address', 'bool'] if i == 0 else ['address']
        decoded = decode(types, bytes.fromhex(calldata[10:]))
        assert decoded[0].lower() == args[0].lower()
        if i == 0:
            assert decoded[1] is True
        rpc('eth_call', [{'from': OWNER, 'to': target, 'data': calldata, 'value': '0x0'}, tag])
        gas = int(rpc('eth_estimateGas', [{'from': OWNER, 'to': target,
                                           'data': calldata, 'value': '0x0'}, tag]), 16)
        row = {'ordinal': i+1, 'chainId': 84532, 'from': OWNER, 'to': target,
               'nonce': confirmed+i, 'nonceConditionalOnPriorVerifiedSuccess': i != 0,
               'valueWei': 0, 'function': signature, 'selector': calldata[:10],
               'args': list(args), 'calldata': calldata, 'expectedEvent': event,
               'expectedEventTopic0': '0x'+keccak(text=event).hex(),
               'expectedPostcondition': after,
               'rollbackForReviewOnly': {'function': signature, 'args': list(rollback_args),
                                         'calldata': encode_call(cd, signature, rollback_args)},
               'ownerContextEthCall': 'SUCCESS_AT_COMPARISON_BLOCK',
               'gasEstimateAtCurrentState': gas,
               'estimateCaveat': 'R2/R3 estimated against current state; refresh after each preceding write.'}
        reviews.append((name, row))
    assert rpc('eth_getBlockByNumber', [tag, False])['hash'].lower() == block['hash'].lower()
    assert int(rpc('eth_getTransactionCount', [OWNER, 'latest']), 16) == confirmed
    assert int(rpc('eth_getTransactionCount', [OWNER, 'pending']), 16) == pending
    OUT.mkdir(exist_ok=True)
    hashes = {name: save(name, row) for name, row in reviews}
    result = {'milestone': 'PERPS_V2_BASE_SEPOLIA_V2_REBIND_OWNER_ONLY_V1',
              'result': 'PREPARED_NOT_AUTHORIZED_FOR_BROADCAST',
              'comparisonBlock': block_number, 'comparisonBlockHash': block['hash'],
              'comparisonTimestamp': int(block['timestamp'], 16), 'chainId': 84532,
              'ownerConfirmedNonce': confirmed, 'ownerPendingNonce': pending,
              'targetsOwnedByOwner': [x[1] for x in specs],
              'G1Consumed': True, 'G2Consumed': True,
              'insuranceNewAuthorized': True, 'vaultNewAuthorized': True,
              'feeConsumerNewBefore': False, 'riskBefore': ctx['OLD'],
              'pmeBefore': ctx['OLD'], 'newEngineRuntimeSize': len(code),
              'newEngineRuntimeKeccak': ENGINE_HASH, 'migrationHash': ctx['SNAPSHOT'],
              'maintenanceFlags': flags, 'economicChecks': len(state['checks']),
              'seedFlags': len(state['seedFlags']), 'positionIndexes': len(state['positionIndexes']),
              'traderNonces': len(state['pmeV2Nonces']), 'clearingBalanceNative': 1000000000,
              'backendLocalRuntime': 'STOPPED', 'scopedProtocolEventsAfterE2': len(events),
              'E2PublicTx': E2_TX, 'reviewFileSha256': hashes,
              'publicWrites': 0, 'keystoreAccess': False}
    preflight_hash = save('preflight.json', result)
    print(json.dumps({'block': block_number, 'blockHash': block['hash'],
                      'nonce': confirmed, 'preflightSha256': preflight_hash,
                      'reviewFiles': hashes,
                      'review': [{k: row[k] for k in ('ordinal', 'to', 'nonce', 'selector',
                         'calldata', 'gasEstimateAtCurrentState')} for _, row in reviews]}),
          flush=True)


if __name__ == '__main__':
    main()
