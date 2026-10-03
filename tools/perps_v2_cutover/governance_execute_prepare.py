#!/usr/bin/env python3
"""Read-only G1/G2 Timelock EXECUTE preparation. Never signs or sends."""
import datetime as dt
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from eth_abi import encode
from eth_utils import keccak

sys.dont_write_bytecode = True
import governance_queue_postflight as queue
import maintenance_lock_preflight as maintenance
import migration_reseal_preflight as migration
from governance_prepare import abi_words, decoded_address_array

ROOT = migration.ROOT
SOURCE = ROOT / 'artifacts/perps_v2_recovery_governance_prepare'
OUT = ROOT / 'artifacts/perps_v2_recovery_governance_execute'
SAFE = queue.SAFE
TIMELOCK = queue.TIMELOCK
ZERO = '0x' + '00' * 20
ETA = 1791086934
CHECKPOINT = '91be6559c9bc0bf810e5c116a4d17253886dbb3d'


def utc(value):
    return dt.datetime.fromtimestamp(value, dt.timezone.utc).isoformat()


def save(name, value):
    path = OUT / name
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    return path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def safe_tx_hash(fields, domain):
    typehash = keccak(text='SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)')
    structure = keccak(encode(
        ['bytes32', 'address', 'uint256', 'bytes32', 'uint8', 'uint256', 'uint256',
         'uint256', 'address', 'address', 'uint256'],
        [typehash, fields['to'], int(fields['value']), keccak(bytes.fromhex(fields['data'][2:])),
         fields['operation'], int(fields['safeTxGas']), int(fields['baseGas']),
         int(fields['gasPrice']), fields['gasToken'], fields['refundReceiver'], fields['nonce']]))
    return '0x' + keccak(b'\x19\x01' + domain + structure).hex()


def main():
    assert not sys.flags.optimize
    assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip() == CHECKPOINT
    backend = ROOT.parent / 'deopt-v2-backend'
    assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=backend, text=True).strip() == 'ad8dd7466aeba6963d28687e825fe4df58ef32ee'
    assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=backend, text=True).strip()
    report = (ROOT / 'docs/PERPS_V2_BASE_SEPOLIA_RECOVERY_GOVERNANCE_PREPARE_V1.md').read_text()
    for name in ('g1_insurance_safe_review_manifest.json', 'g2_vault_safe_review_manifest.json',
                 'g1_insurance_safe_builder.json', 'g2_vault_safe_builder.json'):
        assert f'| `{name}` | `{sha(SOURCE / name)}` |' in report, name + ' queue-file drift'
    ctx = migration.prepare_context()
    rpc, call, cd = ctx['live'], ctx['call'], ctx['calldata']
    assert int(rpc('eth_chainId', []), 16) == 84532
    included = [queue.verify_receipt(ctx, row) for row in queue.TXS]
    latest = rpc('eth_getBlockByNumber', ['latest', False])
    observed_heads = {}
    for head in ('safe', 'finalized'):
        try:
            observed = rpc('eth_getBlockByNumber', [head, False])
            assert observed and int(observed['hash'], 16) != 0
            observed_heads[head] = {'block': int(observed['number'], 16), 'hash': observed['hash']}
        except RuntimeError as error:
            observed_heads[head] = {'unavailable': str(error)}
    tag = latest['number']
    block = int(tag, 16)
    timestamp = int(latest['timestamp'], 16)
    assert int(latest['hash'], 16) != 0
    assert block >= 47614194
    assert rpc('eth_getCode', [TIMELOCK, tag]).lower() == json.loads(
        (ROOT / 'out/ProtocolTimelock.sol/ProtocolTimelock.json').read_text())['deployedBytecode']['object'].lower()

    previous = json.loads((migration.OUT / 'postflight.json').read_text())
    ctx['checks'] = [(label, addr, sig, 1 if sig == 'migrationState()' else ctx['SNAPSHOT'], args)
                     if addr.lower() == ctx['NEW'].lower() and sig in ('migrationState()', 'migrationSnapshotHash()')
                     else (label, addr, sig, expected, args)
                     for label, addr, sig, expected, args in ctx['checks']]
    state = migration.reconcile_state(ctx, tag, previous)
    state['checks'] = [{**row, 'args': list(row['args'])} for row in state['checks']]
    for key in ('checks', 'seedFlags', 'positionIndexes', 'pmeV2Nonces'):
        assert state[key] == previous[key], 'economic drift: ' + key
    assert len(state['checks']) == 114
    for name in ('PME', 'PME1'):
        assert call(rpc, ctx[name], 'paused()', tag=tag) == [1]
    controls = {name: [call(rpc, ctx[name], sig, tag=tag)[0] for sig in maintenance.FLAGS]
                for name in ('V1', 'OLD', 'NEW')}
    assert all(flags == [1, 1, 1, 1] for flags in controls.values())
    assert call(rpc, ctx['VAULT'], 'balances(address,address)',
                [ctx['deps']['clearingAccount()'], ctx['TOKEN']], tag) == [1000000000]
    assert call(rpc, ctx['PME'], 'perpEngine()', tag=tag) == [int(ctx['OLD'], 16)]
    assert call(rpc, ctx['RISK'], 'perpEngine()', tag=tag) == [int(ctx['OLD'], 16)]
    assert call(rpc, ctx['deps']['feesManagerV2()'], 'isFeeConsumer(address)', [ctx['NEW']], tag) == [0]
    assert ctx['backend_stopped']()['backend_runtime_state'] == 'STOPPED'

    def address(contract, sig):
        return '0x' + call(rpc, contract, sig, tag=tag)[0].to_bytes(20, 'big').hex()

    assert address(TIMELOCK, 'owner()').lower() == SAFE.lower()
    assert address(ctx['deps']['insuranceFund()'], 'owner()').lower() == TIMELOCK.lower()
    assert address(ctx['VAULT'], 'owner()').lower() == TIMELOCK.lower()
    assert call(rpc, TIMELOCK, 'executors(address)', [SAFE], tag) == [1]
    assert call(rpc, TIMELOCK, 'proposers(address)', [SAFE], tag) == [1]
    min_delay = call(rpc, TIMELOCK, 'minDelay()', tag=tag)[0]
    grace = call(rpc, TIMELOCK, 'GRACE_PERIOD()', tag=tag)[0]
    queue_paused = bool(call(rpc, TIMELOCK, 'queuePaused()', tag=tag)[0])
    assert min_delay == 86400 and grace == 1209600
    safe_nonce = call(rpc, SAFE, 'nonce()', tag=tag)[0]
    assert safe_nonce == 17, 'Safe nonce changed; reconcile before new review'
    owners = decoded_address_array(rpc('eth_call', [{'to': SAFE, 'data': cd('getOwners()')}, tag]))
    threshold = call(rpc, SAFE, 'getThreshold()', tag=tag)[0]
    assert threshold == 2 and len(owners) == 3
    mods = abi_words(rpc('eth_call', [{'to': SAFE, 'data': cd('getModulesPaginated(address,uint256)',
        ('0x0000000000000000000000000000000000000001', 10))}, tag]))
    assert int.from_bytes(mods[0], 'big') == 64
    module_count = int.from_bytes(mods[2], 'big')
    assert len(mods) == 3 + module_count and module_count == 0
    domain_local = keccak(encode(['bytes32', 'uint256', 'address'],
        [keccak(text='EIP712Domain(uint256 chainId,address verifyingContract)'), 84532, SAFE]))
    domain_live = bytes.fromhex(rpc('eth_call', [{'to': SAFE, 'data': cd('domainSeparator()')}, tag])[2:])
    assert domain_local == domain_live
    # This independent implementation reproduces both already-observed queue SafeTx hashes.
    for row in queue.TXS:
        old = json.loads((SOURCE / row[1]).read_text())['reviewedSafeTxFields']
        assert safe_tx_hash(old, domain_live).lower() == row[3].lower()

    execute_abi = next(x for x in json.loads((ROOT / 'out/ProtocolTimelock.sol/ProtocolTimelock.json').read_text())['abi']
                       if x.get('name') == 'executeTransaction' and x['type'] == 'function')
    assert execute_abi['stateMutability'] == 'payable' and execute_abi['outputs'][0]['type'] == 'bytes'
    assert cd('executeTransaction(address,uint256,bytes,uint256)',
              (ctx['deps']['insuranceFund()'], 0, json.loads((SOURCE / queue.TXS[0][1]).read_text())['innerCalldata'], ETA))[:10] == '0x06a41d09'
    builder_method = {'name': 'executeTransaction', 'inputs': execute_abi['inputs'], 'payable': True}
    OUT.mkdir(exist_ok=True)
    save('execute_transaction_abi.json', [execute_abi])
    operations = []
    for ordinal, row in enumerate(queue.TXS, 1):
        name = 'g1_insurance' if ordinal == 1 else 'g2_vault'
        old = json.loads((SOURCE / row[1]).read_text())
        # Decode the actual canonical TransactionQueued event, then compare to the approved file.
        receipt = rpc('eth_getTransactionReceipt', [row[2]])
        queued_log = next(log for log in receipt['logs'] if
                          log['address'].lower() == TIMELOCK.lower() and
                          log['topics'][0].lower() == queue.TIMELOCK_QUEUED)
        event_data = bytes.fromhex(queued_log['data'][2:])
        inner_length = int.from_bytes(event_data[96:128], 'big')
        inner = '0x' + event_data[128:128 + inner_length].hex()
        assert inner.lower() == old['innerCalldata'].lower()
        target = old['target']
        assert old['eta'] == ETA and old['operationId'].lower() == included[ordinal-1]['operationId'].lower()
        assert inner[:10].lower() == ('0x0f62e507' if ordinal == 1 else '0x3331c56e')
        inner_bytes = bytes.fromhex(inner[10:])
        assert len(inner_bytes) == 64 and int.from_bytes(inner_bytes[:32], 'big') == int(ctx['NEW'], 16)
        assert int.from_bytes(inner_bytes[32:], 'big') == 1
        assert target.lower() == (ctx['deps']['insuranceFund()'] if ordinal == 1 else ctx['VAULT']).lower()
        encoded = encode(['address', 'uint256', 'bytes', 'uint256'], [target, 0, bytes.fromhex(inner[2:]), ETA])
        local_id = '0x' + keccak(encoded).hex()
        assert local_id.lower() == old['operationId'].lower()
        assert rpc('eth_call', [{'to': TIMELOCK, 'data': cd('hashOperation(address,uint256,bytes,uint256)',
            (target, 0, inner, ETA))}, tag]).lower() == local_id.lower()
        assert call(rpc, TIMELOCK, 'queuedTransactions(bytes32)', [local_id], tag) == [1]
        assert call(rpc, TIMELOCK, 'isOperationReady(address,uint256,bytes,uint256)',
                    [target, 0, inner, ETA], tag) == [int(ETA <= timestamp <= ETA + grace)]
        getter = 'isBackstopCaller(address)' if ordinal == 1 else 'isAuthorizedEngine(address)'
        assert call(rpc, target, getter, [ctx['NEW']], tag) == [0]
        outer = cd('executeTransaction(address,uint256,bytes,uint256)', (target, 0, inner, ETA))
        assert outer == '0x06a41d09' + encoded.hex()
        nonce = safe_nonce + ordinal - 1
        fields = {'to': TIMELOCK, 'value': '0', 'data': outer, 'operation': 0,
                  'safeTxGas': '0', 'baseGas': '0', 'gasPrice': '0',
                  'gasToken': ZERO, 'refundReceiver': ZERO, 'nonce': nonce}
        local_hash = safe_tx_hash(fields, domain_live)
        onchain_hash = rpc('eth_call', [{'to': SAFE, 'data': cd(
            'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)',
            (TIMELOCK, 0, outer, 0, 0, 0, 0, ZERO, ZERO, nonce))}, tag])
        assert onchain_hash.lower() == local_hash.lower()
        if ETA <= timestamp <= ETA + grace:
            rpc('eth_call', [{'from': SAFE, 'to': TIMELOCK, 'data': outer, 'value': '0x0'}, tag])
        builder = {'version': '1.0', 'chainId': '84532', 'createdAt': timestamp * 1000,
                   'meta': {'name': name.upper() + '_EXECUTE', 'description': 'Review only: one direct Safe CALL to execute one queued Timelock operation',
                            'txBuilderVersion': '1.18.0', 'createdFromSafeAddress': SAFE,
                            'createdFromOwnerAddress': ''},
                   'transactions': [{'to': TIMELOCK, 'value': '0', 'data': outer,
                                     'contractMethod': builder_method,
                                     'contractInputsValues': {'target': target, 'value': '0',
                                                              'data': inner, 'eta': str(ETA)}}]}
        builder_path = save(name + '_execute_safe_builder.json', builder)
        manifest = {'operation': name.upper(), 'chainId': 84532, 'safe': SAFE,
                    'safeTxHashLocal': local_hash, 'safeTxHashOnchainGetter': onchain_hash,
                    'safeTxFields': fields, 'safeNonceConditionalOnPriorSuccess': ordinal == 2,
                    'innerFunction': old['innerFunction'], 'innerCalldata': inner,
                    'outerFunction': 'executeTransaction(address,uint256,bytes,uint256)',
                    'outerSelector': '0x06a41d09', 'outerCalldata': outer,
                    'operationId': local_id, 'eta': ETA, 'executionWindowEnd': ETA + grace,
                    'targetPermissionBefore': False, 'expectedPermissionAfter': True,
                    'expectedQueueFlagAfter': False,
                    'builderFileSha256': sha(builder_path),
                    'temporalStatus': ('NOT_YET_EXECUTABLE' if timestamp < ETA else
                                       'EXECUTABLE' if timestamp <= ETA + grace else 'EXPIRED'),
                    'warning': 'Builder import does not bind nonce/gas/refund fields. Compare the actual constructed Safe transaction before signature.'}
        manifest_path = save(name + '_execute_review_manifest.json', manifest)
        operations.append({'name': name, 'operationId': local_id, 'target': target,
                           'innerCalldata': inner, 'outerCalldata': outer,
                           'safeNonceForReview': nonce, 'safeTxHash': local_hash,
                           'builderSha256': sha(builder_path), 'manifestSha256': sha(manifest_path),
                           'queued': True, 'targetPermission': False})

    # Scope the no-change event check to the post-queue interval and reviewed emitters.
    emitters = [ctx[x] for x in ('NEW', 'OLD', 'V1', 'PME', 'PME1', 'RISK', 'VAULT', 'PMR')]
    emitters += [ctx['deps']['feesManagerV2()'], ctx['deps']['insuranceFund()'], TIMELOCK, SAFE]
    relevant_logs = []
    for start in range(47614195, block + 1, 2000):
        relevant_logs.extend(rpc('eth_getLogs', [{'address': emitters, 'fromBlock': hex(start),
                                                 'toBlock': hex(min(start + 1999, block))}]))
    assert not relevant_logs, 'Unexpected protocol/governance event after queue postflight'
    assert rpc('eth_getBlockByNumber', [tag, False])['hash'].lower() == latest['hash'].lower()
    evidence = {'result': 'PAYLOAD_PREPARED', 'chainId': 84532,
                'comparisonBlock': block, 'comparisonBlockHash': latest['hash'],
                'comparisonTimestamp': timestamp, 'comparisonUTC': utc(timestamp),
                'observedHeads': observed_heads,
                'timeGate': ('NOT_YET_EXECUTABLE' if timestamp < ETA else
                             'EXECUTABLE' if timestamp <= ETA + grace else 'EXPIRED'),
                'remainingSeconds': max(0, ETA - timestamp), 'eta': ETA,
                'windowEnd': ETA + grace, 'canonicalQueueReceipts': included,
                'timelock': {'owner': SAFE, 'safeExecutor': True, 'minDelay': min_delay,
                             'gracePeriod': grace, 'queuePaused': queue_paused},
                'safe': {'nonce': safe_nonce, 'owners': owners, 'threshold': threshold,
                         'modules': [], 'domainSeparator': '0x' + domain_live.hex()},
                'operations': operations, 'economicChecks': len(state['checks']),
                'seedFlags': len(state['seedFlags']), 'positionIndexes': len(state['positionIndexes']),
                'traderNonces': len(state['pmeV2Nonces']), 'clearingBalanceNative': 1000000000,
                'maintenanceFlags': controls, 'pmeRiskStillOld': True,
                'fmv2NewConsumer': False, 'backendLocalRuntimeState': 'STOPPED',
                'postQueueScopedEvents': len(relevant_logs), 'postQueueScanFromBlock': 47614195,
                'safeInterfaceComparison': 'PENDING', 'publicWrites': 0,
                'keystoreAccess': False, 'signaturesGenerated': False}
    save('preparation_readback.json', evidence)
    print(json.dumps({'block': block, 'timestamp': timestamp, 'timeGate': evidence['timeGate'],
                      'remainingSeconds': evidence['remainingSeconds'], 'safeNonce': safe_nonce,
                      'operations': [{k: item[k] for k in ('name', 'safeTxHash', 'manifestSha256')}
                                     for item in operations]}, indent=2))


if __name__ == '__main__':
    main()
