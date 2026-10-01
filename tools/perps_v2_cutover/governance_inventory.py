#!/usr/bin/env python3
"""Bounded read-only inventory of the known local DeOpt database.

Never selects signature bytes, raw transactions, credentials, or payloads.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.parse

sys.dont_write_bytecode = True
import migration_reseal_preflight as migration

ROOT = migration.ROOT
OUT = ROOT / 'artifacts/perps_v2_recovery_governance_prepare'
BACKEND = ROOT.parent / 'deopt-v2-backend'
CONFIG = BACKEND / '.env.perps_closed_test_prepare_only.local'


def connection_env():
    line = next(x for x in CONFIG.read_text().splitlines() if x.startswith('DATABASE_URL='))
    url = urllib.parse.urlsplit(line.split('=',1)[1].strip().strip('"\''))
    assert url.scheme in ('postgres','postgresql') and url.hostname in ('127.0.0.1','localhost')
    env = {**os.environ,
        'PGHOST':url.hostname,'PGPORT':str(url.port or 5432),
        'PGUSER':urllib.parse.unquote(url.username or ''),
        'PGPASSWORD':urllib.parse.unquote(url.password or ''),
        'PGDATABASE':url.path.removeprefix('/'),
        'PGOPTIONS':'-c default_transaction_read_only=on -c statement_timeout=5000 -c lock_timeout=1000',
        'PGCONNECT_TIMEOUT':'5'}
    return env


def select(env, sql):
    assert sql.startswith('SELECT ') and ';' not in sql
    result = subprocess.run(['psql','-X','-w','-At','-F','|','-c',sql], env=env,
                            capture_output=True,text=True,timeout=10)
    if result.returncode:
        raise RuntimeError('Read-only database query failed; details withheld')
    return [row.split('|') for row in result.stdout.splitlines()]


def main():
    assert not sys.flags.optimize
    env = connection_env()
    ctx = migration.prepare_context()
    rpc=ctx['live']; assert int(rpc('eth_chainId',[]),16)==84532
    configured = {line.split('=',1)[0]:line.split('=',1)[1].strip().strip('"\'')
                  for line in CONFIG.read_text().splitlines() if '=' in line and not line.lstrip().startswith('#')}
    assert configured.get('CHAIN_ID')=='84532' and configured.get('EXECUTOR_CHAIN_ID')=='84532'
    config_pme = configured.get('PERP_MATCHING_ENGINE_ADDRESS','').lower()
    config_pme_class='V1' if config_pme=='0x774d96e5739bffadee91508b4d3d74f5be29f165' else (
        'REUSED_PME_V2' if config_pme==ctx['PME'].lower() else 'OTHER_OR_UNSET')
    intents=select(env,"SELECT i.intent_id,i.status,i.buyer,i.seller,i.buyer_nonce,i.seller_nonce,i.deadline_ms,"
        "(s.buyer_sig IS NOT NULL AND s.buyer_sig <> '')::int,(s.seller_sig IS NOT NULL AND s.seller_sig <> '')::int,"
        "i.created_at_ms FROM execution_intents i LEFT JOIN execution_intent_signatures s ON s.intent_id=i.intent_id "
        "WHERE i.protocol_version='perp_v2' ORDER BY i.created_at_ms,i.intent_id LIMIT 30")
    broadcasts=select(env,"SELECT b.intent_id,b.chain_id,b.protocol_version,b.status,b.target_address,"
        "b.expected_emitter,b.nonce,b.receipt_block_number,b.receipt_status,b.tx_hash "
        "FROM execution_intent_broadcasts b WHERE b.protocol_version='perp_v2' ORDER BY b.intent_id LIMIT 30")
    assert len(intents)==14 and len(broadcasts)==11, 'Inventory changed; review query scope'
    rows=[]
    for v in intents:
        rows.append(dict(zip(('intentId','lifecycle','buyer','seller','buyerNonce','sellerNonce',
                              'deadlineMs','buyerSignaturePresent','sellerSignaturePresent','createdAtMs'),v)))
    claimed=[]
    for v in broadcasts:
        row=dict(zip(('intentId','chainId','protocolVersion','status','target','expectedEmitter',
                      'nonce','claimedReceiptBlock','claimedReceiptStatus','claimedTxHash'),v))
        h=row['claimedTxHash']; target=row['target']
        row['baseSepoliaReceiptPresent']=bool(rpc('eth_getTransactionReceipt',[h])) if h else False
        row['baseSepoliaTransactionPresent']=bool(rpc('eth_getTransactionByHash',[h])) if h else False
        row['baseSepoliaTargetCodePresent']=rpc('eth_getCode',[target,'latest'])!='0x'
        row['targetsReusedPME']=target.lower()==ctx['PME'].lower()
        claimed.append(row)
    assert all(not x['baseSepoliaReceiptPresent'] and not x['baseSepoliaTransactionPresent']
               and not x['baseSepoliaTargetCodePresent'] and not x['targetsReusedPME'] for x in claimed)
    v1_hash='0xa6a6bb44b7dc71f77b86989933af4088f8685bbff178721e52d64c60119508e4'
    v1_receipt=rpc('eth_getTransactionReceipt',[v1_hash])
    assert v1_receipt and int(v1_receipt['blockNumber'],16)==46973629
    result={'scope':'One reachable loopback database from prepare-only local config; no other stores or backups inferred',
        'configFile':str(CONFIG.relative_to(BACKEND)),
        'configuredMatchingEngineClass':config_pme_class,
        'configuredRealBroadcastEnabled':configured.get('EXECUTOR_REAL_BROADCAST_ENABLED'),
        'v2IntentCount':len(rows),'v2SignedPairCount':sum(x['buyerSignaturePresent']=='1' and x['sellerSignaturePresent']=='1' for x in rows),
        'v2Intents':rows,'v2Broadcasts':claimed,
        'v1ConfirmedRealBaseSepoliaReceipt':{'txHash':v1_hash,'block':46973629,'status':int(v1_receipt['status'],16)},
        'v2BroadcastClaimedHashReceiptMatches':0,
        'fixtureEvidence':'Three prepared V2 targets equal the PME_V2_ADDR test constant in backend tests; all 11 claimed V2 hash/target pairs have no Base Sepolia receipt/transaction/code.',
        'limitations':['No verifyingContract or chainId field on execution_intents or execution_intent_signatures',
                       'Five V2 signature-bearing intents have no broadcast target; their provenance is not proven',
                       'This database includes one real V1 receipt but does not prove completeness of all stores',
                       'Signature bytes and raw transactions were never selected'],
        'databaseWrites':0,'signaturesPrinted':False,'verdict':'UNRESOLVED'}
    OUT.mkdir(exist_ok=True)
    (OUT/'signed_order_inventory.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    print(json.dumps({'databaseReachable':True,'v2Intents':len(rows),
          'v2SignedPairs':result['v2SignedPairCount'],'v2Broadcasts':len(claimed),
          'v2ReceiptMatches':0,'v1RealReceipt':True,'verdict':'UNRESOLVED'}))


if __name__=='__main__':
    main()
