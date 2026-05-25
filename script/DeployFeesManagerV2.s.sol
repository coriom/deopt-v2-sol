// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";

/// @title DeployFeesManagerV2
/// @notice Safe-by-default deployment preflight for `FeesManagerV2` (V2D-F).
/// @dev
///  Safety model:
///    - prints sanitized config and aborts unless `DEPLOY_FEES_MANAGER_V2_CONFIRM=true`;
///    - never enables `useFeesManagerV2` on any engine (that lives in the wiring script);
///    - never wires `MarginEngine` (kept in the wiring script);
///    - never prints the private key (only the derived deployer address);
///    - rebate budget funding is opt-in via a separate `FUND_REBATE_BUDGET_CONFIRM=true` flag,
///      intended for local/fork validation only.
///
///  Required env when confirmed:
///    - DEPLOYER_PRIVATE_KEY
///    - INITIAL_OWNER (or falls back to deployer)
///    - FEES_MANAGER_V2_FEE_RECIPIENT
///    - FEES_MANAGER_V2_REBATE_FUNDING_ACCOUNT
///
///  Optional env (local/fork rebate budget seeding):
///    - FEES_MANAGER_V2_INITIAL_REBATE_ASSET
///    - FEES_MANAGER_V2_INITIAL_REBATE_BUDGET
///    - FUND_REBATE_BUDGET_CONFIRM=true (required to actually fund)
contract DeployFeesManagerV2 is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct PreflightInputs {
        address deployer;
        address initialOwner;
        address feeRecipient;
        address rebateFundingAccount;
        address initialRebateAsset;
        uint256 initialRebateBudget;
        bool deployConfirmed;
        bool fundRebateConfirmed;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error FeeRecipientUnset();
    error RebateFundingAccountUnset();
    error InitialOwnerUnset();
    error PostDeployFeeRecipientMismatch(address expected, address actual);
    error PostDeployOwnerMismatch(address expected, address actual);
    error PostDeployRebateFundingAccountMismatch(address expected, address actual);
    error InvalidRebateAssetForBudget();

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external returns (address feesManagerV2) {
        PreflightInputs memory inputs = _readInputs();
        _validateInputs(inputs);
        _logSanitizedConfig(inputs);

        if (!inputs.deployConfirmed) {
            console2.log("DEPLOY_FEES_MANAGER_V2_CONFIRM is not set to true; aborting deployment.");
            console2.log("This was a sanitized preflight only. No contract was deployed.");
            return address(0);
        }

        feesManagerV2 = _broadcastDeploy(inputs);
        _verifyPostDeployState(feesManagerV2, inputs);
        return feesManagerV2;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _readInputs() internal view returns (PreflightInputs memory inputs) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        inputs.deployer = vm.addr(deployerPk);
        inputs.initialOwner = vm.envOr("INITIAL_OWNER", inputs.deployer);

        inputs.feeRecipient = _envAddressOrZero("FEES_MANAGER_V2_FEE_RECIPIENT");
        inputs.rebateFundingAccount = _envAddressOrZero("FEES_MANAGER_V2_REBATE_FUNDING_ACCOUNT");

        inputs.initialRebateAsset = _envAddressOrZero("FEES_MANAGER_V2_INITIAL_REBATE_ASSET");
        inputs.initialRebateBudget = vm.envOr("FEES_MANAGER_V2_INITIAL_REBATE_BUDGET", uint256(0));

        inputs.deployConfirmed = vm.envOr("DEPLOY_FEES_MANAGER_V2_CONFIRM", false);
        inputs.fundRebateConfirmed = vm.envOr("FUND_REBATE_BUDGET_CONFIRM", false);
    }

    function _validateInputs(PreflightInputs memory inputs) internal pure {
        if (inputs.initialOwner == address(0)) revert InitialOwnerUnset();
        if (inputs.feeRecipient == address(0)) revert FeeRecipientUnset();
        if (inputs.rebateFundingAccount == address(0)) revert RebateFundingAccountUnset();
        if (inputs.initialRebateBudget != 0 && inputs.initialRebateAsset == address(0)) {
            revert InvalidRebateAssetForBudget();
        }
    }

    function _broadcastDeploy(PreflightInputs memory inputs) internal returns (address feesManagerV2) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPk);

        FeesManagerV2 manager = new FeesManagerV2(inputs.initialOwner, inputs.feeRecipient);
        manager.setRebateFundingAccount(inputs.rebateFundingAccount);

        if (inputs.fundRebateConfirmed && inputs.initialRebateAsset != address(0) && inputs.initialRebateBudget != 0) {
            manager.fundRebateBudget(inputs.initialRebateAsset, inputs.initialRebateBudget);
        }

        vm.stopBroadcast();

        feesManagerV2 = address(manager);
    }

    function _verifyPostDeployState(address feesManagerV2, PreflightInputs memory inputs) internal view {
        FeesManagerV2 manager = FeesManagerV2(feesManagerV2);

        address actualOwner = manager.owner();
        if (actualOwner != inputs.initialOwner) {
            revert PostDeployOwnerMismatch(inputs.initialOwner, actualOwner);
        }

        address actualFeeRecipient = manager.feeRecipient();
        if (actualFeeRecipient != inputs.feeRecipient) {
            revert PostDeployFeeRecipientMismatch(inputs.feeRecipient, actualFeeRecipient);
        }

        address actualRebateFundingAccount = manager.rebateFundingAccount();
        if (actualRebateFundingAccount != inputs.rebateFundingAccount) {
            revert PostDeployRebateFundingAccountMismatch(inputs.rebateFundingAccount, actualRebateFundingAccount);
        }

        uint256 rebateBudget =
            inputs.initialRebateAsset == address(0) ? 0 : manager.rebateBudget(inputs.initialRebateAsset);

        console2.log("FeesManagerV2 deployed");
        console2.log("FeesManagerV2 address", feesManagerV2);
        console2.log("FeesManagerV2.owner()", actualOwner);
        console2.log("FeesManagerV2.feeRecipient()", actualFeeRecipient);
        console2.log("FeesManagerV2.rebateFundingAccount()", actualRebateFundingAccount);
        console2.log("FeesManagerV2.rebateBudget(initialAsset)", rebateBudget);
    }

    function _logSanitizedConfig(PreflightInputs memory inputs) internal view {
        console2.log("FeesManagerV2 deployment preflight V2D-F");
        console2.log("chainId", block.chainid);
        console2.log("deployer (sanitized, no key)", inputs.deployer);
        console2.log("initialOwner", inputs.initialOwner);
        console2.log("feeRecipient", inputs.feeRecipient);
        console2.log("rebateFundingAccount", inputs.rebateFundingAccount);
        console2.log("initialRebateAsset", inputs.initialRebateAsset);
        console2.log("initialRebateBudget", inputs.initialRebateBudget);
        console2.log("DEPLOY_FEES_MANAGER_V2_CONFIRM", inputs.deployConfirmed);
        console2.log("FUND_REBATE_BUDGET_CONFIRM", inputs.fundRebateConfirmed);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
