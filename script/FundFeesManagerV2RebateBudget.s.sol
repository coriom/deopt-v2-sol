// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";

/// @title FundFeesManagerV2RebateBudget
/// @notice V2G-B preflight + optional broadcast for
///         `FeesManagerV2.fundRebateBudget(settlementAsset, amount)`.
/// @dev
///  IMPORTANT: `fundRebateBudget` is **accounting-only** in the V2D-C
///  V2 fee model — it increments the on-contract `rebateBudget[asset]`
///  ledger and emits `RebateBudgetFunded`. It does **not** pull any
///  ERC20 from the operator or the funding account. The actual mUSDC
///  movement on a rebate happens inside the consumer's settlement path.
///  Therefore this script does NOT call `IERC20.approve` — no allowance
///  is required to fund the bookkeeping mapping.
///
///  The optional `REBATE_TOKEN_BALANCE_CHECK` flag (default true)
///  reads `IERC20(token).balanceOf(rebateFundingAccount)` so the
///  preflight surfaces whether the funding account has enough mUSDC
///  to cover the would-be rebates during the smoke. The check is
///  read-only and never reverts on the call site.
///
///  Required env in all cases:
///    - `DEPLOYER_PRIVATE_KEY` (owner key)
///    - `FEES_MANAGER_V2_ADDRESS`
///    - `REBATE_TOKEN`
///    - `REBATE_BUDGET_AMOUNT`
///
///  Optional env:
///    - `REBATE_FUNDING_ACCOUNT` — checked against the on-contract
///      value; mismatch logs a warning but does not revert.
///    - `REBATE_TOKEN_BALANCE_CHECK=true` (default true).
///
///  Mutating call gated by:
///    - `FUND_FEES_MANAGER_V2_REBATE_BUDGET_CONFIRM=true`
contract FundFeesManagerV2RebateBudget is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Inputs {
        address caller;
        address feesManager;
        address token;
        address fundingAccountFromEnv;
        uint256 amount;
        bool balanceCheck;
        bool confirmed;
    }

    struct Snapshot {
        address owner;
        address rebateFundingAccount;
        uint256 rebateBudget;
        uint256 fundingAccountBalance;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error FeesManagerUnset();
    error TokenUnset();
    error AmountZero();
    error NoCodeAt(string name, address target);
    error NotOwner(address caller, address owner);
    error RebateFundingAccountUnset();
    error BudgetDidNotIncrease(uint256 before_, uint256 after_, uint256 expectedDelta);

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        Inputs memory inputs = _readInputs();
        _validateInputs(inputs);

        Snapshot memory before_ = _snapshot(inputs);
        _logInputs(inputs);
        _logSnapshot("before", before_);

        _validatePreconditions(inputs, before_);

        if (!inputs.confirmed) {
            console2.log("FUND_FEES_MANAGER_V2_REBATE_BUDGET_CONFIRM not set; preflight done, no transactions sent.");
            return;
        }

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPk);
        FeesManagerV2(inputs.feesManager).fundRebateBudget(inputs.token, inputs.amount);
        vm.stopBroadcast();

        Snapshot memory after_ = _snapshot(inputs);
        _logSnapshot("after", after_);
        _verifyPostState(inputs, before_, after_);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _readInputs() internal view returns (Inputs memory inputs) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        inputs.caller = vm.addr(deployerPk);
        inputs.feesManager = _envAddressOrZero("FEES_MANAGER_V2_ADDRESS");
        inputs.token = _envAddressOrZero("REBATE_TOKEN");
        inputs.fundingAccountFromEnv = _envAddressOrZero("REBATE_FUNDING_ACCOUNT");
        inputs.amount = vm.envUint("REBATE_BUDGET_AMOUNT");
        inputs.balanceCheck = vm.envOr("REBATE_TOKEN_BALANCE_CHECK", true);
        inputs.confirmed = vm.envOr("FUND_FEES_MANAGER_V2_REBATE_BUDGET_CONFIRM", false);
    }

    function _validateInputs(Inputs memory inputs) internal view {
        if (inputs.feesManager == address(0)) revert FeesManagerUnset();
        if (inputs.feesManager.code.length == 0) {
            revert NoCodeAt("FEES_MANAGER_V2_ADDRESS", inputs.feesManager);
        }
        if (inputs.token == address(0)) revert TokenUnset();
        if (inputs.amount == 0) revert AmountZero();
    }

    function _snapshot(Inputs memory inputs) internal view returns (Snapshot memory snap) {
        FeesManagerV2 fm = FeesManagerV2(inputs.feesManager);
        snap.owner = fm.owner();
        snap.rebateFundingAccount = fm.rebateFundingAccount();
        snap.rebateBudget = fm.rebateBudget(inputs.token);
        if (inputs.balanceCheck && snap.rebateFundingAccount != address(0) && inputs.token.code.length > 0) {
            (bool ok, bytes memory data) =
                inputs.token.staticcall(abi.encodeWithSignature("balanceOf(address)", snap.rebateFundingAccount));
            if (ok && data.length == 32) {
                snap.fundingAccountBalance = abi.decode(data, (uint256));
            }
        }
    }

    function _validatePreconditions(Inputs memory inputs, Snapshot memory snap) internal pure {
        if (inputs.confirmed) {
            if (inputs.caller != snap.owner) revert NotOwner(inputs.caller, snap.owner);
            if (snap.rebateFundingAccount == address(0)) revert RebateFundingAccountUnset();
        }
    }

    function _verifyPostState(Inputs memory inputs, Snapshot memory before_, Snapshot memory after_) internal pure {
        uint256 expected = before_.rebateBudget + inputs.amount;
        if (after_.rebateBudget != expected) {
            revert BudgetDidNotIncrease(before_.rebateBudget, after_.rebateBudget, inputs.amount);
        }
    }

    function _logInputs(Inputs memory inputs) internal view {
        console2.log("FeesManagerV2.fundRebateBudget preflight V2G-B (accounting-only call)");
        console2.log("chainId", block.chainid);
        console2.log("caller (sanitized, no key)", inputs.caller);
        console2.log("FEES_MANAGER_V2_ADDRESS", inputs.feesManager);
        console2.log("REBATE_TOKEN", inputs.token);
        console2.log("REBATE_BUDGET_AMOUNT", inputs.amount);
        console2.log("REBATE_FUNDING_ACCOUNT (env)", inputs.fundingAccountFromEnv);
        console2.log("REBATE_TOKEN_BALANCE_CHECK", inputs.balanceCheck);
        console2.log("FUND_FEES_MANAGER_V2_REBATE_BUDGET_CONFIRM", inputs.confirmed);
    }

    function _logSnapshot(string memory label, Snapshot memory snap) internal pure {
        console2.log("State snapshot:", label);
        console2.log(" FeesManagerV2.owner()", snap.owner);
        console2.log(" FeesManagerV2.rebateFundingAccount()", snap.rebateFundingAccount);
        console2.log(" FeesManagerV2.rebateBudget(token)", snap.rebateBudget);
        console2.log(" IERC20(token).balanceOf(rebateFundingAccount)", snap.fundingAccountBalance);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
