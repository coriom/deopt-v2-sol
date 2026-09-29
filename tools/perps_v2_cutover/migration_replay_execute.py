#!/usr/bin/env python3
"""One-shot, operator-approved M3 runner. Never retries or resumes a send.

The package hash and target are fixed to the reviewed eight seeds. Read-only
definitions/checks are reused from the exact Stage-A helper, never its fork loop.
Only explicit CLI confirmation enables execution. Wallet output is never logged.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'artifacts/perps_v2_migration_replay'
APPROVED = 'bdcc5f48b4637822316752358e3c37324cf6e3aa85f86dc406b1e0f74bee5738'
PREFLIGHT_HELPER = 'c0799fb5eafaf0f318dfe4ac2b7b275b0eaa8b0983bc87a61dbf8a465bb28ffc'
OWNER = '0xc35F7A8A103A9A4464adfaa76B9B514093D23C27'
NEW = '0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15'
PASSWORD = Path('/run/user/1000/deopt-deployer.pw')
KEYSTORE = '/home/corio/.foundry/keystores/deopt-deployer'


def check_receipt(receipt, tx, step, ordinal, expected_event):
    """Reject wrong receipt/transaction/event before any next public send."""
    assert receipt and int(receipt['status'], 16) == 1, 'Receipt failed or absent'
    assert receipt['transactionHash'].lower() == tx['hash'].lower()
    assert tx['from'].lower() == OWNER.lower() and tx['to'].lower() == NEW.lower()
    assert int(tx['chainId'], 16) == 84532 and int(tx['nonce'], 16) == 798 + ordinal
    assert int(tx['value'], 16) == 0 and tx['input'].lower() == step['calldata'].lower()
    assert not receipt.get('contractAddress'), 'Unexpected deployment'
    assert len(receipt['logs']) == 1, 'Unexpected event count'
    event = receipt['logs'][0]
    assert event['address'].lower() == NEW.lower(), 'Unexpected event emitter'
    assert [t.lower() for t in event['topics']] == expected_event['topics']
    assert event['data'].lower() == expected_event['data']


def save(journal):
    temp = OUT / 'execution_journal.json.tmp'
    with temp.open('w') as stream:
        json.dump(journal, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    temp.replace(OUT / 'execution_journal.json')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute-reviewed-package', required=True)
    args = parser.parse_args()
    if args.execute_reviewed_package != APPROVED:
        parser.error('Only the reviewed package hash is authorized')
    sys.dont_write_bytecode = True
    journal = {'milestone': 'PERPS_V2_BASE_SEPOLIA_MIGRATION_REPLAY_V1', 'chainId': 84532,
               'packageSha256': APPROVED, 'status': 'PRECHECK', 'successfulPrefix': 0,
               'transactions': [], 'publicSendInvocations': 0}
    ctx = None
    started = False
    try:
        assert hashlib.sha256((OUT / 'execution_package.json').read_bytes()).hexdigest() == APPROVED
        helper = ROOT / 'tools/perps_v2_cutover/migration_replay_preflight.py'
        source = helper.read_text()
        assert hashlib.sha256(helper.read_bytes()).hexdigest() == PREFLIGHT_HELPER
        ctx = {'__file__': str(helper)}
        prefix = source.split("assert int(live('eth_chainId',[]),16)==84532")[0]
        exec(compile(prefix, str(helper), 'exec'), ctx)
        live, expect, flag = ctx['live'], ctx['expect'], ctx['flag']
        package, manifest = ctx['package'], ctx['manifest']
        deps, call, calldata = ctx['deps'], ctx['call'], ctx['calldata']
        PMR, VAULT, PME, RISK = (ctx[k] for k in ['PMR', 'VAULT', 'PME', 'RISK'])
        pre = json.loads((OUT / 'prebroadcast.json').read_text())
        sim = json.loads((OUT / 'simulation.json').read_text())
        assert pre['approvedPackageSha256'] == APPROVED and sim['passed']
        assert pre['verifiedSigner'].lower() == OWNER.lower()
        assert int(live('eth_chainId', []), 16) == 84532
        # Verify independently again in this process; --from alone is not proof.
        metadata = PASSWORD.lstat()
        assert stat.S_ISREG(metadata.st_mode) and stat.S_IMODE(metadata.st_mode) == 0o600 and metadata.st_uid == 1000
        env = os.environ.copy()
        for name in ['ETH_PRIVATE_KEY', 'PRIVATE_KEY', 'DEPLOYER_PRIVATE_KEY', 'ETH_PASSWORD']:
            env.pop(name, None)
        signer = subprocess.run(['cast', 'wallet', 'address', '--keystore', KEYSTORE,
                                 '--password-file', str(PASSWORD)], cwd='/tmp', env=env,
                                capture_output=True, text=True, timeout=30)
        assert signer.returncode == 0 and signer.stdout.strip().lower() == OWNER.lower(), 'Keystore address mismatch'
        journal['independentlyVerifiedSigner'] = signer.stdout.strip()
        print('Signer independently verified as OWNER; checking final live boundary', flush=True)
        assert int(live('eth_getTransactionCount', [OWNER, 'latest']), 16) == 799
        assert int(live('eth_getTransactionCount', [OWNER, 'pending']), 16) == 799
        current = live('eth_getBlockByNumber', ['latest', False]); tag = current['number']
        assert int(tag, 16) - pre['prebroadcastBlock'] <= 600, 'Prebroadcast gates stale'
        assert live('eth_getCode', [NEW, tag]) == '0x' + ctx['linked'](ctx['artifact'], 'deployedBytecode').hex()
        assert not live('eth_getLogs', [{'address': pre['eventScan']['emitters'],
            'fromBlock': hex(pre['prebroadcastBlock']), 'toBlock': tag, 'topics': [pre['eventScan']['topics']]}])
        ctx['backend_stopped']()
        # Exclusive marker/journal: a later invocation must never restart ordinal one.
        marker = OUT / 'execution_started.json'
        assert not (OUT / 'execution_journal.json').exists(), 'Existing journal: no automatic resume'
        with marker.open('x') as stream:
            json.dump({'packageSha256': APPROVED, 'preblock': int(tag, 16), 'startingNonce': 799}, stream)
            stream.write('\n')
        started = True
        journal.update(status='RUNNING', preblock=int(tag, 16), preblockHash=current['hash'],
                       ownerBalancePreWei=int(live('eth_getBalance', [OWNER, tag]), 16),
                       safeNoncePre=pre['safeNonce'], executorNoncePre=pre['executorNonce'])
        save(journal)
        oi = [0, 0]
        for step, simulated in zip(package['orderedSteps'], sim['transactions']):
            i = step['ordinal']; values = step['args']; nonce = 798 + i
            assert i == journal['successfulPrefix'] + 1
            assert hashlib.sha256((OUT / 'execution_package.json').read_bytes()).hexdigest() == APPROVED
            assert int(live('eth_chainId', []), 16) == 84532
            assert int(live('eth_getTransactionCount', [OWNER, 'latest']), 16) == nonce
            assert int(live('eth_getTransactionCount', [OWNER, 'pending']), 16) == nonce
            before = live('eth_getBlockByNumber', ['latest', False]); before_tag = before['number']
            expect(live, NEW, 'migrationState()', 0, tag=before_tag)
            expect(live, NEW, 'migrationSnapshotHash()', 0, tag=before_tag)
            expect(live, NEW, 'marketState(uint256)', oi + [0, 0 if i == 1 else 1789715546], [1], before_tag)
            expect(live, NEW, 'marketState(uint256)', [0, 0, 0, 0], [2], before_tag)
            for contract in [PME, RISK]: expect(live, contract, 'perpEngine()', ctx['OLD'], tag=before_tag)
            expect(live, VAULT, 'isAuthorizedEngine(address)', 0, [NEW], before_tag)
            if i <= 2:
                flag(live, '_marketFundingSeeded', (values['marketId'],), 0, before_tag)
            else:
                trader, mid = values['trader'], values['marketId']
                flag(live, '_positionSeeded', (trader, mid), 0, before_tag)
                expect(live, NEW, 'positions(address,uint256)', [0, 0, 0], [trader, mid], before_tag)
                expect(live, NEW, 'getTraderMarketsLength(address)', 0, [trader], before_tag)
            # Keep the reviewed L2 fee cap and gas margin; fresh L1 allowance/balance.
            fee = pre['fees']; max_fee = fee['maxFeePerGasWei']; priority = fee['priorityFeePerGasWei']
            assert int(before['baseFeePerGas'], 16) + priority <= max_fee, 'Reviewed fee cap too low; stop'
            l1 = call(live, '0x420000000000000000000000000000000000000F', 'getL1FeeUpperBound(uint256)', [512], before_tag)[0]
            remaining_gas = sum(t['gasLimitWithMargin'] for t in sim['transactions'][i-1:])
            balance = int(live('eth_getBalance', [OWNER, before_tag]), 16)
            assert balance > remaining_gas * max_fee + 2 * l1 * (9-i), 'Insufficient ETH; no top-up'
            row = {'ordinal': i, 'nonce': nonce, 'target': NEW, 'value': 0, 'signature': step['signature'],
                   'args': values, 'calldata': step['calldata'], 'gasLimit': simulated['gasLimitWithMargin'],
                   'maxFeePerGasWei': max_fee, 'priorityFeePerGasWei': priority,
                   'preblock': int(before_tag, 16), 'state': 'SUBMITTING'}
            journal['transactions'].append(row)
            journal['publicSendInvocations'] += 1
            save(journal)  # Persist intent before calling any write-capable tool.
            command = ['cast', 'send', NEW, step['calldata'], '--async', '-j', '1', '--from', OWNER,
                       '--value', '0', '--nonce', str(nonce), '--chain', '84532',
                       '--gas-limit', str(row['gasLimit']), '--gas-price', str(max_fee),
                       '--priority-gas-price', str(priority), '--rpc-url', ctx['url'],
                       '--keystore', KEYSTORE, '--password-file', str(PASSWORD)]
            result = subprocess.run(command, cwd='/tmp', env=env, capture_output=True, text=True, timeout=90)
            output = result.stdout.strip().strip('"')
            if re.fullmatch(r'0x[0-9a-fA-F]{64}', output):
                row.update(hash=output, state='SUBMITTED'); save(journal)
            assert result.returncode == 0 and 'hash' in row, 'Submission failed/ambiguous; no retry; output withheld'
            print('Submitted seed', i, 'nonce', nonce, row['hash'], flush=True)
            deadline = time.monotonic() + 180
            receipt = None
            while time.monotonic() < deadline:
                receipt = live('eth_getTransactionReceipt', [row['hash']])
                if receipt is not None: break
                time.sleep(2)
            assert receipt is not None, 'Receipt timeout; reconcile before any continuation'
            row.update(receiptStatus=int(receipt['status'], 16), block=int(receipt['blockNumber'], 16),
                       blockHash=receipt['blockHash'], state='RECEIPT_OBSERVED')
            save(journal)
            tx = live('eth_getTransactionByHash', [row['hash']])
            event_name = 'MigrationMarketFundingSeeded' if i <= 2 else 'MigrationPositionSeeded'
            event_abi = next(a for a in ctx['artifact']['abi'] if a['type'] == 'event' and a['name'] == event_name)
            sig = event_name + '(' + ','.join(x['type'] for x in event_abi['inputs']) + ')'
            topic = '0x' + ctx['keccak256'](sig.encode()).hex()
            indexed, data = [], []
            for param in event_abi['inputs']:
                value = values[param['name']]
                value = int(value, 16) if isinstance(value, str) else value % (1 << 256)
                word = value.to_bytes(32, 'big').hex()
                (indexed if param['indexed'] else data).append(word)
            expected_event = {'topics': [topic] + ['0x'+v for v in indexed], 'data': '0x'+''.join(data)}
            check_receipt(receipt, tx, step, i, expected_event)
            after_tag = receipt['blockNumber']
            if i <= 2:
                row['seedFlag'] = flag(live, '_marketFundingSeeded', (values['marketId'],), 1, after_tag)
                row['marketReadback'] = expect(live, NEW, 'marketState(uint256)',
                    [0, 0, values['cumulativeFundingRate1e18'], values['lastFundingTimestamp']], [values['marketId']], after_tag)
            else:
                trader, mid, size = values['trader'], values['marketId'], values['size1e8']
                row['positionReadback'] = expect(live, NEW, 'positions(address,uint256)',
                    [values[k] for k in ['size1e8', 'openNotional1e8', 'lastCumulativeFundingRate1e18']], [trader, mid], after_tag)
                row['seedFlag'] = flag(live, '_positionSeeded', (trader, mid), 1, after_tag)
                row['indexFlag'] = flag(live, 'traderMarketIndexPlus1', (trader, mid), 1, after_tag)
                expect(live, NEW, 'getTraderMarketsLength(address)', 1, [trader], after_tag)
                row['traderMarkets'] = expect(live, NEW, 'getTraderMarketsSlice(address,uint256,uint256)', [32, 1, mid], [trader, 0, 1], after_tag)
                row['traderLongExposure'] = expect(live, NEW, 'totalAbsLongSize1e8(address)', max(size, 0), [trader], after_tag)
                row['traderShortExposure'] = expect(live, NEW, 'totalAbsShortSize1e8(address)', max(-size, 0), [trader], after_tag)
                expect(live, NEW, 'getResidualBadDebt(address)', 0, [trader], after_tag)
                oi[0] += max(size, 0); oi[1] += max(-size, 0)
                row['marketReadback'] = expect(live, NEW, 'marketState(uint256)', oi + [0, 1789715546], [1], after_tag)
            expect(live, NEW, 'migrationState()', 0, tag=after_tag)
            expect(live, NEW, 'migrationSnapshotHash()', 0, tag=after_tag)
            expect(live, NEW, 'totalResidualBadDebtBase()', 0, tag=after_tag)
            row.update(state='VERIFIED', event=expected_event, eventName=event_name,
                       gasUsed=int(receipt['gasUsed'], 16), effectiveGasPriceWei=int(receipt['effectiveGasPrice'], 16),
                       l1FeeWei=int(receipt.get('l1Fee', '0x0'), 16))
            journal['successfulPrefix'] = i
            save(journal)
            print('Verified seed', i, 'receipt/event/storage PASS; block', row['block'], 'OI', oi, flush=True)
        journal['status'] = 'EIGHT_SEEDS_VERIFIED_FINAL_RECONCILIATION_PENDING'
        save(journal)
    except BaseException as error:
        journal.update(status='HALTED', errorType=type(error).__name__)
        if ctx is not None:
            try:
                rpc = ctx['live']
                reconciliation = {'confirmedNonce': int(rpc('eth_getTransactionCount', [OWNER, 'latest']), 16),
                                  'pendingNonce': int(rpc('eth_getTransactionCount', [OWNER, 'pending']), 16)}
                if journal['transactions']:
                    last = journal['transactions'][-1]
                    if 'hash' in last:
                        receipt = rpc('eth_getTransactionReceipt', [last['hash']])
                        reconciliation['lastReceiptStatus'] = None if receipt is None else int(receipt['status'], 16)
                    else:
                        latest = int(rpc('eth_getBlockByNumber', ['latest', False])['number'], 16)
                        candidates = []
                        for height in range(last['preblock'], latest+1):
                            for tx in rpc('eth_getBlockByNumber', [hex(height), True])['transactions']:
                                if tx['from'].lower() == OWNER.lower() and int(tx['nonce'], 16) == last['nonce']:
                                    candidates.append({'hash': tx['hash'], 'target': tx['to'], 'inputMatches': tx['input'].lower() == last['calldata'].lower()})
                        reconciliation['candidateTransactions'] = candidates
                journal['haltReconciliation'] = reconciliation
            except Exception:
                journal['haltReconciliation'] = 'Read-only reconciliation unavailable; state remains uncertain'
        if started: save(journal)
        print('HALTED; successful verified prefix:', journal['successfulPrefix'], '; no retry or next send.', flush=True)
        # Exceptions originating from subprocesses can contain command-line credentials.
        raise RuntimeError('M3 halted; inspect sanitized execution journal; underlying output withheld') from None
    finally:
        PASSWORD.unlink(missing_ok=True)
        assert not PASSWORD.exists(), 'Password cleanup failed'
        if started:
            journal['passwordFileAbsent'] = True
            save(journal)
        print('Temporary password file removed; absence verified.', flush=True)


if __name__ == '__main__':
    main()
