#!/usr/bin/env python3
"""M4 Stage A only: allowlisted RPC reads, exact seal eth_call and gas estimate.

No signing, keystore access, broadcast, fork mutation or state override. Existing
M3 artifacts are read unchanged; evidence is written only to the M4 directory.
Run with the existing cbor2 decoder available on PYTHONPATH; never use python -O.
"""
import concurrent.futures
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'artifacts/perps_v2_migration_reseal'
CHECKPOINT = 'a43e66245871a6286dcc158ef08e2f0373494a6a'
BACKEND_HEAD = 'ad8dd7466aeba6963d28687e825fe4df58ef32ee'
PACKAGE_HASH = 'bdcc5f48b4637822316752358e3c37324cf6e3aa85f86dc406b1e0f74bee5738'
HELPER_HASH = 'c0799fb5eafaf0f318dfe4ac2b7b275b0eaa8b0983bc87a61dbf8a465bb28ffc'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare_context():
    """Reuse only pinned read helpers; exclude the historical file write/main."""
    helper = ROOT / 'tools/perps_v2_cutover/migration_replay_preflight.py'
    assert digest(helper) == HELPER_HASH
    source = helper.read_text()
    prefix = source.split("assert int(live('eth_chainId',[]),16)==84532")[0]
    historical_write = "(DESTINATION/'storage_layout.json').write_text(json.dumps(layout,indent=2)+'\\n')"
    assert prefix.count(historical_write) == 1
    prefix = prefix.replace(historical_write, '')
    ctx = {'__file__': str(helper)}
    exec(compile(prefix, str(helper), 'exec'), ctx)
    ctx['READS'].add('eth_estimateGas')
    exec(compile(source[source.index('checks=[]'):source.index('def runcheck(item):')], str(helper), 'exec'), ctx)
    manifest = ctx['manifest']
    positions = {(p['trader'].lower(), p['marketId']): p for p in manifest['positions']}
    markets = {m['marketId']: m for m in manifest['markets']}
    checks = []
    for label, address, sig, want, args in ctx['checks']:
        if address.lower() == ctx['NEW'].lower():
            if sig == 'marketState(uint256)':
                m = markets[args[0]]
                want = [m[k] for k in ['longOI1e8', 'shortOI1e8', 'cumulativeFundingRate1e18', 'lastFundingTimestamp']]
            elif sig == 'positions(address,uint256)':
                p = positions.get((args[0].lower(), args[1]))
                want = [p[k] for k in ['size1e8', 'openNotional1e8', 'lastCumulativeFundingRate1e18']] if p else [0, 0, 0]
            elif sig == 'getTraderMarketsLength(address)':
                want = 1
            elif sig == 'totalAbsLongSize1e8(address)':
                want = max(positions[(args[0].lower(), 1)]['size1e8'], 0)
            elif sig == 'totalAbsShortSize1e8(address)':
                want = max(-positions[(args[0].lower(), 1)]['size1e8'], 0)
        checks.append((label, address, sig, want, args))
    ctx['checks'] = checks
    return ctx


def reconcile_state(ctx, tag, previous):
    rpc, expect, flag = ctx['live'], ctx['expect'], ctx['flag']
    def run(item):
        label, address, sig, want, args = item
        return {'label': label, 'address': address, 'function': sig, 'args': args,
                'value': expect(rpc, address, sig, want, args, tag), 'passed': True}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        checks = list(pool.map(run, ctx['checks']))
    flags = [flag(rpc, '_marketFundingSeeded', (mid,), 1, tag) for mid in [1, 2]]
    indexes = []
    for p in ctx['manifest']['positions']:
        trader, mid = p['trader'], p['marketId']
        flags.append(flag(rpc, '_positionSeeded', (trader, mid), 1, tag))
        flags.append(flag(rpc, '_residualBadDebtSeeded', (trader,), 0, tag))
        indexes.append(flag(rpc, 'traderMarketIndexPlus1', (trader, mid), 1, tag))
        expect(rpc, ctx['NEW'], 'getTraderMarketsSlice(address,uint256,uint256)', [32, 1, mid], [trader, 0, 1], tag)
    nonces = {t: expect(rpc, ctx['PME'], 'nonces(address)', n, [t], tag)
              for t, n in previous['pmeV2Nonces'].items()}
    return {'checks': checks, 'seedFlags': flags, 'positionIndexes': indexes, 'pmeV2Nonces': nonces}


def verify_receipts(ctx, previous):
    rpc = ctx['live']
    result = []
    for row, step in zip(previous['transactions'], ctx['package']['orderedSteps']):
        tx = rpc('eth_getTransactionByHash', [row['hash']])
        receipt = rpc('eth_getTransactionReceipt', [row['hash']])
        block = rpc('eth_getBlockByNumber', [hex(row['block']), False])
        assert tx and receipt and block
        assert tx['hash'] == receipt['transactionHash'] == row['hash']
        assert tx['blockHash'] == receipt['blockHash'] == block['hash'] == row['blockHash']
        assert int(block['hash'], 16) != 0
        assert int(tx['blockNumber'], 16) == int(receipt['blockNumber'], 16) == row['block']
        assert row['hash'] in block['transactions'] and int(receipt['status'], 16) == 1
        assert tx['from'].lower() == ctx['OWNER'].lower() and tx['to'].lower() == ctx['NEW'].lower()
        assert int(tx['chainId'], 16) == 84532 and int(tx['nonce'], 16) == row['nonce']
        assert int(tx['value'], 16) == 0 and tx['input'].lower() == step['calldata'].lower()
        assert receipt['logs'] and len(receipt['logs']) == 1
        assert receipt['logs'][0]['address'].lower() == ctx['NEW'].lower()
        result.append({'ordinal': row['ordinal'], 'hash': row['hash'], 'block': row['block'],
                       'blockHash': block['hash'], 'status': 1, 'senderTargetNonceCalldataVerified': True})
    assert len(result) == 8
    return result


def scan_changes(ctx, start, end):
    # Only the window after the committed M3 postflight. Include configuration
    # events as well as trades; no historical V1 rescan or full-block scan.
    addresses = list(dict.fromkeys([ctx[k] for k in ['NEW', 'OLD', 'V1', 'PME', 'PME1', 'RISK', 'VAULT', 'PMR']]
                                  + [ctx['deps']['feesManagerV2()'], ctx['deps']['insuranceFund()']]))
    count = 0
    for first in range(start, end + 1, 2000):
        logs = ctx['live']('eth_getLogs', [{'address': addresses, 'fromBlock': hex(first),
                                          'toBlock': hex(min(first + 1999, end))}])
        count += len(logs)
        if logs:
            OUT.mkdir(exist_ok=True)
            (OUT/'unexpected_activity.json').write_text(json.dumps([
                {k: entry[k] for k in ['address', 'transactionHash', 'blockNumber', 'topics']}
                for entry in logs], indent=2) + '\n')
            raise AssertionError('Unexpected activity since replay postflight; review before seal')
    return {'fromBlock': start, 'toBlock': end, 'emitters': addresses,
            'topics': 'all events from these exact emitters', 'events': count}


def main():
    assert not sys.flags.optimize, 'Assertions must remain enabled'
    sol_head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    backend = ROOT.parent / 'deopt-v2-backend'
    backend_head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=backend, text=True).strip()
    assert sol_head == CHECKPOINT and backend_head == BACKEND_HEAD
    assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=backend, text=True).strip()
    preserved = list((ROOT/'artifacts/perps_v2_final_snapshot').glob('*')) + list((ROOT/'artifacts/perps_v2_migration_replay').glob('*.json'))
    before = {str(p.relative_to(ROOT)): digest(p) for p in preserved if p.is_file()}
    ctx = prepare_context()
    rpc, expect, call = ctx['live'], ctx['expect'], ctx['call']
    NEW, OWNER = ctx['NEW'], ctx['OWNER']
    assert digest(ctx['DESTINATION']/'execution_package.json') == PACKAGE_HASH
    previous = json.loads((ctx['DESTINATION']/'postflight.json').read_text())
    assert previous['status'] == 'PERPS_V2_BASE_SEPOLIA_MIGRATION_REPLAY_V1_COMPLETE'
    prior_observations = json.loads((ctx['DESTINATION']/'receipt_block_reconciliation.json').read_text())
    assert len(prior_observations['observations']) == 8
    assert int(rpc('eth_chainId', []), 16) == 84532
    block = rpc('eth_getBlockByNumber', ['latest', False])
    assert int(block['hash'], 16) != 0 and int(block['number'], 16) > previous['block']
    tag = block['number']
    assert rpc('eth_getBlockByNumber', [hex(ctx['manifest']['snapshotBlockNumber']), False])['hash'] == ctx['manifest']['snapshotBlockHash']
    code = bytes.fromhex(rpc('eth_getCode', [NEW, tag])[2:])
    assert code == ctx['linked'](ctx['artifact'], 'deployedBytecode')
    assert len(code) == 24321 and '0x'+ctx['keccak256'](code).hex() == ctx['ENGINE_HASH']
    assert int(rpc('eth_getTransactionCount', [OWNER, 'latest']), 16) == 807
    assert int(rpc('eth_getTransactionCount', [OWNER, 'pending']), 16) == 807, 'Nonce drift; no stale preview'
    report = {'milestone': 'PERPS_V2_BASE_SEPOLIA_MIGRATION_RESEAL_V1', 'stage': 'A',
              'solHead': sol_head, 'backendHead': backend_head, 'chainId': 84532,
              'publicWrites': 0, 'keystoreUnlocked': False, 'comparisonBlock': int(tag, 16),
              'comparisonBlockHash': block['hash'], 'snapshotHash': ctx['SNAPSHOT'],
              'canonicalFileSha256': ctx['hashes'], 'recoveryPackageSha256': PACKAGE_HASH,
              'jsonCborSemanticAgreement': True, 'runtimeBytes': len(code), 'runtimeKeccak256': ctx['ENGINE_HASH']}
    report['replayReceipts'] = verify_receipts(ctx, previous)
    report['inclusionHeads'] = {}
    for head in ['safe', 'finalized']:
        try:
            h = rpc('eth_getBlockByNumber', [head, False])
            assert h and int(h['hash'], 16) != 0
            report['inclusionHeads'][head] = {'block': int(h['number'], 16), 'hash': h['hash']}
        except (RuntimeError, AssertionError):
            report['inclusionHeads'][head] = {'supported': False}
    last_seed = max(r['block'] for r in report['replayReceipts'])
    covering = [name for name in ['finalized', 'safe'] if report['inclusionHeads'][name].get('block', 0) >= last_seed]
    assert covering, 'No safe/finalized head covering the eight seeds'
    report['receiptInclusionTagUsed'] = covering[0]
    print('Canonical artifacts and eight replay receipts verified; head tag:', covering[0], flush=True)
    report.update(reconcile_state(ctx, tag, previous))
    report['positionTotals'] = previous['positionTotals']
    assert sum(p['size1e8'] for p in ctx['manifest']['positions']) == 0
    report['positions'] = ctx['manifest']['positions']
    report['markets'] = ctx['manifest']['markets']
    report['migrationState'] = 'OPEN'
    report['migrationSnapshotHash'] = '0x'+'00'*32
    report['eventScan'] = scan_changes(ctx, previous['block']+1, int(tag, 16))
    report.update(ctx['backend_stopped']())
    print('Full seeded-state, isolation and event-window checks passed', flush=True)

    # Refresh all economic and boundary checks at one new canonical block before
    # the exact OWNER-context eth_call and budget preview, not only OI totals.
    fresh = rpc('eth_getBlockByNumber', ['latest', False]); fresh_tag = fresh['number']
    assert int(fresh['hash'], 16) != 0
    report['freshness'] = {'block': int(fresh_tag, 16), 'blockHash': fresh['hash'],
                           **reconcile_state(ctx, fresh_tag, previous)}
    report['freshness']['eventScan'] = scan_changes(ctx, int(tag, 16)+1, int(fresh_tag, 16))
    assert rpc('eth_getCode', [NEW, fresh_tag]) == '0x'+code.hex()
    assert int(rpc('eth_chainId', []), 16) == 84532
    nonce = int(rpc('eth_getTransactionCount', [OWNER, 'latest']), 16)
    pending = int(rpc('eth_getTransactionCount', [OWNER, 'pending']), 16)
    assert nonce == pending == 807, 'OWNER nonce drift; no stale preview'
    balance = int(rpc('eth_getBalance', [OWNER, fresh_tag]), 16)
    assert balance == previous['ownerBalancePostWei'], 'Unexpected OWNER balance drift; reconcile before preview'
    safe_nonce = expect(rpc, ctx['SAFE'], 'nonce()', previous['safeNoncePost'], tag=fresh_tag)
    executor_nonce = int(rpc('eth_getTransactionCount', [ctx['EXECUTOR'], fresh_tag]), 16)
    assert executor_nonce == previous['executorNoncePost']
    assert int(rpc('eth_getTransactionCount', [ctx['EXECUTOR'], 'pending']), 16) == executor_nonce
    sig = 'sealMigration(bytes32)'
    assert ctx['artifact']['methodIdentifiers'][sig] == '05d5af5b'
    data = ctx['calldata'](sig, (ctx['SNAPSHOT'],))
    assert data == '0x05d5af5b'+ctx['SNAPSHOT'][2:]
    transaction = {'from': OWNER, 'to': NEW, 'value': '0x0', 'data': data, 'gas': hex(1000000)}
    result = rpc('eth_call', [transaction, fresh_tag])
    assert result == '0x', 'Unexpected seal eth_call result'
    gas = int(rpc('eth_estimateGas', [transaction, fresh_tag]), 16)
    gas_limit = (gas*130+99)//100
    priority = int(rpc('eth_maxPriorityFeePerGas', []), 16)
    gas_price = int(rpc('eth_gasPrice', []), 16)
    max_fee = max(2*int(fresh['baseFeePerGas'], 16)+priority, gas_price)
    l1 = call(rpc, '0x420000000000000000000000000000000000000F', 'getL1FeeUpperBound(uint256)', [512], fresh_tag)[0]
    budget = gas_limit*max_fee + 2*l1
    assert balance > budget, 'Insufficient ETH; no automatic top-up'
    event = next(a for a in ctx['artifact']['abi'] if a.get('type') == 'event' and a.get('name') == 'MigrationSealed')
    assert event['inputs'] == [{'name': 'snapshotHash', 'type': 'bytes32', 'indexed': False, 'internalType': 'bytes32'},
                               {'name': 'sealer', 'type': 'address', 'indexed': True, 'internalType': 'address'}]
    event_topic = '0x'+ctx['keccak256'](b'MigrationSealed(bytes32,address)').hex()
    report.update(ownerNonce=nonce, ownerPendingNonce=pending, ownerBalanceWei=balance,
                  ownerBalanceETH=str(Decimal(balance)/Decimal(10**18)), safeNonce=safe_nonce, executorNonce=executor_nonce)
    report['simulation'] = {'method': 'eth_call', 'block': int(fresh_tag, 16), 'from': OWNER, 'to': NEW,
                            'data': data, 'value': 0, 'result': result, 'stateOverrides': False, 'passed': True}
    report['fees'] = {'gasEstimate': gas, 'gasLimitWithMargin': gas_limit, 'gasMarginPercent': 30,
                      'baseFeePerGasWei': int(fresh['baseFeePerGas'], 16), 'priorityFeePerGasWei': priority,
                      'maxFeePerGasWei': max_fee, 'l1FeeUpperBound512BytesWei': l1, 'l1AllowanceWei': 2*l1,
                      'maxBudgetWei': budget, 'maxBudgetETH': str(Decimal(budget)/Decimal(10**18))}
    report['expectedEvent'] = {'emitter': NEW, 'signature': 'MigrationSealed(bytes32,address)',
                               'topics': [event_topic, '0x'+OWNER[2:].lower().zfill(64)], 'data': ctx['SNAPSHOT']}
    preview = {'chainId': 84532, 'from': OWNER, 'to': NEW, 'nonce': nonce, 'value': 0,
               'function': sig, 'selector': '0x05d5af5b', 'args': [ctx['SNAPSHOT']], 'calldata': data,
               'gasLimit': gas_limit, 'maxFeePerGasWei': max_fee, 'maxPriorityFeePerGasWei': priority}
    report['transaction'] = preview
    report.update(ctx['backend_stopped']())
    assert rpc('eth_getBlockByNumber', [tag, False])['hash'] == block['hash']
    assert rpc('eth_getBlockByNumber', [fresh_tag, False])['hash'] == fresh['hash']
    assert {p: digest(ROOT/p) for p in before} == before, 'Historical artifact mutation'
    report['preservedArtifactSha256'] = before
    report['status'] = 'PERPS_V2_BASE_SEPOLIA_MIGRATION_RESEAL_V1_READY_TO_BROADCAST'
    OUT.mkdir(exist_ok=True)
    encoded = (json.dumps(preview, indent=2)+'\n').encode()
    report['previewSha256'] = hashlib.sha256(encoded).hexdigest()
    (OUT/'transaction_preview.json').write_bytes(encoded)
    (OUT/'preflight.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k: report[k] for k in ['status', 'comparisonBlock', 'comparisonBlockHash', 'receiptInclusionTagUsed',
          'ownerNonce', 'ownerPendingNonce', 'ownerBalanceETH', 'fees', 'transaction', 'previewSha256']}, indent=2))


if __name__ == '__main__':
    main()
