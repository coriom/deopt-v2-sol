// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";
import {MarginEngine} from "../src/margin/MarginEngine.sol";

/// @title WireFeesManagerV2Option
/// @notice Safe-by-default V2D-F wiring preflight for the option `MarginEngine` -> `FeesManagerV2` link.
/// @dev
///  Two independent confirmation flags gate the only two mutating operations:
///    - WIRE_FEES_MANAGER_V2_CONFIRM=true  -> set V2 manager on engine + authorize engine as fee consumer
///    - ENABLE_FEES_MANAGER_V2_CONFIRM=true -> flip MarginEngine.useFeesManagerV2 from false to true
///
///  Default is safe: no wiring, no enabling, only a sanitized read-only preflight.
///  Enabling V2 fees requires both confirmations; wiring alone never changes engine fee routing,
///  because `useFeesManagerV2` remains false unless explicitly enabled here.
///
///  Required env when WIRE_FEES_MANAGER_V2_CONFIRM=true:
///    - DEPLOYER_PRIVATE_KEY (engine + manager owner)
///    - MARGIN_ENGINE_ADDRESS
///    - FEES_MANAGER_V2_ADDRESS
contract WireFeesManagerV2Option is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct WiringInputs {
        address caller;
        address marginEngine;
        address feesManagerV2;
        bool wireConfirmed;
        bool enableConfirmed;
    }

    struct StateSnapshot {
        address marginEngineFeesManagerV2;
        bool useFeesManagerV2;
        bool isFeeConsumer;
        address feeRecipient;
        address rebateFundingAccount;
        address feesManagerV2Owner;
        address marginEngineOwner;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error MarginEngineUnset();
    error FeesManagerV2Unset();
    error NotMarginEngineOwner(address caller, address owner);
    error NotFeesManagerV2Owner(address caller, address owner);
    error FeeRecipientZero();
    error RebateFundingAccountZero();
    error EnableRequiresWire();
    error WireDidNotTake(address expected, address actual);
    error ConsumerNotAuthorized(address engine);
    error UseFeesManagerV2NotEnabled();
    error UnexpectedV1Drift();

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        WiringInputs memory inputs = _readInputs();
        _validateInputs(inputs);

        StateSnapshot memory before_ = _snapshot(inputs);
        _logInputs(inputs);
        _logSnapshot("before", before_);

        _validatePreconditions(inputs, before_);

        if (!inputs.wireConfirmed && !inputs.enableConfirmed) {
            console2.log("Neither WIRE nor ENABLE confirmed; preflight done, no transactions sent.");
            return;
        }

        if (inputs.enableConfirmed && !inputs.wireConfirmed && before_.marginEngineFeesManagerV2 == address(0)) {
            revert EnableRequiresWire();
        }

        // V2G-P keystore mode: PK is optional. When unset Foundry uses
        // `--account <keystore>` / `--sender <addr>` from the CLI.
        uint256 deployerPk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        if (deployerPk != 0) {
            vm.startBroadcast(deployerPk);
        } else {
            vm.startBroadcast();
        }

        if (inputs.wireConfirmed) {
            _applyWire(inputs);
        }

        if (inputs.enableConfirmed) {
            _applyEnable(inputs);
        }

        vm.stopBroadcast();

        StateSnapshot memory after_ = _snapshot(inputs);
        _logSnapshot("after", after_);
        _verifyPostState(inputs, after_);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _readInputs() internal view returns (WiringInputs memory inputs) {
        // V2G-P keystore mode: derive caller from PK when set, otherwise from
        // `DEPLOYER_ADDRESS` env (defaulting to the canonical V2 deployer EOA).
        uint256 deployerPk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address envDeployer = vm.envOr("DEPLOYER_ADDRESS", address(0xc35F7A8A103A9A4464adfaa76B9B514093D23C27));
        if (deployerPk != 0) {
            inputs.caller = vm.addr(deployerPk);
        } else {
            inputs.caller = envDeployer;
        }
        inputs.marginEngine = _envAddressOrZero("MARGIN_ENGINE_ADDRESS");
        inputs.feesManagerV2 = _envAddressOrZero("FEES_MANAGER_V2_ADDRESS");

        inputs.wireConfirmed = vm.envOr("WIRE_FEES_MANAGER_V2_CONFIRM", false);
        inputs.enableConfirmed = vm.envOr("ENABLE_FEES_MANAGER_V2_CONFIRM", false);
    }

    function _validateInputs(WiringInputs memory inputs) internal view {
        if (inputs.marginEngine == address(0)) revert MarginEngineUnset();
        if (inputs.feesManagerV2 == address(0)) revert FeesManagerV2Unset();

        if (inputs.marginEngine.code.length == 0) revert MarginEngineUnset();
        if (inputs.feesManagerV2.code.length == 0) revert FeesManagerV2Unset();
    }

    function _snapshot(WiringInputs memory inputs) internal view returns (StateSnapshot memory snap) {
        MarginEngine engine = MarginEngine(inputs.marginEngine);
        FeesManagerV2 fees = FeesManagerV2(inputs.feesManagerV2);

        snap.marginEngineOwner = engine.owner();
        snap.marginEngineFeesManagerV2 = address(engine.feesManagerV2());
        snap.useFeesManagerV2 = engine.useFeesManagerV2();

        snap.feesManagerV2Owner = fees.owner();
        snap.feeRecipient = fees.feeRecipient();
        snap.rebateFundingAccount = fees.rebateFundingAccount();
        snap.isFeeConsumer = fees.isFeeConsumer(inputs.marginEngine);
    }

    function _validatePreconditions(WiringInputs memory inputs, StateSnapshot memory snap) internal pure {
        if (snap.marginEngineOwner != inputs.caller) {
            revert NotMarginEngineOwner(inputs.caller, snap.marginEngineOwner);
        }
        if (snap.feesManagerV2Owner != inputs.caller) {
            revert NotFeesManagerV2Owner(inputs.caller, snap.feesManagerV2Owner);
        }
        if (snap.feeRecipient == address(0)) revert FeeRecipientZero();
        if (snap.rebateFundingAccount == address(0)) revert RebateFundingAccountZero();
    }

    function _applyWire(WiringInputs memory inputs) internal {
        MarginEngine engine = MarginEngine(inputs.marginEngine);
        FeesManagerV2 fees = FeesManagerV2(inputs.feesManagerV2);

        engine.setFeesManagerV2(inputs.feesManagerV2);
        fees.setFeeConsumer(inputs.marginEngine, true);
    }

    function _applyEnable(WiringInputs memory inputs) internal {
        MarginEngine engine = MarginEngine(inputs.marginEngine);
        engine.setUseFeesManagerV2(true);
    }

    function _verifyPostState(WiringInputs memory inputs, StateSnapshot memory snap) internal view {
        if (inputs.wireConfirmed) {
            if (snap.marginEngineFeesManagerV2 != inputs.feesManagerV2) {
                revert WireDidNotTake(inputs.feesManagerV2, snap.marginEngineFeesManagerV2);
            }
            if (!snap.isFeeConsumer) revert ConsumerNotAuthorized(inputs.marginEngine);
        }

        if (inputs.enableConfirmed) {
            if (!snap.useFeesManagerV2) revert UseFeesManagerV2NotEnabled();
        } else {
            // Hard rule: never enable V2 by default. If we did not request enable, the flag must remain false.
            if (snap.useFeesManagerV2) revert UnexpectedV1Drift();
        }
    }

    function _logInputs(WiringInputs memory inputs) internal view {
        console2.log("FeesManagerV2 option wiring preflight V2D-F");
        console2.log("chainId", block.chainid);
        console2.log("caller (sanitized, no key)", inputs.caller);
        console2.log("MarginEngine", inputs.marginEngine);
        console2.log("FeesManagerV2", inputs.feesManagerV2);
        console2.log("WIRE_FEES_MANAGER_V2_CONFIRM", inputs.wireConfirmed);
        console2.log("ENABLE_FEES_MANAGER_V2_CONFIRM", inputs.enableConfirmed);
    }

    function _logSnapshot(string memory label, StateSnapshot memory snap) internal pure {
        console2.log("State snapshot:", label);
        console2.log(" MarginEngine.owner()", snap.marginEngineOwner);
        console2.log(" MarginEngine.feesManagerV2()", snap.marginEngineFeesManagerV2);
        console2.log(" MarginEngine.useFeesManagerV2()", snap.useFeesManagerV2);
        console2.log(" FeesManagerV2.owner()", snap.feesManagerV2Owner);
        console2.log(" FeesManagerV2.feeRecipient()", snap.feeRecipient);
        console2.log(" FeesManagerV2.rebateFundingAccount()", snap.rebateFundingAccount);
        console2.log(" FeesManagerV2.isFeeConsumer(MarginEngine)", snap.isFeeConsumer);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
