#!/usr/bin/env python3
"""Validation-only guard for a separately approved, single V2 close.

No wallet, signer, RPC send, database write, or automatic unpause exists here.
The callback journal is an integration primitive; this module supplies no
production send callback. Never log calldata or signature bytes.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import time

from signed_order_resolution import TRADE_TYPE, domain, k256, recover, word

CHAIN = 84532
PME = '0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2'
ENGINE = '0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15'
ENGINE_HASH = '0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a'
EXECUTOR = '0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8'
BUYER = '0x66858286fEEA78a05eA093673EA1535E0A52002d'
SELLER = '0xff287410852B9328437eaC353720e5476bC5F837'
TRADE_SIGNATURE = ('executeTrade((bytes32,address,address,uint256,uint128,uint128,uint128,uint128,'
                   'bool,uint256,uint256,uint256),bytes,bytes)')
SELECTOR = k256(TRADE_SIGNATURE.encode())[:4]
WORD_KEYS = ('intentId', 'buyer', 'seller', 'marketId', 'sizeDelta1e8',
             'executionPrice1e8', 'maxExecutionPrice1e8', 'minExecutionPrice1e8',
             'buyerIsMaker', 'buyerNonce', 'sellerNonce', 'deadline')
UINT128_KEYS = ('sizeDelta1e8', 'executionPrice1e8', 'maxExecutionPrice1e8', 'minExecutionPrice1e8')
PACKAGE_KEYS = frozenset(('schema', 'chainId', 'pme', 'engine', 'engineRuntimeHash',
                          'executor', 'valueWei', 'trade', 'digest', 'buyerSignatureSha256',
                          'sellerSignatureSha256', 'calldataSha256', 'transaction',
                          'l1AllowanceWei', 'maxTotalCostWei'))
REPLACEMENT_PACKAGE_KEYS = PACKAGE_KEYS | {'deploymentPolicySha256'}
REPLACEMENT_POLICY_KEYS = frozenset((
    'schema', 'chainId', 'pme', 'engine', 'engineRuntimeHash', 'pmeRuntimeHash',
    'pmr', 'risk', 'fees', 'vault', 'insurance', 'clearing', 'oracle',
    'seizer', 'legacyCollateralRisk', 'guardian',
    'engineRuntimeBytes', 'pmeRuntimeBytes',
    'owner', 'executor', 'buyer', 'seller', 'snapshotHash', 'deploymentBlock'))
TX_KEYS = frozenset(('nonce', 'gasLimit', 'maxFeePerGas', 'maxPriorityFeePerGas'))
MAX_DEADLINE_HORIZON = 900  # sign and approve near the actual closed test


class GuardRejected(ValueError):
    pass


def require(ok, message):
    if not ok:
        raise GuardRejected(message)


def wint(raw):
    return int.from_bytes(raw, 'big')


def a32(value):
    require(isinstance(value, str) and value.startswith('0x') and len(value) == 42,
            'invalid address')
    return bytes(12) + bytes.fromhex(value[2:])


def hex32(value):
    require(isinstance(value, str) and value.startswith('0x') and len(value) == 66,
            'invalid bytes32')
    return bytes.fromhex(value[2:])


def trade_words(trade):
    require(set(trade) == set(WORD_KEYS), 'trade fields changed')
    for key in UINT128_KEYS:
        require(type(trade[key]) is int and 0 <= trade[key] < 2**128, key + ' out of range')
    for key in ('marketId', 'buyerNonce', 'sellerNonce', 'deadline'):
        require(type(trade[key]) is int and 0 <= trade[key] < 2**256, key + ' out of range')
    require(type(trade['buyerIsMaker']) is bool, 'invalid maker flag')
    return [hex32(trade['intentId']), a32(trade['buyer']), a32(trade['seller']),
            word(trade['marketId']), word(trade['sizeDelta1e8']),
            word(trade['executionPrice1e8']), word(trade['maxExecutionPrice1e8']),
            word(trade['minExecutionPrice1e8']), word(int(trade['buyerIsMaker'])),
            word(trade['buyerNonce']), word(trade['sellerNonce']), word(trade['deadline'])]


def digest(trade, *, pme=PME):
    struct_hash = k256(k256(TRADE_TYPE.encode()) + b''.join(trade_words(trade)))
    return '0x' + k256(b'\x19\x01' + domain(CHAIN, pme) + struct_hash).hex()


def encode(trade, buyer_sig, seller_sig):
    require(len(buyer_sig) == len(seller_sig) == 65, 'signature length')
    words = trade_words(trade)
    first = 14*32
    second = first + 32 + 96
    def dynamic(value):
        return word(len(value)) + value + bytes(96-len(value))
    return SELECTOR + b''.join(words + [word(first), word(second)]) + dynamic(buyer_sig) + dynamic(seller_sig)


def decode(data):
    require(isinstance(data, bytes) and len(data) == 4+14*32+2*(32+96),
            'noncanonical calldata length')
    require(data[:4] == SELECTOR, 'alternate entrypoint or wrapper')
    words = [data[4+i*32:4+(i+1)*32] for i in range(14)]
    require(wint(words[12]) == 448 and wint(words[13]) == 576, 'noncanonical dynamic offsets')
    require(all(words[i][:12] == bytes(12) for i in (1, 2)), 'noncanonical address word')
    require(wint(words[8]) in (0, 1), 'noncanonical boolean')
    def signature(offset):
        start = 4+offset
        require(wint(data[start:start+32]) == 65, 'signature length')
        value = data[start+32:start+97]
        require(data[start+97:start+128] == bytes(31), 'noncanonical signature padding')
        return value
    trade = dict(zip(WORD_KEYS, (
        '0x'+words[0].hex(), '0x'+words[1][-20:].hex(), '0x'+words[2][-20:].hex(),
        *(wint(words[i]) for i in range(3, 8)), bool(wint(words[8])),
        *(wint(words[i]) for i in range(9, 12)))))
    buyer_sig, seller_sig = signature(448), signature(576)
    require(data == encode(trade, buyer_sig, seller_sig), 'noncanonical re-encoding')
    return trade, buyer_sig, seller_sig


def approved_hash(package_bytes):
    require(isinstance(package_bytes, bytes), 'package must be exact reviewed bytes')
    return hashlib.sha256(package_bytes).hexdigest()


def parse_replacement_policy(policy_bytes):
    require(type(policy_bytes) is bytes, 'replacement policy bytes missing')
    policy = json.loads(policy_bytes)
    require(set(policy) == REPLACEMENT_POLICY_KEYS and
            policy['schema'] == 'DEOPT_REPLACEMENT_FIRST_TRADE_DEPLOYMENT_POLICY_V1' and
            type(policy['chainId']) is int and policy['chainId'] == CHAIN and
            type(policy['deploymentBlock']) is int and policy['deploymentBlock'] > 0,
            'replacement policy schema')
    for key in ('pme', 'engine', 'pmr', 'risk', 'fees', 'vault', 'insurance',
                'clearing', 'oracle', 'seizer', 'legacyCollateralRisk', 'guardian',
                'owner', 'executor', 'buyer', 'seller'):
        a32(policy[key])
    for key in ('engineRuntimeHash', 'pmeRuntimeHash', 'snapshotHash'):
        hex32(policy[key])
    require(all(type(policy[key]) is int and 0 < policy[key] <= 24_576
                for key in ('engineRuntimeBytes', 'pmeRuntimeBytes')),
            'replacement runtime size policy')
    require(policy['pme'].lower() not in {PME.lower(), ENGINE.lower()} and
            policy['engine'].lower() != ENGINE.lower() and
            policy['pme'].lower() != policy['engine'].lower() and
            policy['executor'].lower() == EXECUTOR.lower() and
            policy['buyer'].lower() == BUYER.lower() and
            policy['seller'].lower() == SELLER.lower() and
            policy['snapshotHash'].lower() == '0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d' and
            policy['owner'].lower() == '0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588'.lower() and
            policy['guardian'].lower() == '0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46'.lower(),
            'replacement policy authority or scope')
    return policy


def validate(package_bytes, approved_sha256, candidate, live, *, deployment_policy_bytes=None):
    """Validate only. live must come from a fresh authenticated pinned RPC read."""
    require(approved_hash(package_bytes) == approved_sha256, 'approved package hash changed')
    package = json.loads(package_bytes)
    if deployment_policy_bytes is None:
        require(set(package) == PACKAGE_KEYS and package['schema'] == 'DEOPT_RESTRICTED_FIRST_TRADE_V1',
                'package schema')
        expected_pme, expected_engine, expected_hash = PME, ENGINE, ENGINE_HASH
    else:
        require(set(package) == REPLACEMENT_PACKAGE_KEYS and
                package['schema'] == 'DEOPT_RESTRICTED_FIRST_TRADE_REPLACEMENT_V1' and
                package['deploymentPolicySha256'] == approved_hash(deployment_policy_bytes),
                'replacement package/policy binding')
        policy = parse_replacement_policy(deployment_policy_bytes)
        expected_pme, expected_engine = policy['pme'], policy['engine']
        expected_hash = policy['engineRuntimeHash']
    require(set(package['transaction']) == TX_KEYS, 'transaction envelope schema')
    require(package['chainId'] == candidate['chainId'] == live['chainId'] == CHAIN,
            'wrong chain')
    require(package['pme'].lower() == candidate['to'].lower() == expected_pme.lower(), 'wrong destination')
    require(package['engine'].lower() == live['pmeEngine'].lower() == expected_engine.lower(),
            'PME not rebound to recovery engine')
    require(package['engineRuntimeHash'].lower() == live['engineRuntimeHash'].lower() == expected_hash.lower(),
            'engine runtime changed')
    require(live['domainSeparator'].lower() == '0x'+domain(CHAIN, expected_pme).hex(), 'wrong live EIP-712 domain')
    require(package['executor'].lower() == candidate['from'].lower() == EXECUTOR.lower(),
            'wrong executor')
    require({x.lower() for x in live['activeExecutors']} == {EXECUTOR.lower()},
            'other executor remains authorized')
    require(candidate['valueWei'] == package['valueWei'] == 0, 'nonzero ETH value')
    require(set(candidate) == ({'chainId', 'from', 'to', 'valueWei', 'data'} | TX_KEYS),
            'candidate transaction fields changed')
    for key in TX_KEYS:
        require(type(package['transaction'][key]) is int and
                candidate[key] == package['transaction'][key], key + ' drift')
    require(package['transaction']['gasLimit'] > 0 and
            package['transaction']['maxFeePerGas'] >= package['transaction']['maxPriorityFeePerGas'] > 0,
            'invalid approved gas/fee envelope')
    require(type(package['l1AllowanceWei']) is int and package['l1AllowanceWei'] >= 0 and
            type(package['maxTotalCostWei']) is int and package['maxTotalCostWei'] > 0 and
            type(live['l1FeeQuoteWei']) is int and live['l1FeeQuoteWei'] >= 0 and
            type(live['executorBalanceWei']) is int and live['executorBalanceWei'] >= 0,
            'missing or invalid L1/balance quote')
    require(live['l1FeeQuoteWei'] <= package['l1AllowanceWei'], 'L1 allowance exceeded')
    planning_cost = (package['transaction']['gasLimit'] * package['transaction']['maxFeePerGas']
                     + package['l1AllowanceWei'])
    require(planning_cost <= package['maxTotalCostWei'] <= live['executorBalanceWei'],
            'fee budget or balance insufficient')
    require(candidate['nonce'] == live['executorNonceConfirmed'] == live['executorNoncePending'],
            'executor nonce drift')
    require(live['pmePaused'] is False and live['engineTradingPaused'] is False and
            live['engineFundingPaused'] is False, 'maintenance release not separately verified')
    require(live['vaultAuthorized'] is True and live['insuranceAuthorized'] is True and
            live['feeConsumerAuthorized'] is True, 'dependencies not authorized')
    require(live['migrationSealed'] is True and live['marketId'] == 1, 'migration/market state drift')

    data = bytes.fromhex(candidate['data'][2:]) if isinstance(candidate['data'], str) and candidate['data'].startswith('0x') else b''
    require(hashlib.sha256(data).hexdigest() == package['calldataSha256'], 'calldata changed')
    trade, buyer_sig, seller_sig = decode(data)
    approved_trade = package['trade']
    require(set(approved_trade) == set(WORD_KEYS), 'approved trade shape')
    for key in WORD_KEYS:
        if key in ('buyer', 'seller', 'intentId'):
            require(trade[key].lower() == approved_trade[key].lower(), key + ' changed')
        else:
            require(trade[key] == approved_trade[key], key + ' changed')
    require(trade['buyer'].lower() == BUYER.lower() and
            trade['seller'].lower() == SELLER.lower() and
            trade['buyer'].lower() != trade['seller'].lower(), 'wrong close traders/roles')
    require(trade['marketId'] == 1 and trade['sizeDelta1e8'] > 0 and
            trade['executionPrice1e8'] > 0, 'invalid close economics')
    require(live['buyerSize1e8'] < 0 and live['sellerSize1e8'] > 0 and
            trade['sizeDelta1e8'] <= min(-live['buyerSize1e8'], live['sellerSize1e8']),
            'oversized or exposure-increasing close')
    require(trade['maxExecutionPrice1e8'] > 0 and
            trade['executionPrice1e8'] <= trade['maxExecutionPrice1e8'], 'buyer bound')
    require(trade['minExecutionPrice1e8'] > 0 and
            trade['executionPrice1e8'] >= trade['minExecutionPrice1e8'], 'seller bound')
    require(trade['buyerNonce'] == live['buyerNonce'] and
            trade['sellerNonce'] == live['sellerNonce'], 'trader nonce drift')
    require(trade['deadline'] != 0 and
            live['blockTimestamp'] < trade['deadline'] <= live['blockTimestamp']+MAX_DEADLINE_HORIZON,
            'expired, zero, or overlong deadline')
    require(trade['intentId'] != '0x'+bytes(32).hex() and
            trade['intentId'].lower() not in {x.lower() for x in live['knownHistoricalIntentIds']},
            'intent ID not fresh')
    require(digest(trade, pme=expected_pme).lower() == package['digest'].lower(), 'digest changed')
    require(hashlib.sha256(buyer_sig).hexdigest() == package['buyerSignatureSha256'] and
            hashlib.sha256(seller_sig).hexdigest() == package['sellerSignatureSha256'],
            'signature bytes changed')
    require(recover(bytes.fromhex(package['digest'][2:]), '0x'+buyer_sig.hex()) == trade['buyer'].lower() and
            recover(bytes.fromhex(package['digest'][2:]), '0x'+seller_sig.hex()) == trade['seller'].lower(),
            'signature does not match exact live-domain trade')
    return {'packageSha256': approved_sha256, 'calldataSha256': package['calldataSha256'],
            'digest': package['digest'], 'preflightBlockHash': live['blockHash'],
            'executor': package['executor'], 'nonce': candidate['nonce'],
            'gasLimit': candidate['gasLimit'], 'maxFeePerGas': candidate['maxFeePerGas'],
            'maxPriorityFeePerGas': candidate['maxPriorityFeePerGas']}


def _persist(path, record):
    """Atomic, durable journal write; called before any injected sender."""
    path = Path(path)
    pending = path.with_suffix(path.suffix+'.tmp')
    fd = os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(record, out, sort_keys=True)
            out.write('\n')
            out.flush()
            os.fsync(out.fileno())
        os.replace(pending, path)
        dfd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except BaseException:
        # Leave any uncertain journal/temp file for operator reconciliation.
        raise


def one_shot(decision, journal, signed_bytes, send_callback, *,
             locked_preflight, persist=_persist):
    """Journal the exact immutable bytes before a caller-supplied test transport.

    No sender is supplied. The final check runs under the exclusive lock.
    An ambiguous callback leaves SUBMISSION_UNKNOWN; no retry.
    """
    require(set(decision) == {'packageSha256', 'calldataSha256', 'digest',
                             'preflightBlockHash', 'executor', 'nonce', 'gasLimit',
                             'maxFeePerGas', 'maxPriorityFeePerGas'}, 'unvalidated decision')
    require(type(signed_bytes) is bytes and len(signed_bytes) > 0,
            'immutable signed transaction missing')
    require(callable(locked_preflight), 'locked final preflight missing')
    tx_hash = '0x'+k256(signed_bytes).hex()
    path = Path(journal)
    parent = path.parent.stat()
    require(stat.S_ISDIR(parent.st_mode) and parent.st_uid == os.getuid() and
            parent.st_mode & 0o077 == 0, 'journal directory must be private and owned')
    lock = path.with_suffix(path.suffix+'.lock')
    lock_fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        require(not path.exists() and not path.with_suffix(path.suffix+'.tmp').exists(),
                'prior or ambiguous attempt exists')
        fresh = locked_preflight()
        require(fresh['packageSha256'] == decision['packageSha256'] and
                fresh['calldataSha256'] == decision['calldataSha256'] and
                fresh['digest'] == decision['digest'] and
                fresh['executor'].lower() == decision['executor'].lower() and
                fresh['nonce'] == decision['nonce'] and
                fresh['gasLimit'] == decision['gasLimit'] and
                fresh['maxFeePerGas'] == decision['maxFeePerGas'] and
                fresh['maxPriorityFeePerGas'] == decision['maxPriorityFeePerGas'],
                'final locked preflight changed approved decision')
        decision = fresh
        record = {'status': 'SUBMISSION_UNKNOWN', 'packageSha256': decision['packageSha256'],
                  'calldataSha256': decision['calldataSha256'], 'txHash': tx_hash,
                  'nonce': decision['nonce'], 'preflightBlockHash': decision['preflightBlockHash'],
                  'recordedAtUnix': int(time.time())}
        persist(path, record)
        observed_hash = send_callback(signed_bytes)
        require(observed_hash == tx_hash, 'ambiguous submission; reconcile exact hash')
        persist(path, {**record, 'status': 'SUBMITTED'})
    finally:
        os.close(lock_fd)
