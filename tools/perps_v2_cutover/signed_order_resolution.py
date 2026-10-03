#!/usr/bin/env python3
"""Bounded read-only resolution of persisted bilateral V2 PerpTrade signatures.

Signature bytes stay in process memory: never write or print them, and never
send them to RPC. Database session is forced read-only by governance_inventory.
"""
import datetime as dt
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
from Crypto.Hash import keccak
import governance_inventory as inventory
import migration_reseal_preflight as migration
import maintenance_lock_preflight as maintenance

ROOT = migration.ROOT
OUT = ROOT / 'artifacts/perps_v2_signed_order_resolution'
KNOWN_FIVE = (
    '5f98818a-4db8-444c-a417-8056cf3279db',
    'c1ddbbac-3066-4f31-9e2a-e0bf6b5a3a1b',
    '3b98f01a-7936-4522-a82e-4e98d158a069',
    '870d04b6-8e98-4ef3-bcbb-9ed407361a38',
    'e93faa83-ade8-4749-a130-5024a6c98314',
)
PME = '0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2'
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
     0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)
DOMAIN_TYPE = 'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'
TRADE_TYPE = ('PerpTrade(bytes32 intentId,address buyer,address seller,uint256 marketId,'
              'uint128 sizeDelta1e8,uint128 executionPrice1e8,uint128 maxExecutionPrice1e8,'
              'uint128 minExecutionPrice1e8,bool buyerIsMaker,uint256 buyerNonce,'
              'uint256 sellerNonce,uint256 deadline)')


def k256(data):
    h = keccak.new(digest_bits=256)
    h.update(data)
    return h.digest()


def word(value):
    assert isinstance(value, int) and 0 <= value < 2**256
    return value.to_bytes(32, 'big')


def addr(value):
    assert isinstance(value, str) and value.startswith('0x') and len(value) == 42
    return word(int(value, 16))


def domain(chain_id=84532, contract=PME):
    return k256(b''.join((k256(DOMAIN_TYPE.encode()),
                          k256(b'DeOptV2-PerpMatchingEngine'), k256(b'2'),
                          word(chain_id), addr(contract))))


def payload(row):
    required = ('intent_id', 'buyer', 'seller', 'market_id', 'size_1e8',
                'price_1e8', 'max_execution_price_1e8', 'min_execution_price_1e8',
                'buyer_is_maker', 'buyer_nonce', 'seller_nonce', 'deadline_ms')
    if any(row.get(k) is None for k in required):
        raise ValueError('UNRESOLVED_PAYLOAD: missing required field')
    deadline_ms = int(row['deadline_ms'])
    if deadline_ms < 0 or deadline_ms % 1000:
        raise ValueError('UNRESOLVED_PAYLOAD: deadline not exact whole seconds')
    maker = row['buyer_is_maker']
    if not isinstance(maker, bool):
        raise ValueError('UNRESOLVED_PAYLOAD: invalid maker flag')
    values = (k256(row['intent_id'].encode()), addr(row['buyer']), addr(row['seller']),
              word(int(row['market_id'])), word(int(row['size_1e8'])),
              word(int(row['price_1e8'])), word(int(row['max_execution_price_1e8'])),
              word(int(row['min_execution_price_1e8'])), word(int(maker)),
              word(int(row['buyer_nonce'])), word(int(row['seller_nonce'])),
              word(deadline_ms // 1000))
    return {'words': values, 'deadline': deadline_ms // 1000}


def trade_digest(row, domain_separator):
    struct_hash = k256(k256(TRADE_TYPE.encode()) + b''.join(payload(row)['words']))
    return k256(b'\x19\x01' + domain_separator + struct_hash)


def deadline_expired(deadline_seconds, chain_timestamp):
    # Bilateral PerpTrade permits zero (no expiry); equality is still valid.
    return deadline_seconds != 0 and chain_timestamp > deadline_seconds


def nonce_relation(signed, live):
    return 'MATCH' if signed == live else 'PAST' if signed < live else 'FUTURE'


def add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0] and (a[1] + b[1]) % P == 0:
        return None
    if a == b:
        slope = (3*a[0]*a[0]) * pow(2*a[1], -1, P) % P
    else:
        slope = (b[1]-a[1]) * pow((b[0]-a[0]) % P, -1, P) % P
    x = (slope*slope-a[0]-b[0]) % P
    return (x, (slope*(a[0]-x)-a[1]) % P)


def mul(k, point):
    acc = None
    while k:
        if k & 1:
            acc = add(acc, point)
        point = add(point, point)
        k >>= 1
    return acc


def recover(digest, signature):
    """Match OZ ECDSA.tryRecover for canonical 65-byte, low-s Ethereum sigs."""
    if not isinstance(signature, str) or len(signature) != 132 or not signature.startswith('0x'):
        return None
    try:
        raw = bytes.fromhex(signature[2:])
    except ValueError:
        return None
    r, s, v = int.from_bytes(raw[:32], 'big'), int.from_bytes(raw[32:64], 'big'), raw[64]
    if not (1 <= r < N and 1 <= s <= N//2 and v in (27, 28)):
        return None
    x = r
    y2 = (pow(x, 3, P) + 7) % P
    y = pow(y2, (P+1)//4, P)
    if y*y % P != y2:
        return None
    if y % 2 != v-27:
        y = P-y
    point = (x, y)
    if mul(N, point) is not None:
        return None
    z = int.from_bytes(digest, 'big') % N
    inv = pow(r, -1, N)
    q = add(mul((s*inv) % N, point), mul((-z*inv) % N, G))
    if q is None:
        return None
    public = q[0].to_bytes(32, 'big') + q[1].to_bytes(32, 'big')
    return '0x' + k256(public)[-20:].hex()


def fetch_rows():
    env = inventory.connection_env()
    sql = ("SELECT row_to_json(q) FROM (SELECT i.intent_id,i.protocol_version,i.status,"
           "i.market_id,i.buyer,i.seller,i.price_1e8,i.size_1e8,i.buyer_is_maker,"
           "i.buyer_nonce,i.seller_nonce,i.deadline_ms,i.max_execution_price_1e8,"
           "i.min_execution_price_1e8,s.buyer_sig,s.seller_sig "
           "FROM execution_intents i LEFT JOIN execution_intent_signatures s "
           "ON s.intent_id=i.intent_id WHERE i.protocol_version='perp_v2' "
           "ORDER BY i.intent_id LIMIT 30) q")
    rows = [json.loads(parts[0]) for parts in inventory.select(env, sql)]
    assert len(rows) < 30, 'Query limit reached; bounded inventory incomplete'
    broadcasts = inventory.select(env, "SELECT intent_id,target_address,status FROM "
                                  "execution_intent_broadcasts WHERE protocol_version='perp_v2' "
                                  "ORDER BY intent_id LIMIT 30")
    assert len(broadcasts) < 30
    extra = {}
    for table in ('orders', 'perps_signed_intent_nonce_ledger', 'perps_intent_fills_ledger'):
        extra[table] = int(inventory.select(env, f'SELECT count(*) FROM {table}')[0][0])
    return rows, {x[0]: {'target': x[1], 'status': x[2]} for x in broadcasts}, extra


def crosscheck_recovery(cases):
    """Independent viem recovery, with signatures passed only on stdin."""
    js = ("const fs=require('fs'),v=require('viem');"
          "(async()=>{const a=JSON.parse(fs.readFileSync(0,'utf8'));const out=[];"
          "for(const x of a){try{out.push((await v.recoverAddress({hash:x.hash,"
          "signature:x.sig})).toLowerCase())}catch{out.push(null)}}"
          "process.stdout.write(JSON.stringify(out))})().catch(()=>process.exit(1))")
    proc = subprocess.run(['node', '-e', js], cwd=ROOT.parent/'deopt-v2-frontend',
                          input=json.dumps(cases), capture_output=True, text=True,
                          timeout=30, check=True)
    other = json.loads(proc.stdout)
    assert len(other) == len(cases)
    assert other == [recover(bytes.fromhex(x['hash'][2:]), x['sig']) for x in cases], \
        'Independent ECDSA recovery disagreement'
    return len(other)


def main():
    assert not sys.flags.optimize
    ctx = migration.prepare_context()
    rpc, call = ctx['live'], ctx['call']
    assert int(rpc('eth_chainId', []), 16) == 84532
    block = rpc('eth_getBlockByNumber', ['latest', False])
    tag = block['number']
    timestamp = int(block['timestamp'], 16)
    assert int(block['hash'], 16) != 0
    assert ctx['PME'].lower() == PME.lower()
    runtime = bytes.fromhex(rpc('eth_getCode', [PME, tag])[2:])
    assert len(runtime) == 10441, 'Live PME runtime size drift'
    live_domain = call(rpc, PME, 'domainSeparatorV4()', tag=tag)[0]
    assert live_domain == int.from_bytes(domain(), 'big'), 'Live EIP-712 domain differs'
    rows, broadcasts, extra_counts = fetch_rows()
    assert len(rows) == 14 and len(broadcasts) == 11, 'Known store count drift'
    by_id = {x['intent_id']: x for x in rows}
    assert set(KNOWN_FIVE) <= set(by_id)
    ordered = [by_id[x] for x in KNOWN_FIVE] + [x for x in rows if x['intent_id'] not in KNOWN_FIVE]
    recorded_targets = sorted({x['target'].lower() for x in broadcasts.values()})
    out = []
    recovery_cases = []
    for row in ordered:
        record = {'intentId': row['intent_id'], 'messageType': 'bilateral PerpTrade',
                  'entrypoint': 'executeTrade(PerpTrade,bytes,bytes)',
                  'protocolVersion': row['protocol_version'], 'lifecycle': row['status'],
                  'broadcastTargetRecorded': row['intent_id'] in broadcasts,
                  'provenance': 'UNPROVEN', 'subaccountAndPartialFillFields': 'NOT_APPLICABLE'}
        if row['intent_id'] in broadcasts:
            record['recordedHistoricalTarget'] = broadcasts[row['intent_id']]['target']
        try:
            trade = payload(row)
            assert all(0 <= int(row[k]) < 2**128 for k in ('size_1e8', 'price_1e8',
                          'max_execution_price_1e8', 'min_execution_price_1e8'))
            record['payloadComplete'] = True
            record['reconstructedPayload'] = {
                'intentIdBytes32': '0x'+trade['words'][0].hex(),
                'buyer': row['buyer'], 'seller': row['seller'],
                'marketId': int(row['market_id']),
                'sizeDelta1e8': int(row['size_1e8']),
                'executionPrice1e8': int(row['price_1e8']),
                'maxExecutionPrice1e8': int(row['max_execution_price_1e8']),
                'minExecutionPrice1e8': int(row['min_execution_price_1e8']),
                'buyerIsMaker': row['buyer_is_maker'],
                'buyerNonce': int(row['buyer_nonce']),
                'sellerNonce': int(row['seller_nonce']),
                'deadline': trade['deadline'],
            }
            record['reconstructedDeadlineSeconds'] = trade['deadline']
            record['reconstructedDeadlineUTC'] = dt.datetime.fromtimestamp(trade['deadline'], dt.timezone.utc).isoformat()
            record['reconstructedDeadlineExpired'] = deadline_expired(trade['deadline'], timestamp)
            digest = trade_digest(row, domain())
        except (ValueError, AssertionError, OverflowError) as exc:
            record.update(payloadComplete=False, verdict='UNRESOLVED_PAYLOAD', reason=str(exc))
            out.append(record)
            continue
        checks = {}
        for role in ('buyer', 'seller'):
            signer = recover(digest, row[role+'_sig']) if row[role+'_sig'] else None
            if row[role+'_sig']:
                recovery_cases.append({'hash': '0x'+digest.hex(), 'sig': row[role+'_sig']})
            declared = row[role].lower()
            checks[role] = ('MISSING' if not row[role+'_sig'] else
                            'VALID_LIVE_DOMAIN' if signer == declared else 'INVALID_LIVE_DOMAIN_OR_PAYLOAD')
        record['signatureChecks'] = checks
        record['signaturePairPresent'] = bool(row['buyer_sig'] and row['seller_sig'])
        record['fillAssessment'] = 'NOT_APPLICABLE_BILATERAL_PERP_TRADE'
        record['storedLivePayloadSignatureValid'] = all(v == 'VALID_LIVE_DOMAIN' for v in checks.values())
        historical_valid = False
        if record['signaturePairPresent'] and row['intent_id'] in broadcasts:
            historical_digest = trade_digest(row, domain(contract=broadcasts[row['intent_id']]['target']))
            historical_valid = all(recover(historical_digest, row[role+'_sig']) == row[role].lower()
                                   for role in ('buyer', 'seller'))
        record['recordedHistoricalTargetSignatureValid'] = historical_valid
        if historical_valid:
            record['provenance'] = 'SIGNED_PAYLOAD_VERIFIED_FOR_RECORDED_HISTORICAL_TARGET'
            record['verifiedSignedDeadlineSeconds'] = trade['deadline']
        elif record['signaturePairPresent'] and row['intent_id'] not in broadcasts:
            # Bounded provenance hypothesis only: never claim this proves
            # the signatures invalid for an unknown original target/payload.
            record['recordedTargetCandidatePairMatches'] = sum(
                all(recover(trade_digest(row, domain(contract=target)), row[role+'_sig'])
                    == row[role].lower() for role in ('buyer', 'seller'))
                for target in recorded_targets)
        nonce_state = {}
        for role in ('buyer', 'seller'):
            live_nonce = call(rpc, PME, 'nonces(address)', [row[role]], tag)[0]
            signed_nonce = int(row[role+'_nonce'])
            nonce_state[role] = {'signed': signed_nonce, 'live': live_nonce,
                                 'relation': nonce_relation(signed_nonce, live_nonce)}
        record['nonces'] = nonce_state
        record['verdict'] = ('MISSING_SIGNATURE' if not record['signaturePairPresent'] else
                             'EXPIRED_VERIFIED_SIGNED_DEADLINE' if historical_valid and record['reconstructedDeadlineExpired'] else
                             'UNRESOLVED_ORIGINAL_SIGNED_PAYLOAD' if not historical_valid and not record['storedLivePayloadSignatureValid'] else
                             'POTENTIALLY_EXECUTABLE')
        out.append(record)
    assert len(out) == len(rows)
    assert all(x['verdict'] in ('EXPIRED_VERIFIED_SIGNED_DEADLINE',
                               'UNRESOLVED_ORIGINAL_SIGNED_PAYLOAD', 'MISSING_SIGNATURE') for x in out)
    assert all(x['payloadComplete'] for x in out)
    assert sum(x['signaturePairPresent'] for x in out) == 13
    assert all(x['reconstructedDeadlineExpired'] for x in out)
    assert sum(x['verdict']=='EXPIRED_VERIFIED_SIGNED_DEADLINE' for x in out) == 8
    assert {x['intentId'] for x in out if x['verdict']=='UNRESOLVED_ORIGINAL_SIGNED_PAYLOAD'} == set(KNOWN_FIVE)
    independent_checks = crosscheck_recovery(recovery_cases)
    # Refresh only the rollout safety boundary, not the full migration audit.
    assert call(rpc, PME, 'paused()', tag=tag) == [1]
    assert call(rpc, ctx['PME1'], 'paused()', tag=tag) == [1]
    controls = {name: [call(rpc, ctx[name], sig, tag=tag)[0] for sig in maintenance.FLAGS]
                for name in ('NEW', 'OLD', 'V1')}
    assert all(v == [1, 1, 1, 1] for v in controls.values())
    for name in ('NEW', 'OLD'):
        assert call(rpc, ctx[name], 'migrationSnapshotHash()', tag=tag)[0] == int(ctx['SNAPSHOT'], 16)
    assert call(rpc, PME, 'perpEngine()', tag=tag) == [int(ctx['OLD'], 16)]
    assert call(rpc, ctx['RISK'], 'perpEngine()', tag=tag) == [int(ctx['OLD'], 16)]
    ids = ('0x824bc77bb68ff4878d2e477478ed4d120abab89ce27b181a7c8ecc5ba7cfa3f6',
           '0x02705011c0ee36d4928843bfb5641ff90aebf658162735668774768a7bc3e846')
    assert all(call(rpc, maintenance.TIMELOCK, 'queuedTransactions(bytes32)', [op], tag) == [1]
               for op in ids)
    assert call(rpc, ctx['VAULT'], 'isAuthorizedEngine(address)', [ctx['NEW']], tag) == [0]
    assert call(rpc, ctx['deps']['insuranceFund()'], 'isBackstopCaller(address)', [ctx['NEW']], tag) == [0]
    assert ctx['backend_stopped']()['backend_runtime_state'] == 'STOPPED'
    assert call(rpc, ctx['VAULT'], 'balances(address,address)',
                [ctx['deps']['clearingAccount()'], ctx['TOKEN']], tag) == [1000000000]
    assert call(rpc, ctx['deps']['feesManagerV2()'], 'isFeeConsumer(address)', [ctx['NEW']], tag) == [0]
    baseline = json.loads((migration.OUT/'postflight.json').read_text())['pmeV2Nonces']
    assert all(call(rpc, PME, 'nonces(address)', [trader], tag)[0] == expected
               for trader, expected in baseline.items())
    executor_allowlist = {
        'owner': bool(call(rpc, PME, 'isExecutor(address)', [ctx['OWNER']], tag)[0]),
        'runtimeExecutor': bool(call(rpc, PME, 'isExecutor(address)',
                                     ['0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8'], tag)[0]),
    }
    start = 47614195
    scoped_logs = []
    for lo in range(start, int(tag, 16)+1, 2000):
        scoped_logs.extend(rpc('eth_getLogs', [{'address': [PME, ctx['RISK'], ctx['NEW'], ctx['OLD'], ctx['V1']],
                                               'fromBlock': hex(lo),
                                               'toBlock': hex(min(lo+1999, int(tag, 16)))}]))
    assert not scoped_logs, 'Unexpected protocol event since G1/G2 queue postflight'
    report = {'milestone': 'PERPS_V2_BASE_SEPOLIA_SIGNED_ORDER_RESOLUTION_V1',
              'chainId': 84532, 'comparisonBlock': int(tag, 16), 'comparisonBlockHash': block['hash'],
              'comparisonTimestamp': timestamp,
              'comparisonUTC': dt.datetime.fromtimestamp(timestamp, dt.timezone.utc).isoformat(),
              'liveDomainSeparatorMatchesLocal': True, 'reusedPme': PME,
              'livePmeRuntimeBytes': len(runtime), 'livePmeRuntimeEthereumKeccak': '0x'+k256(runtime).hex(),
              'storeScope': 'One existing loopback PostgreSQL database from prepare-only config; bounded V2 execution_intents, signatures and broadcasts tables',
              'intents': out, 'intentCount': len(out), 'signedPairCount': 13,
              'independentViemRecoveryChecks': independent_checks,
              'broadcastCount': len(broadcasts), 'recordedHistoricalTargetsTested': len(recorded_targets),
              'otherIdentifiedLocalStoreRowCounts': extra_counts,
              'fivePreviouslyUnresolvedCovered': True,
              'maintenanceControls': controls, 'G1Queued': True, 'G2Queued': True,
              'newInsuranceAuthorization': False, 'newVaultAuthorization': False,
              'newFeeConsumerAuthorization': False, 'clearingBalanceNative': 1000000000,
              'canonicalTraderNoncesUnchanged': True, 'executorAllowlist': executor_allowlist,
              'scopedProtocolEventScan': {'fromBlock': start, 'toBlock': int(tag,16), 'eventCount': 0},
              'backendLocalRuntime': 'STOPPED', 'databaseWrites': 0,
              'publicChainWrites': 0, 'signatureBytesPersisted': False,
              'KNOWN_RECORDS': 'PARTIALLY_RESOLVED', 'STORE_COVERAGE': 'INCOMPLETE',
              'PRE_UNPAUSE_ACTION': 'SPECIFIC_ACTION_REQUIRED', 'TRADING': 'NOT AUTHORIZED'}
    OUT.mkdir(exist_ok=True)
    (OUT/'evidence.json').write_text(json.dumps(report, indent=2, sort_keys=True)+'\n')
    print(json.dumps({'block': report['comparisonBlock'], 'intents': len(out),
                      'signedPairs': 13, 'broadcasts': len(broadcasts),
                      'verifiedExpired': sum(x['verdict']=='EXPIRED_VERIFIED_SIGNED_DEADLINE' for x in out),
                      'unknownOriginalPayload': sum(x['verdict']=='UNRESOLVED_ORIGINAL_SIGNED_PAYLOAD' for x in out),
                      'knownRecords': report['KNOWN_RECORDS'], 'storeCoverage': report['STORE_COVERAGE']}))


if __name__ == '__main__':
    main()
