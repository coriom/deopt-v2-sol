// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IOptionExecutionFeeHook} from "../../../../src/hybrid-v2/interfaces/IOptionExecutionFeeHook.sol";

/// @title MockOptionExecutionFeeHook
/// @notice Test-only concrete fee hook. Configurable bps + rejection + rebate.
///         NOT production source.
contract MockOptionExecutionFeeHook is IOptionExecutionFeeHook {
    uint16 public takerFeeBps; // fee as bps of premium notional
    uint16 public makerFeeBps;
    bool public reject; // when true, all quotes return ok=false
    bool public emitRebate; // when true, returns non-zero rebate

    function setFees(uint16 takerBps, uint16 makerBps) external {
        takerFeeBps = takerBps;
        makerFeeBps = makerBps;
    }

    function setReject(bool r) external {
        reject = r;
    }

    function setEmitRebate(bool e) external {
        emitRebate = e;
    }

    function quoteExecutionFee(
        bytes32, /*subKey*/
        address, /*token*/
        uint128 quantity1e8,
        uint128 pricePerContract1e8,
        uint8 orderRole
    )
        external
        view
        returns (uint128 feeAmount1e8, uint128 rebateAmount1e8, bool ok)
    {
        if (reject) return (0, 0, false);
        // premium1e8 = quantity1e8 * price / 1e8
        uint256 premium1e8 = (uint256(quantity1e8) * uint256(pricePerContract1e8)) / 1e8;
        uint16 bps = orderRole == 0 ? makerFeeBps : takerFeeBps;
        uint256 fee1e8 = (premium1e8 * uint256(bps) + 9_999) / 10_000; // round up
        feeAmount1e8 = uint128(fee1e8);
        rebateAmount1e8 = emitRebate ? uint128(1) : uint128(0);
        ok = true;
    }
}
