#!/usr/bin/env python3
"""Pure type-2 verification plus a fake-transport-only one-shot integration.

No CLI sends transactions. No real wallet or signer is loaded. A later sender
requires separate implementation, review, and explicit authorization.
"""
import json
from pathlib import Path
import subprocess

import first_trade_live_state as state
import restricted_first_trade_guard as guard
from signed_order_resolution import k256

ROOT = Path(__file__).resolve().parents[2]
DECODER = Path(__file__).with_name('verify_type2_raw.cjs')


class RecordingFakeTransport:
    """The only transport accepted by this milestone; never touches a network."""
    def __init__(self, *, timeout=False):
        self.seen = []
        self.timeout = timeout

    def __call__(self, signed_bytes):
        self.seen.append(signed_bytes)
        if self.timeout:
            raise TimeoutError('synthetic ambiguous submission')
        return '0x'+k256(signed_bytes).hex()


def decode_signed_raw(raw):
    """Use mature viem parsing/recovery; never put signed bytes in argv/logs."""
    guard.require(type(raw) is bytes and raw[:1] == b'\x02' and 0 < len(raw) <= 10000,
                  'unsupported signed transaction form')
    proc = subprocess.run(['node', str(DECODER)],
        input=json.dumps({'raw':'0x'+raw.hex()}), text=True,
        capture_output=True, timeout=20, cwd=ROOT.parent/'deopt-v2-frontend')
    guard.require(proc.returncode == 0, 'signed transaction decode/recovery failed')
    try:
        decoded = json.loads(proc.stdout)
    except (ValueError, TypeError):
        raise guard.GuardRejected('malformed signed transaction verifier output') from None
    keys = {'type','chainId','nonce','to','valueWei','data','gasLimit','maxFeePerGas',
            'maxPriorityFeePerGas','accessListLength','from','transactionHash',
            'serializedLengthBytes'}
    guard.require(set(decoded) == keys and decoded['type'] == 'eip1559' and
                  decoded['accessListLength'] == 0 and decoded['serializedLengthBytes'] == len(raw) and
                  decoded['transactionHash'].lower() == '0x'+k256(raw).hex(),
                  'signed transaction verifier mismatch')
    candidate = {'chainId':decoded['chainId'], 'from':decoded['from'], 'to':decoded['to'],
                 'valueWei':int(decoded['valueWei']), 'data':decoded['data'],
                 'nonce':decoded['nonce'], 'gasLimit':int(decoded['gasLimit']),
                 'maxFeePerGas':int(decoded['maxFeePerGas']),
                 'maxPriorityFeePerGas':int(decoded['maxPriorityFeePerGas'])}
    guard.require(candidate['chainId'] == guard.CHAIN and
                  candidate['from'].lower() == guard.EXECUTOR.lower() and
                  candidate['to'].lower() == guard.PME.lower() and
                  candidate['valueWei'] == 0, 'signed transaction sender/target/chain/value drift')
    return candidate, decoded['transactionHash']


def validated_decision(package_bytes, approved_sha256, raw, live):
    candidate, tx_hash = decode_signed_raw(raw)
    approval = json.loads(package_bytes)
    guard.require(guard.approved_hash(package_bytes) == approved_sha256,
                  'approved package hash changed')
    # The guard checks all candidate fields, exact ABI re-encoding, trader
    # signatures, domain, close-only pre-state, deadline, nonce and fees.
    trade = approval['trade']
    guard.require(live['riskEngine'].lower() == guard.ENGINE.lower() and
                  live['migrationSnapshotHash'].lower() == state.SNAPSHOT.lower() and
                  live['marketExists'] and live['marketActive'] and
                  live['maxExecutionDeviationBps'] == 100 and
                  live['riskMaxOracleDelay'] == 600 and
                  live['backendLocalStopped'] is True,
                  'recovery dependency or local backend precondition failed')
    guard.require(live['markPriceStatus'] == 'AVAILABLE' and
                  type(live['markPrice1e8']) is int and live['markPrice1e8'] > 0,
                  'oracle mark unavailable')
    mark = live['markPrice1e8']
    guard.require(abs(trade['executionPrice1e8']-mark)*10000 <= mark*100,
                  'execution price outside approved PMR deviation')
    guard.require(state.readiness(live)['status'] == 'ARMED_FOR_LOCAL_VALIDATION',
                  'LIVE_EXECUTION_NOT_ARMED')
    decision = guard.validate(package_bytes, approved_sha256, candidate, live)
    return decision, candidate, tx_hash


def test_only_one_shot(package_path, approved_sha256, signed_bytes, journal,
                       fake_transport, rpc, *, persist=guard._persist):
    """Recording-fake transport integration. This is not an operational sender.

    The lock is acquired before the final collector call, final package check,
    final guard decision, journal and immutable-byte callback.
    """
    guard.require(type(signed_bytes) is bytes and type(fake_transport) is RecordingFakeTransport,
                  'test transport or immutable transaction missing')
    package_path = Path(package_path)
    package_bytes = package_path.read_bytes()
    guard.require(guard.approved_hash(package_bytes) == approved_sha256,
                  'approved package hash changed')
    initial = state.collect(rpc, raw_size_bytes=len(signed_bytes))
    decision, candidate, tx_hash = validated_decision(package_bytes,approved_sha256,
                                                     signed_bytes,initial)

    def locked_preflight():
        guard.require(package_path.read_bytes() == package_bytes,
                      'approved package file changed before send')
        refreshed = state.collect(rpc, raw_size_bytes=len(signed_bytes))
        guard.require(package_path.read_bytes() == package_bytes,
                      'approved package file changed before send')
        again, candidate_now, hash_now = validated_decision(package_bytes,approved_sha256,
                                                             signed_bytes,refreshed)
        guard.require(candidate_now == candidate and hash_now.lower() == tx_hash.lower(),
                      'signed transaction changed before send')
        return again

    guard.one_shot(decision,journal,signed_bytes,fake_transport,persist=persist,
                   locked_preflight=locked_preflight)
    return {'transactionHash':tx_hash, 'packageSha256':approved_sha256,
            'journalStatus':'SUBMITTED_NOT_CONFIRMED', 'transport':'TEST_FAKE_ONLY'}
