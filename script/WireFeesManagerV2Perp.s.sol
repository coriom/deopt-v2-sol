// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";
import {PerpEngine} from "../src/perp/PerpEngine.sol";

/// @title WireFeesManagerV2Perp
/// @notice Safe-by-default V2F-D wiring preflight for the `PerpEngine` -> `FeesManagerV2` link.
/// @dev
///  Modelled byte-for-byte on `script/WireFeesManagerV2Option.s.sol` (V2D-F precedent):
///   - WIRE_FEES_MANAGER_V2_PERP_CONFIRM=true  -> set V2 manager on engine + authorize engine as fee consumer
///   - ENABLE_FEES_MANAGER_V2_PERP_CONFIRM=true -> flip PerpEngine.useFeesManagerV2 from false to true
///
///  Default is safe: no wiring, no enabling, only a sanitized read-only preflight.
///  Enabling V2 fees requires both confirmations; wiring alone never changes engine fee routing,
///  because `useFeesManagerV2` remains false unless explicitly enabled here.
///
///  Required env when WIRE_FEES_MANAGER_V2_PERP_CONFIRM=true:
///    - DEPLOYER_PRIVATE_KEY (PerpEngine + FeesManagerV2 owner)
///    - PERP_ENGINE_ADDRESS
///    - FEES_MANAGER_V2_ADDRESS
contract WireFeesManagerV2Perp is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct WiringInputs {
        address caller;
        address perpEngine;
        address feesManagerV2;
        bool wireConfirmed;
        bool enableConfirmed;
    }

    struct StateSnapshot {
        address perpEngineFeesManagerV2;
        bool useFeesManagerV2;
        bool isFeeConsumer;
        address feeRecipient;
        address rebateFundingAccount;
        address feesManagerV2Owner;
        address perpEngineOwner;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error PerpEngineUnset();
    error FeesManagerV2Unset();
    error NotPerpEngineOwner(address caller, address owner);
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

        if (inputs.enableConfirmed && !inputs.wireConfirmed && before_.perpEngineFeesManagerV2 == address(0)) {
            revert EnableRequiresWire();
        }

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPk);

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
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        inputs.caller = vm.addr(deployerPk);
        inputs.perpEngine = _envAddressOrZero("PERP_ENGINE_ADDRESS");
        inputs.feesManagerV2 = _envAddressOrZero("FEES_MANAGER_V2_ADDRESS");

        inputs.wireConfirmed = vm.envOr("WIRE_FEES_MANAGER_V2_PERP_CONFIRM", false);
        inputs.enableConfirmed = vm.envOr("ENABLE_FEES_MANAGER_V2_PERP_CONFIRM", false);
    }

    function _validateInputs(WiringInputs memory inputs) internal view {
        if (inputs.perpEngine == address(0)) revert PerpEngineUnset();
        if (inputs.feesManagerV2 == address(0)) revert FeesManagerV2Unset();

        if (inputs.perpEngine.code.length == 0) revert PerpEngineUnset();
        if (inputs.feesManagerV2.code.length == 0) revert FeesManagerV2Unset();
    }

    function _snapshot(WiringInputs memory inputs) internal view returns (StateSnapshot memory snap) {
        PerpEngine engine = PerpEngine(inputs.perpEngine);
        FeesManagerV2 fees = FeesManagerV2(inputs.feesManagerV2);

        snap.perpEngineOwner = engine.owner();
        snap.perpEngineFeesManagerV2 = address(engine.feesManagerV2());
        snap.useFeesManagerV2 = engine.useFeesManagerV2();

        snap.feesManagerV2Owner = fees.owner();
        snap.feeRecipient = fees.feeRecipient();
        snap.rebateFundingAccount = fees.rebateFundingAccount();
        snap.isFeeConsumer = fees.isFeeConsumer(inputs.perpEngine);
    }

    function _validatePreconditions(WiringInputs memory inputs, StateSnapshot memory snap) internal pure {
        if (snap.perpEngineOwner != inputs.caller) {
            revert NotPerpEngineOwner(inputs.caller, snap.perpEngineOwner);
        }
        if (snap.feesManagerV2Owner != inputs.caller) {
            revert NotFeesManagerV2Owner(inputs.caller, snap.feesManagerV2Owner);
        }
        if (snap.feeRecipient == address(0)) revert FeeRecipientZero();
        if (snap.rebateFundingAccount == address(0)) revert RebateFundingAccountZero();
    }

    function _applyWire(WiringInputs memory inputs) internal {
        PerpEngine engine = PerpEngine(inputs.perpEngine);
        FeesManagerV2 fees = FeesManagerV2(inputs.feesManagerV2);

        engine.setFeesManagerV2(inputs.feesManagerV2);
        fees.setFeeConsumer(inputs.perpEngine, true);
    }

    function _applyEnable(WiringInputs memory inputs) internal {
        PerpEngine engine = PerpEngine(inputs.perpEngine);
        engine.setUseFeesManagerV2(true);
    }

    function _verifyPostState(WiringInputs memory inputs, StateSnapshot memory snap) internal view {
        if (inputs.wireConfirmed) {
            if (snap.perpEngineFeesManagerV2 != inputs.feesManagerV2) {
                revert WireDidNotTake(inputs.feesManagerV2, snap.perpEngineFeesManagerV2);
            }
            if (!snap.isFeeConsumer) revert ConsumerNotAuthorized(inputs.perpEngine);
        }

        if (inputs.enableConfirmed) {
            if (!snap.useFeesManagerV2) revert UseFeesManagerV2NotEnabled();
        } else {
            // Hard rule: never enable V2 by default. If we did not request enable, the flag must remain false.
            if (snap.useFeesManagerV2) revert UnexpectedV1Drift();
        }
    }

    function _logInputs(WiringInputs memory inputs) internal view {
        console2.log("FeesManagerV2 perp wiring preflight V2F-D");
        console2.log("chainId", block.chainid);
        console2.log("caller (sanitized, no key)", inputs.caller);
        console2.log("PerpEngine", inputs.perpEngine);
        console2.log("FeesManagerV2", inputs.feesManagerV2);
        console2.log("WIRE_FEES_MANAGER_V2_PERP_CONFIRM", inputs.wireConfirmed);
        console2.log("ENABLE_FEES_MANAGER_V2_PERP_CONFIRM", inputs.enableConfirmed);
    }

    function _logSnapshot(string memory label, StateSnapshot memory snap) internal pure {
        console2.log("State snapshot:", label);
        console2.log(" PerpEngine.owner()", snap.perpEngineOwner);
        console2.log(" PerpEngine.feesManagerV2()", snap.perpEngineFeesManagerV2);
        console2.log(" PerpEngine.useFeesManagerV2()", snap.useFeesManagerV2);
        console2.log(" FeesManagerV2.owner()", snap.feesManagerV2Owner);
        console2.log(" FeesManagerV2.feeRecipient()", snap.feeRecipient);
        console2.log(" FeesManagerV2.rebateFundingAccount()", snap.rebateFundingAccount);
        console2.log(" FeesManagerV2.isFeeConsumer(PerpEngine)", snap.isFeeConsumer);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
