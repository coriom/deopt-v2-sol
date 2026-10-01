#!/usr/bin/env python3
"""M5 read-only baseline and maintenance probe. No signer or send path.

Uses existing pinned M3/M4 readers. Does not prepare an executable package:
unresolved authority, maintenance and signed-order gates need separate review.
"""
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
import migration_reseal_preflight as previous

ROOT = previous.ROOT
OUT = ROOT / 'artifacts/perps_v2_rebind'


def main():
    assert not sys.flags.optimize
    c = previous.prepare_context()
    rpc, call = c['live'], c['call']
    prior = json.loads((previous.OUT / 'postflight.json').read_text())
    assert prior['status'] == 'PERPS_V2_BASE_SEPOLIA_MIGRATION_RESEAL_V1_COMPLETE'
    assert int(rpc('eth_chainId', []), 16) == 84532
    block = rpc('eth_getBlockByNumber', ['latest', False])
    tag = block['number']
    report = {'milestone': 'PERPS_V2_BASE_SEPOLIA_V2_REBIND_V1', 'stage': 'A_READBACK',
              'chainId': 84532, 'block': int(tag, 16), 'blockHash': block['hash'],
              'publicWrites': 0, 'keystoreUnlocked': False,
              'solHead': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              'backendHead': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT.parent/'deopt-v2-backend', text=True).strip(),
              'canonicalFileSha256': c['hashes'], 'snapshotHash': c['SNAPSHOT'],
              'jsonCborSemanticAgreement': True}
    assert report['solHead'] == 'fe5a7e4588504fdaf50db2ea940943c75442a8e7'
    assert report['backendHead'] == 'ad8dd7466aeba6963d28687e825fe4df58ef32ee'
    assert rpc('eth_getBlockByNumber', [hex(c['manifest']['snapshotBlockNumber']), False])['hash'] == c['manifest']['snapshotBlockHash']
    code = bytes.fromhex(rpc('eth_getCode', [c['NEW'], tag])[2:])
    assert code == c['linked'](c['artifact'], 'deployedBytecode')
    assert len(code) == 24321 and '0x'+c['keccak256'](code).hex() == c['ENGINE_HASH']
    report['runtime'] = {'bytes': len(code), 'ethereumKeccak256': c['ENGINE_HASH'], 'equalsFrozenArtifact': True}
    h = prior['transactionHash']
    assert h == '0xf4cd9b68d0b21734e2d1ab4710b52b20ca36a7458e8fcc518d01731e07b0cec2'
    tx = rpc('eth_getTransactionByHash', [h])
    receipt = rpc('eth_getTransactionReceipt', [h])
    included = rpc('eth_getBlockByNumber', [receipt['blockNumber'], False])
    assert tx['hash'] == receipt['transactionHash'] == h
    assert tx['blockHash'] == receipt['blockHash'] == included['hash'] == prior['receiptBlockHash']
    assert int(included['hash'], 16) and h in included['transactions']
    assert int(receipt['status'], 16) == 1 and tx['from'].lower() == c['OWNER'].lower()
    assert tx['to'].lower() == c['NEW'].lower() and int(tx['nonce'], 16) == 807
    assert tx['input'] == c['calldata']('sealMigration(bytes32)', (c['SNAPSHOT'],))
    assert int(tx['value'], 16) == 0 and receipt['logs'] == [prior['event']]
    report['sealInclusion'] = {'hash': h, 'block': int(receipt['blockNumber'], 16),
                             'blockHash': included['hash'], 'status': 1, 'exactEventVerified': True}
    report['heads'] = {}
    for name in ['safe', 'finalized']:
        try:
            head = rpc('eth_getBlockByNumber', [name, False])
            report['heads'][name] = {'block': int(head['number'], 16), 'hash': head['hash'],
                                    'coversSeal': int(head['number'], 16) >= report['sealInclusion']['block']}
        except (RuntimeError, TypeError):
            report['heads'][name] = {'supported': False}
    c['checks'] = [(label, address, sig, 1 if sig == 'migrationState()' else c['SNAPSHOT'], args)
                   if address.lower() == c['NEW'].lower() and sig in ['migrationState()', 'migrationSnapshotHash()']
                   else (label, address, sig, want, args) for label, address, sig, want, args in c['checks']]
    state = previous.reconcile_state(c, tag, prior)
    state['checks'] = [{**row, 'args': list(row['args'])} for row in state['checks']]
    for key in ['checks', 'seedFlags', 'positionIndexes', 'pmeV2Nonces']:
        assert state[key] == prior[key], 'State drift since reseal: '+key
    report.update(state)
    print('Full economics and isolation: 114 checks, flags, indexes and PME nonces match reseal', flush=True)
    report['owners'] = {}
    for name, address in [('PME', c['PME']), ('RISK', c['RISK']),
                          ('FMV2', c['deps']['feesManagerV2()']), ('INSURANCE', c['deps']['insuranceFund()'])]:
        actual = '0x'+call(rpc, address, 'owner()', tag=tag)[0].to_bytes(20, 'big').hex()
        report['owners'][name] = {'address': actual, 'matchesOwnerEOA': actual.lower() == c['OWNER'].lower()}
    report['oldPermissions'] = {name: call(rpc, c['deps'][getter], sig, [c['OLD']], tag)[0]
        for name, getter, sig in [('feeConsumer', 'feesManagerV2()', 'isFeeConsumer(address)'),
                                  ('backstopCaller', 'insuranceFund()', 'isBackstopCaller(address)')]}
    report['pauses'] = {name: {sig: call(rpc, c[name], sig, tag=tag)[0]
                              for sig in ['tradingPaused()', 'fundingPaused()', 'liquidationPaused()']}
                         for name in ['NEW', 'OLD', 'V1']}
    report['pmePaused'] = call(rpc, c['PME'], 'paused()', tag=tag)[0]
    report['riskMaxOracleDelay'] = c['expect'](rpc, c['RISK'], 'maxOracleDelay()', 600, tag=tag)
    report['pmeDomainSeparator'] = rpc('eth_call', [{'to': c['PME'], 'data': c['calldata']('domainSeparatorV4()')}, tag])
    report['pmeEip712DomainAbi'] = rpc('eth_call', [{'to': c['PME'], 'data': c['calldata']('eip712Domain()')}, tag])
    report['executors'] = {a: call(rpc, c['PME'], 'isExecutor(address)', [a], tag)[0] for a in [c['OWNER'], c['EXECUTOR']]}
    report['ownerNonce'] = int(rpc('eth_getTransactionCount', [c['OWNER'], 'latest']), 16)
    report['ownerPendingNonce'] = int(rpc('eth_getTransactionCount', [c['OWNER'], 'pending']), 16)
    assert report['ownerNonce'] == report['ownerPendingNonce'] == 808
    report['ownerBalanceWei'] = int(rpc('eth_getBalance', [c['OWNER'], tag]), 16)
    report['safeNonce'] = c['expect'](rpc, c['SAFE'], 'nonce()', prior['safeNoncePost'], tag=tag)
    report['executorNonce'] = int(rpc('eth_getTransactionCount', [c['EXECUTOR'], tag]), 16)
    assert report['executorNonce'] == prior['executorNoncePost']
    emitters = prior['eventAudit']['emitters']
    logs = []
    for first in range(prior['block']+1, int(tag, 16)+1, 2000):
        logs.extend(rpc('eth_getLogs', [{'address': emitters, 'fromBlock': hex(first), 'toBlock': hex(min(first+1999, int(tag, 16)))}]))
    report['eventScan'] = {'fromBlock': prior['block']+1, 'toBlock': int(tag, 16), 'emitters': emitters, 'topics': 'all', 'events': logs}
    assert not logs, 'Unexpected scoped events since reseal'
    local = c['backend_stopped']()
    report['localBackend'] = {**local, 'scope': 'local /proc executable/comm and port 8080 only; no global activity claim'}
    probe = {'from': '0x0000000000000000000000000000000000000001', 'to': c['NEW'],
             'value': '0x0', 'data': c['calldata']('updateFunding(uint256)', (2,))}
    report['fundingProbe'] = {'method': 'eth_call', 'transaction': probe, 'block': int(tag, 16),
        'result': rpc('eth_call', [probe, tag]), 'publicWrite': False,
        'sourceEffect': 'market 2 lastFundingTimestamp becomes block.timestamp; FundingUpdated emitted in execution; eth_call discards state'}
    assert call(rpc, c['NEW'], 'marketState(uint256)', [2], tag) == [0, 0, 0, 0]
    # Optional read-only trace proves the storage effect without a fork transaction.
    c['READS'].add('debug_traceCall')
    try:
        trace = rpc('debug_traceCall', [probe, tag, {'tracer': 'prestateTracer', 'tracerConfig': {'diffMode': True}}])
        report['fundingProbe']['stateDiff'] = trace
    except RuntimeError:
        report['fundingProbe']['stateDiffAvailable'] = False
    report['result'] = 'BLOCKED_INSURANCE_AUTHORITY_MISMATCH'
    assert not report['owners']['INSURANCE']['matchesOwnerEOA'], 'Authority changed; review separately'
    report['fourCallForkRehearsal'] = 'NOT_RUN: Insurance authority gate failed; maintenance and signed-order gates also unresolved'
    report['executablePackage'] = None
    assert rpc('eth_getBlockByNumber', [tag, False])['hash'] == block['hash']
    OUT.mkdir(exist_ok=True)
    (OUT/'stage_a_readback.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k: report[k] for k in ['block', 'blockHash', 'heads', 'ownerNonce', 'ownerPendingNonce', 'ownerBalanceWei', 'oldPermissions', 'pauses', 'pmePaused', 'executors', 'result']}, indent=2))


if __name__ == '__main__':
    main()
