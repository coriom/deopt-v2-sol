#!/usr/bin/env python3
"""Stage B only: one approved V1 maintenance transaction, never a resume of four."""

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

sys.dont_write_bytecode = True
import maintenance_fee_guard as fee_guard
import maintenance_lock_execute as original
import maintenance_lock_preflight as audit
import migration_reseal_preflight as reseal

ROOT = audit.ROOT
PRIOR = audit.OUT
OUT = ROOT / 'artifacts/perps_v2_recovery_maintenance_lock_finish'
OWNER = original.OWNER
V1 = '0xc6C592100723Fe0C66343A16e95eC34cC0c2141c'
PASSWORD = Path('/run/user') / str(os.getuid()) / 'deopt-deployer.pw'
KEYSTORE = Path.home() / '.foundry/keystores/deopt-deployer'


def save(name, value):
    path = OUT / name
    temporary = path.with_name(path.name + '.tmp')
    with temporary.open('w') as file:
        json.dump(value, file, indent=2)
        file.write('\n')
        file.flush()
        os.fsync(file.fileno())
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--execute-reviewed-package', required=True)
    parser.add_argument('--broadcast-one', action='store_true', required=True)
    args = parser.parse_args()
    assert not sys.flags.optimize and args.broadcast_one
    journal = {'milestone': 'PERPS_V2_BASE_SEPOLIA_RECOVERY_MAINTENANCE_LOCK_V1_FINISH',
               'status': 'PRECHECK', 'publicSendInvocations': 0, 'transactions': []}
    try:
        assert not (OUT / 'execution_journal.json').exists(), 'Prior attempt exists; no auto-resume'
        assert not (OUT / 'fee_decision_broadcast.json').exists(), 'Prior fee decision exists; no resend'
        package_path = OUT / 'execution_package.json'
        digest = hashlib.sha256(package_path.read_bytes()).hexdigest()
        stage_a = json.loads((OUT / 'stage_a.json').read_text())
        assert args.execute_reviewed_package == digest == stage_a['continuationPackageSha256']
        assert stage_a['status'].endswith('_READY_TO_BROADCAST') and stage_a['publicWrites'] == 0
        package = json.loads(package_path.read_text())
        old_path = PRIOR / 'execution_package.json'
        assert hashlib.sha256(old_path.read_bytes()).hexdigest() == original.APPROVED
        old_package = json.loads(old_path.read_text())
        old_step = old_package['transactions'][3]
        assert package['originalPackageSha256'] == original.APPROVED and package['originalOrdinal'] == 4
        assert package['chainId'] == 84532 and package['nonce'] == 811 and package['expectedFinalNonce'] == 812
        assert package['sender'].lower() == OWNER.lower() and package['target'].lower() == V1.lower()
        assert package['value'] == 0 and package['calldata'] == old_step['calldata']
        for key in ('function', 'selector', 'decodedArguments', 'pauseFlagsBefore', 'pauseFlagsAfter', 'expectedEvents'):
            assert package[key] == old_step[key]
        assert package['decodedArguments'] == [True]*4 and package['pauseFlagsBefore'] == [0,1,0,0]
        policy = package['feePolicy']
        assert policy['totalPlanningBudgetWei'] == policy['gasLimit'] * policy['maxFeePerGasWei'] + policy['l1AllowanceWei'] + policy['additionalFeeAllowanceWei']
        preflight = json.loads((PRIOR / 'preflight.json').read_text())
        prefix = json.loads((PRIOR / 'execution_journal.json').read_text())
        assert prefix['status'] == 'HALTED' and prefix['publicSendInvocations'] == 3
        assert len(prefix['transactions']) == 3 and all(row['status'] == 'VERIFIED' for row in prefix['transactions'])
        assert not (PRIOR / 'receipt_4.json').exists()
        for name,digest_before in json.loads((PRIOR / 'entry_inventory.json').read_text())['preservedBlockedRebindFiles'].items():
            assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest() == digest_before
        assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip() == stage_a['solHead']
        assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT.parent/'deopt-v2-backend', text=True).strip() == stage_a['backendHead']
        assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT.parent/'deopt-v2-backend', text=True).strip()

        ctx = reseal.prepare_context()
        rpc = ctx['live']
        assert int(rpc('eth_chainId', []), 16) == 84532
        assert ctx['verify_canonical']()[1] == preflight['canonicalFileSha256']
        ctx['checks'] = [(label,address,sig,1 if sig == 'migrationState()' else ctx['SNAPSHOT'],sigargs)
                         if address.lower() == ctx['NEW'].lower() and sig in ('migrationState()','migrationSnapshotHash()')
                         else (label,address,sig,want,sigargs)
                         for label,address,sig,want,sigargs in ctx['checks']]
        previous = json.loads((reseal.OUT / 'postflight.json').read_text())
        before = rpc('eth_getBlockByNumber', ['latest', False]); tag = before['number']
        assert int(before['hash'], 16) != 0
        assert int(rpc('eth_getTransactionCount', [OWNER, 'latest']), 16) == int(rpc('eth_getTransactionCount', [OWNER, 'pending']), 16) == 811
        controls = {name: list(values) for name,values in preflight['controls'].items()}
        for row in prefix['transactions']:
            step = old_package['transactions'][row['ordinal'] - 1]
            receipt = rpc('eth_getTransactionReceipt', [row['hash']])
            tx = rpc('eth_getTransactionByHash', [row['hash']])
            block = rpc('eth_getBlockByNumber', [receipt['blockNumber'], False])
            original.validate_receipt(ctx, receipt, tx, block, row['hash'], step)
            assert receipt['blockHash'] == row['receiptBlockHash']
            controls[row['name']] = step['pauseFlagsAfter']
        original.invariant(ctx, preflight, previous, rpc, tag, controls)
        assert ctx['call'](rpc, ctx['PME1'], 'paused()', tag=tag)[0] == 1
        hashes = [row['hash'] for row in prefix['transactions']]
        assert len(original.scan_unexpected(ctx, rpc, prefix['preBlock']+1, int(tag,16), hashes)) == 11
        assert ctx['call'](rpc, V1, 'owner()', tag=tag)[0] == int(OWNER,16)
        assert rpc('eth_call', [{'from':OWNER,'to':V1,'data':package['calldata'],'value':'0x0'},tag]) == '0x'
        assert hashlib.sha256(package_path.read_bytes()).hexdigest() == args.execute_reviewed_package

        metadata = PASSWORD.lstat(); directory = PASSWORD.parent.stat()
        assert stat.S_ISREG(metadata.st_mode) and stat.S_IMODE(metadata.st_mode) == 0o600
        assert metadata.st_uid == directory.st_uid == os.getuid()
        assert subprocess.check_output(['findmnt','-n','-T',str(PASSWORD),'-o','FSTYPE,TARGET'],text=True).split() == ['tmpfs',str(PASSWORD.parent)]
        environment = os.environ.copy()
        for name in ('ETH_PRIVATE_KEY','PRIVATE_KEY','DEPLOYER_PRIVATE_KEY','ETH_PASSWORD'):
            environment.pop(name, None)
        environment['ETH_RPC_URL'] = ctx['url']
        signer = subprocess.run(['cast','wallet','address','--keystore',str(KEYSTORE),'--password-file',str(PASSWORD)],
                                cwd='/tmp', env=environment, capture_output=True, text=True, timeout=30)
        assert signer.returncode == 0 and signer.stdout.strip().lower() == OWNER.lower(), 'Signer mismatch; output withheld'

        fresh = rpc('eth_getBlockByNumber', ['latest', False]); fresh_tag = fresh['number']
        assert int(fresh_tag,16) - int(tag,16) <= 180, 'Economic comparison stale'
        assert int(rpc('eth_getTransactionCount',[OWNER,'latest']),16) == int(rpc('eth_getTransactionCount',[OWNER,'pending']),16) == 811
        original.invariant(ctx, preflight, previous, rpc, fresh_tag, controls, whole=False)
        assert len(original.scan_unexpected(ctx,rpc,int(tag,16)+1,int(fresh_tag,16),hashes)) == 0
        assert hashlib.sha256(package_path.read_bytes()).hexdigest() == args.execute_reviewed_package

        estimate_tx = {'from':OWNER,'to':V1,'data':package['calldata'],'value':'0x0','gas':hex(500000)}
        try:
            observed_estimate = int(rpc('eth_estimateGas',[estimate_tx,fresh_tag]),16)
        except (AssertionError,RuntimeError,ValueError,TypeError):
            observed_estimate = None
        oracle = '0x420000000000000000000000000000000000000F'
        try:
            quote = ctx['call'](rpc, oracle, 'getL1FeeUpperBound(uint256)', [policy['oracleUnsignedTxSizeBytes']], fresh_tag)[0]
        except (AssertionError,RuntimeError,ValueError,IndexError):
            quote = None
        try:
            additional_quote = ctx['call'](rpc, oracle, 'getOperatorFee(uint256)', [policy['gasLimit']], fresh_tag)[0]
        except (AssertionError,RuntimeError,ValueError,IndexError):
            additional_quote = None
        balance = int(rpc('eth_getBalance',[OWNER,fresh_tag]),16)
        max_priority = int(rpc('eth_maxPriorityFeePerGas',[]),16)
        gas_price = int(rpc('eth_gasPrice',[]),16)
        observation = {'number': int(fresh_tag,16), 'hash':fresh['hash'], 'timestamp':int(fresh['timestamp'],16)}
        journal.update(status='APPROVED_PRE_SEND_GATES_PASS', packageSha256=args.execute_reviewed_package,
                       comparisonBlock=int(tag,16), ownerNonceBefore=811, ownerBalanceBeforeWei=balance)
        save('execution_journal.json', journal)

        def send_once():
            assert journal['publicSendInvocations'] == 0
            assert hashlib.sha256(package_path.read_bytes()).hexdigest() == args.execute_reviewed_package
            record = {'ordinal':4,'nonce':811,'target':V1,'calldata':package['calldata'],
                      'status':'SUBMITTING','submissionAttempts':1}
            journal['transactions'].append(record)
            journal['publicSendInvocations'] = 1
            journal['status'] = 'SUBMITTING'
            save('execution_journal.json', journal)
            command = ['cast','send',V1,package['calldata'],'--async','-j','1','--from',OWNER,
                       '--value','0','--nonce','811','--chain','84532',
                       '--gas-limit',str(policy['gasLimit']),
                       '--gas-price',str(policy['maxFeePerGasWei']),
                       '--priority-gas-price',str(policy['maxPriorityFeePerGasWei']),
                       '--keystore',str(KEYSTORE),'--password-file',str(PASSWORD)]
            try:
                result = subprocess.run(command,cwd='/tmp',env=environment,capture_output=True,text=True,timeout=90)
            except subprocess.TimeoutExpired:
                record['status'] = 'SUBMISSION_TIMEOUT_UNKNOWN'
                save('execution_journal.json',journal)
                raise RuntimeError('Submission timeout; reconcile nonce/receipt, no retry') from None
            output = result.stdout.strip().strip('"')
            if re.fullmatch(r'0x[0-9a-fA-F]{64}', output):
                record['hash'] = output
                record['status'] = 'SUBMITTED'
                save('execution_journal.json',journal)
            if result.returncode != 0 or 'hash' not in record:
                record['status'] = 'SUBMISSION_AMBIGUOUS'
                save('execution_journal.json',journal)
                raise RuntimeError('Submission ambiguous; no retry')
            return record['hash']

        tx_hash = fee_guard.guarded_send(path=OUT/'fee_decision_broadcast.json',
            block=observation, quote=quote, additional_fee_quote_wei=additional_quote,
            observed_base_fee_wei=int(fresh['baseFeePerGas'],16),
            observed_priority_fee_wei=max_priority, observed_gas_price_wei=gas_price,
            observed_gas_estimate=observed_estimate,
            policy=policy, balance_wei=balance, send=send_once)
        print('Submitted sole continuation transaction',tx_hash,flush=True)
        deadline = time.monotonic() + 300
        record = journal['transactions'][0]
        approved_step = {**package, **policy}
        while time.monotonic() < deadline:
            receipt = rpc('eth_getTransactionReceipt',[tx_hash])
            if receipt is None or int(receipt.get('blockHash','0x0'),16) == 0:
                time.sleep(2); continue
            assert int(receipt['status'],16) == 1
            tx = rpc('eth_getTransactionByHash',[tx_hash])
            block = rpc('eth_getBlockByNumber',[receipt['blockNumber'],False])
            original.validate_receipt(ctx,receipt,tx,block,tx_hash,approved_step)
            head = rpc('eth_getBlockByNumber',['latest',False])
            if int(head['number'],16) < int(receipt['blockNumber'],16)+2:
                time.sleep(2);continue
            record.update(status='VERIFIED',receiptBlock=int(receipt['blockNumber'],16),
                          receiptBlockHash=receipt['blockHash'],gasUsed=int(receipt['gasUsed'],16),
                          eventCount=len(receipt['logs']))
            save('execution_journal.json',journal)
            save('receipt.json',receipt)
            break
        else:
            raise RuntimeError('Canonical receipt timeout; no retry')
        complete = {name:[1]*len(flags) for name,flags in controls.items()}
        final = rpc('eth_getBlockByNumber',['latest',False]); final_tag = final['number']
        original.invariant(ctx,preflight,previous,rpc,final_tag,complete)
        assert ctx['call'](rpc,ctx['PME1'],'paused()',tag=final_tag)[0] == 1
        assert int(rpc('eth_getTransactionCount',[OWNER,'latest']),16) == int(rpc('eth_getTransactionCount',[OWNER,'pending']),16) == 812
        assert len(original.scan_unexpected(ctx,rpc,prefix['preBlock']+1,int(final_tag,16),hashes+[tx_hash])) == 15
        probes = original.maintenance_probes(ctx)
        assert len(probes) == 15
        assert journal['publicSendInvocations'] == 1
        assert hashlib.sha256(package_path.read_bytes()).hexdigest() == args.execute_reviewed_package
        assert int(rpc('eth_getTransactionCount',[ctx['EXECUTOR'],final_tag]),16) == preflight['executorNonce']
        assert ctx['call'](rpc,ctx['SAFE'],'nonce()',tag=final_tag)[0] == preflight['safeNonce']
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            settled = rpc('eth_getTransactionReceipt',[tx_hash])
            assert settled['blockHash'] == record['receiptBlockHash']
            execution_fee = int(settled['gasUsed'],16)*int(settled['effectiveGasPrice'],16)
            l1_fee = int(settled.get('l1Fee','0x0'),16)
            spent = balance-int(rpc('eth_getBalance',[OWNER,'latest']),16)
            if spent == execution_fee+l1_fee:
                break
            time.sleep(3)
        else:
            raise RuntimeError('Settled fee/balance mismatch; preserve receipt and stop')
        result = {'status':'PERPS_V2_BASE_SEPOLIA_RECOVERY_MAINTENANCE_LOCK_V1_COMPLETE',
                  'chainId':84532,'continuationPackageSha256':args.execute_reviewed_package,
                  'comparisonBlock':int(final_tag,16),'comparisonBlockHash':final['hash'],
                  'transactionHash':tx_hash,'receiptBlock':record['receiptBlock'],
                  'receiptBlockHash':record['receiptBlockHash'],'receiptStatus':1,
                  'ownerNonceBefore':811,'ownerNonceAfter':812,
                  'feeDecisionFile':'fee_decision_broadcast.json',
                  'ownerExpenditureWei':spent,'executionFeeWei':execution_fee,'l1FeeWei':l1_fee,
                  'controls':complete,'economicChecks':114,'exactNegativeProbes':len(probes),
                  'scopedEvents':15,'newPublicSendInvocations':1,'combinedMaintenanceWrites':4,
                  'backendRuntimeState':'STOPPED','signedOrderInventory':'UNRESOLVED',
                  'insuranceGovernance':'UNRESOLVED'}
        save('postflight.json',result)
        journal['status'] = 'COMPLETE'
        save('execution_journal.json',journal)
        print(json.dumps(result,indent=2),flush=True)
    except BaseException as error:
        if (OUT/'execution_journal.json').exists():
            journal['status'] = 'HALTED'
            journal['haltReason'] = str(error)[:250]
            save('execution_journal.json',journal)
        raise
    finally:
        PASSWORD.unlink(missing_ok=True)
        assert not PASSWORD.exists(), 'Temporary password file remains'


if __name__ == '__main__':
    main()
