"""Durable, fail-closed fee decision for the single-call maintenance finish.

All amounts are integer wei. The GasPriceOracle argument is the unsigned,
fully RLP-encoded transaction size in bytes; the oracle adds 68 bytes itself.
This module never accesses a keystore or a public write RPC.
"""

import json
import os
from pathlib import Path


class FeeGuardStop(RuntimeError):
    pass


def _uint(value, name):
    if type(value) is not int or value < 0:
        raise ValueError(name + ' must be a nonnegative integer')
    return value


def decide(*, block, quote, additional_fee_quote_wei, observed_base_fee_wei,
           observed_priority_fee_wei, observed_gas_price_wei, observed_gas_estimate,
           policy, balance_wei):
    """Return a complete decision record, including malformed-quote STOPs."""
    record = {
        'blockNumber': block.get('number'),
        'blockHash': block.get('hash'),
        'blockTimestamp': block.get('timestamp'),
        'rpcMethod': 'eth_call',
        'oracleAddress': '0x420000000000000000000000000000000000000F',
        'oracleFunction': 'getL1FeeUpperBound(uint256)',
        'oracleUnsignedTxSizeBytes': policy.get('oracleUnsignedTxSizeBytes'),
        'oracleReturnedL1BoundWei': quote,
        'approvedL2GasEstimate': policy.get('l2GasEstimate'),
        'observedL2GasEstimate': observed_gas_estimate,
        'gasLimit': policy.get('gasLimit'),
        'observedBaseFeePerGasWei': observed_base_fee_wei,
        'observedSuggestedPriorityFeePerGasWei': observed_priority_fee_wei,
        'observedRpcGasPriceWei': observed_gas_price_wei,
        'maxFeePerGasWei': policy.get('maxFeePerGasWei'),
        'maxPriorityFeePerGasWei': policy.get('maxPriorityFeePerGasWei'),
        'l1BoundMultiplierNumerator': policy.get('l1BoundMultiplierNumerator'),
        'l1BoundMultiplierDenominator': policy.get('l1BoundMultiplierDenominator'),
        'approvedL1AllowanceWei': policy.get('l1AllowanceWei'),
        'additionalFeeAllowanceWei': policy.get('additionalFeeAllowanceWei'),
        'additionalFeeQuotedWei': additional_fee_quote_wei,
        'totalPlanningBudgetWei': policy.get('totalPlanningBudgetWei'),
        'ownerBalanceWei': balance_wei,
        'comparison': 'scaledL1BoundWei <= approvedL1AllowanceWei; additionalFeeQuotedWei <= additionalFeeAllowanceWei; observedL2GasEstimate <= gasLimit; 2*baseFee+suggestedPriority <= maxFeePerGas; suggestedPriority <= maxPriorityFeePerGas; rpcGasPrice <= maxFeePerGas; ownerBalanceWei > totalPlanningBudgetWei',
        'result': 'STOP',
    }
    try:
        for field in ('number', 'timestamp'):
            _uint(block.get(field), 'block.' + field)
        if not isinstance(block.get('hash'), str) or len(block['hash']) != 66 or int(block['hash'], 16) == 0:
            raise ValueError('block.hash missing or malformed')
        for field in ('oracleUnsignedTxSizeBytes', 'l2GasEstimate', 'gasLimit', 'maxFeePerGasWei',
                      'maxPriorityFeePerGasWei', 'l1BoundMultiplierNumerator',
                      'l1BoundMultiplierDenominator', 'l1AllowanceWei',
                      'additionalFeeAllowanceWei', 'totalPlanningBudgetWei'):
            _uint(policy.get(field), field)
        _uint(quote, 'oracle quote')
        _uint(additional_fee_quote_wei, 'additional fee quote')
        _uint(observed_base_fee_wei, 'base fee')
        _uint(observed_priority_fee_wei, 'suggested priority fee')
        _uint(observed_gas_price_wei, 'RPC gas price')
        _uint(observed_gas_estimate, 'observed gas estimate')
        _uint(balance_wei, 'owner balance')
        if not policy['oracleUnsignedTxSizeBytes'] or not policy['l1BoundMultiplierDenominator']:
            raise ValueError('zero oracle size or multiplier denominator')
        if policy['l2GasEstimate'] > policy['gasLimit'] or observed_gas_estimate > policy['gasLimit']:
            raise ValueError('gas estimate exceeds gas limit')
        if policy['maxPriorityFeePerGasWei'] > policy['maxFeePerGasWei']:
            raise ValueError('priority cap exceeds max fee cap')
        expected_budget = (policy['gasLimit'] * policy['maxFeePerGasWei']
                           + policy['l1AllowanceWei'] + policy['additionalFeeAllowanceWei'])
        if policy['totalPlanningBudgetWei'] != expected_budget:
            raise ValueError('planning budget mismatch')
        scaled = (quote * policy['l1BoundMultiplierNumerator'] + policy['l1BoundMultiplierDenominator'] - 1) // policy['l1BoundMultiplierDenominator']
        record['scaledL1BoundWei'] = scaled
        if scaled > policy['l1AllowanceWei']:
            record['reason'] = 'L1_BOUND_EXCEEDS_APPROVED_ALLOWANCE'
        elif additional_fee_quote_wei > policy['additionalFeeAllowanceWei']:
            record['reason'] = 'ADDITIONAL_FEE_EXCEEDS_APPROVED_ALLOWANCE'
        elif (2 * observed_base_fee_wei + observed_priority_fee_wei > policy['maxFeePerGasWei']
              or observed_priority_fee_wei > policy['maxPriorityFeePerGasWei']
              or observed_gas_price_wei > policy['maxFeePerGasWei']):
            record['reason'] = 'NETWORK_GAS_PRICE_EXCEEDS_APPROVED_CAP'
        elif balance_wei <= expected_budget:
            record['reason'] = 'INSUFFICIENT_BALANCE_FOR_APPROVED_BUDGET'
        else:
            record['result'], record['reason'] = 'PASS', 'WITHIN_APPROVED_LIMITS'
    except (TypeError, ValueError, KeyError) as error:
        record['reason'] = 'MALFORMED_FEE_INPUT'
        record['detail'] = str(error)
    return record


def persist_and_require(path, record):
    """Persist decision before allowing any send; fail closed on write errors."""
    path = Path(path)
    if path.exists():
        raise FeeGuardStop('Fee decision already exists; no overwrite or resend')
    payload = json.dumps(record, indent=2, sort_keys=True, allow_nan=False) + '\n'
    temporary = path.with_name(path.name + '.tmp')
    try:
        with temporary.open('x') as file:
            file.write(payload)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except OSError as error:
        raise FeeGuardStop('Could not persist fee decision; send forbidden') from error
    if record.get('result') != 'PASS':
        raise FeeGuardStop('Fee guard STOP: ' + str(record.get('reason')))
    return record


def guarded_send(*, path, block, quote, additional_fee_quote_wei,
                 observed_base_fee_wei, observed_priority_fee_wei,
                 observed_gas_price_wei, observed_gas_estimate,
                 policy, balance_wei, send):
    """The only entry to the sender callback; tests prove STOP never invokes it."""
    record = decide(block=block, quote=quote, additional_fee_quote_wei=additional_fee_quote_wei,
                    observed_base_fee_wei=observed_base_fee_wei,
                    observed_priority_fee_wei=observed_priority_fee_wei,
                    observed_gas_price_wei=observed_gas_price_wei,
                    observed_gas_estimate=observed_gas_estimate,
                    policy=policy, balance_wei=balance_wei)
    persist_and_require(path, record)
    return send()
