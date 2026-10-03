#!/usr/bin/env python3
"""Read-only Base Sepolia inventory for a proposed restricted first trade."""
import datetime as dt
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
import migration_reseal_preflight as migration
import maintenance_lock_preflight as maintenance

ROOT = migration.ROOT
OUT = ROOT / 'artifacts/perps_v2_restricted_first_trade_guard'
OWNER = '0xc35F7A8A103A9A4464adfaa76B9B514093D23C27'
EXECUTOR = '0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8'
BUYER = '0x66858286fEEA78a05eA093673EA1535E0A52002d'
SELLER = '0xff287410852B9328437eaC353720e5476bC5F837'
ENGINE_HASH = '0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a'
OPS = ('0x824bc77bb68ff4878d2e477478ed4d120abab89ce27b181a7c8ecc5ba7cfa3f6',
       '0x02705011c0ee36d4928843bfb5641ff90aebf658162735668774768a7bc3e846')


def signed(value):
    return value if value < 2**255 else value-2**256


def main():
    assert not sys.flags.optimize
    ctx = migration.prepare_context()
    rpc, call = ctx['live'], ctx['call']
    assert int(rpc('eth_chainId', []), 16) == 84532
    block = rpc('eth_getBlockByNumber', ['latest', False])
    tag = block['number']
    assert int(block['hash'], 16) != 0
    assert ctx['OWNER'].lower() == OWNER.lower()
    assert ctx['PME'].lower() == '0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2'.lower()
    assert call(rpc, ctx['PME'], 'owner()', tag=tag) == [int(OWNER, 16)]
    assert call(rpc, ctx['PME'], 'paused()', tag=tag) == [1]
    assert call(rpc, ctx['PME1'], 'paused()', tag=tag) == [1]
    assert call(rpc, ctx['PME'], 'perpEngine()', tag=tag) == [int(ctx['OLD'], 16)]
    assert call(rpc, ctx['RISK'], 'perpEngine()', tag=tag) == [int(ctx['OLD'], 16)]
    code = bytes.fromhex(rpc('eth_getCode', [ctx['NEW'], tag])[2:])
    assert len(code) == 24321 and '0x'+ctx['keccak256'](code).hex() == ENGINE_HASH
    assert call(rpc, ctx['NEW'], 'migrationState()', tag=tag) == [1]
    assert call(rpc, ctx['NEW'], 'migrationSnapshotHash()', tag=tag) == [int(ctx['SNAPSHOT'], 16)]
    assert all(call(rpc, maintenance.TIMELOCK, 'queuedTransactions(bytes32)', [op], tag) == [1]
               for op in OPS)
    assert call(rpc, ctx['VAULT'], 'isAuthorizedEngine(address)', [ctx['NEW']], tag) == [0]
    assert call(rpc, ctx['deps']['insuranceFund()'], 'isBackstopCaller(address)', [ctx['NEW']], tag) == [0]
    assert call(rpc, ctx['deps']['feesManagerV2()'], 'isFeeConsumer(address)', [ctx['NEW']], tag) == [0]
    controls = {name: [call(rpc, ctx[name], sig, tag=tag)[0] for sig in maintenance.FLAGS]
                for name in ('NEW', 'OLD', 'V1')}
    assert all(v == [1, 1, 1, 1] for v in controls.values())
    positions = {}
    for role, trader, expected in (('buyer', BUYER, -1000000), ('seller', SELLER, 1000000)):
        p = call(rpc, ctx['NEW'], 'positions(address,uint256)', [trader, 1], tag)
        assert len(p) == 3 and signed(p[0]) == expected
        nonce = call(rpc, ctx['PME'], 'nonces(address)', [trader], tag)[0]
        assert nonce == 0, 'canonical trader nonce changed'
        positions[role] = {'trader': trader, 'size1e8': signed(p[0]),
                           'openNotional1e8': signed(p[1]),
                           'lastCumulativeFundingRate1e18': signed(p[2]),
                           'pmeNonce': nonce}
    assert call(rpc, ctx['PME'], 'isExecutor(address)', [OWNER], tag) == [1]
    assert call(rpc, ctx['PME'], 'isExecutor(address)', [EXECUTOR], tag) == [1]

    # Scan only ExecutorSet on the known PME from its exact deployment block.
    # This is the bounded full lifetime needed to enumerate this mapping.
    topic = '0x'+ctx['keccak256'](b'ExecutorSet(address,bool)').hex()
    begin, end = 47147788, int(tag, 16)
    prior_path = OUT/'preflight.json'
    prior = json.loads(prior_path.read_text()) if prior_path.exists() else None
    timeline = []
    states = {}
    scan_start = begin
    if prior:
        assert prior['chainId'] == 84532 and prior['executorEventScanFromBlock'] == begin
        assert prior['executorEventScanToBlock'] == prior['comparisonBlock']
        assert prior['executorEventCount'] == len(prior['executorTimeline'])
        assert prior['comparisonBlock'] < end
        old_block = rpc('eth_getBlockByNumber', [hex(prior['comparisonBlock']), False])
        assert old_block['hash'].lower() == prior['comparisonBlockHash'].lower()
        timeline = list(prior['executorTimeline'])
        for item in timeline:
            states[item['executor'].lower()] = item['allowed']
        scan_start = prior['comparisonBlock']+1
    events = []
    for lo in range(scan_start, end+1, 2000):
        events += rpc('eth_getLogs', [{'address': ctx['PME'],
                                      'fromBlock': hex(lo),
                                      'toBlock': hex(min(lo+1999, end)),
                                      'topics': [topic]}])
    for log in events:
        assert log['address'].lower() == ctx['PME'].lower()
        assert len(log['topics']) == 2 and log['topics'][0].lower() == topic
        executor = '0x'+log['topics'][1][-40:]
        allowed = int(log['data'], 16)
        assert allowed in (0, 1)
        receipt = rpc('eth_getTransactionReceipt', [log['transactionHash']])
        assert receipt and int(receipt['status'], 16) == 1
        assert receipt['blockHash'].lower() == log['blockHash'].lower()
        states[executor.lower()] = bool(allowed)
        timeline.append({'block': int(log['blockNumber'], 16),
                         'transactionHash': log['transactionHash'],
                         'executor': executor, 'allowed': bool(allowed)})
    assert states, 'No constructor ExecutorSet log; cannot enumerate executors'
    for executor, allowed in states.items():
        assert call(rpc, ctx['PME'], 'isExecutor(address)', [executor], tag)[0] == int(allowed)
    active = sorted(executor for executor, allowed in states.items() if allowed)
    assert set(active) == {OWNER.lower(), EXECUTOR.lower()}, 'Unexpected active executor; review separately'
    # Since the signed-order-resolution postflight, no PME trade, rebind,
    # pause change or executor configuration event should have appeared.
    recent_logs = []
    for lo in range(47615267, end+1, 2000):
        recent_logs += rpc('eth_getLogs', [{'address': ctx['PME'], 'fromBlock': hex(lo),
                                            'toBlock': hex(min(lo+1999, end))}])
    assert not recent_logs, 'Unexpected PME activity since prior postflight'
    assert ctx['backend_stopped']()['backend_runtime_state'] == 'STOPPED'
    report = {'milestone': 'PERPS_V2_BASE_SEPOLIA_RESTRICTED_FIRST_TRADE_GUARD_V1',
              'result': 'READ_ONLY_PREFLIGHT', 'chainId': 84532,
              'comparisonBlock': end, 'comparisonBlockHash': block['hash'],
              'comparisonUTC': dt.datetime.fromtimestamp(int(block['timestamp'],16),dt.timezone.utc).isoformat(),
              'runtimeExecutorFromCommittedEvidence': EXECUTOR,
              'pmeDeploymentBlock': begin, 'executorEventScanFromBlock': begin,
              'executorEventScanToBlock': end, 'executorEventCount': len(timeline),
              'executorTimeline': timeline, 'activeExecutors': active,
              'pmeEventScanFromBlock': 47615267, 'pmeEventScanToBlock': end,
              'pmeEventCountSinceSignedOrderPostflight': len(recent_logs),
              'currentPmeEngine': ctx['OLD'], 'proposedEngine': ctx['NEW'],
              'newEngineRuntimeSize': len(code), 'newEngineRuntimeEthereumKeccak': ENGINE_HASH,
              'positions': positions, 'maintenanceControls': controls,
              'G1Queued': True, 'G2Queued': True,
              'newInsuranceAuthorized': False, 'newVaultAuthorized': False,
              'newFeeConsumerAuthorized': False,
              'backendLocalRuntime': 'STOPPED',
              'publicWrites': 0, 'keystoreAccess': False}
    OUT.mkdir(exist_ok=True)
    (OUT/'preflight.json').write_text(json.dumps(report, indent=2, sort_keys=True)+'\n')
    print(json.dumps({'block': end, 'executorEvents': len(timeline),
                      'activeExecutors': active, 'buyerSize': positions['buyer']['size1e8'],
                      'sellerSize': positions['seller']['size1e8'], 'queued': 2}))


if __name__ == '__main__':
    main()
