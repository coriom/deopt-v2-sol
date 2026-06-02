// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {CollateralVault} from "../src/collateral/CollateralVault.sol";
import {InsuranceFund} from "../src/core/InsuranceFund.sol";
import {RiskGovernor} from "../src/gouvernance/RiskGovernor.sol";
import {MarginEngine} from "../src/margin/MarginEngine.sol";
import {MatchingEngine} from "../src/matching/MatchingEngine.sol";
import {OptionMatchingEngine} from "../src/matching/OptionMatchingEngine.sol";
import {RiskModule} from "../src/risk/RiskModule.sol";

/// @title RewireMarginEngineV2
/// @notice Safe-by-default V2D-L rewire script that repoints every live MarginEngine dependent at
///         a freshly deployed V2D-D-compatible MarginEngine, without touching FeesManagerV2 and
///         without enabling `useFeesManagerV2`.
/// @dev
///  Default (no confirmation flag): reads the before-state of every dependent and aborts without
///  sending any transaction. With `REWIRE_MARGIN_ENGINE_V2_CONFIRM=true`, the script runs the six
///  rewire calls in a deterministic order, then re-reads each dependent and reverts on any
///  mismatch. The script asserts after every confirmed mutation that the new MarginEngine's V2
///  toggle remains `false` — defense against accidental V1 → V2 drift.
contract RewireMarginEngineV2 is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Inputs {
        address caller;
        address oldMarginEngine;
        address newMarginEngine;
        address collateralVault;
        address riskModule;
        address matchingEngine;
        address optionMatchingEngine;
        address insuranceFund;
        address riskGovernor;
        bool rewireConfirmed;
    }

    struct Snapshot {
        // External holders.
        address vaultMarginEngine;
        bool vaultAuthorizesOld;
        bool vaultAuthorizesNew;
        address riskModuleMarginEngine;
        address matchingEngineMarginEngine;
        address optionMatchingEngineMarginEngine;
        bool insuranceAuthorizesOld;
        bool insuranceAuthorizesNew;
        address riskGovernorMarginEngine;
        // New engine self-state we must keep invariant.
        bool newEngineUseFeesManagerV2;
        address newEngineFeesManagerV2;
        // Caller authority over each holder.
        address vaultOwner;
        address riskModuleOwner;
        address matchingEngineOwner;
        address optionMatchingEngineOwner;
        address insuranceFundOwner;
        address riskGovernorOwner;
        address newEngineOwner;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error OldMarginEngineUnset();
    error NewMarginEngineUnset();
    error CollateralVaultUnset();
    error RiskModuleUnset();
    error MatchingEngineUnset();
    error OptionMatchingEngineUnset();
    error InsuranceFundUnset();
    error RiskGovernorUnset();
    error NoCodeAt(string name, address target);

    error UnexpectedOldEngine(string holder, address expected, address actual);
    error NotOwnerOf(string holder, address caller, address owner);
    error NewEngineUseFeesManagerV2NotFalse();
    error NewEngineFeesManagerV2NotZero();

    error VaultMarginEngineMismatch(address expected, address actual);
    error VaultStillAuthorizesOld();
    error VaultDoesNotAuthorizeNew();
    error RiskModuleMismatch(address expected, address actual);
    error MatchingEngineMismatch(address expected, address actual);
    error OptionMatchingEngineMismatch(address expected, address actual);
    error InsuranceFundStillAuthorizesOld();
    error InsuranceFundDoesNotAuthorizeNew();
    error RiskGovernorMismatch(address expected, address actual);
    error UseFeesManagerV2FlippedOn();

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

        if (!inputs.rewireConfirmed) {
            console2.log("REWIRE_MARGIN_ENGINE_V2_CONFIRM is not set to true; preflight done, no transactions sent.");
            return;
        }

        // V2G-P keystore mode: PK is optional. When unset Foundry uses
        // `--account <keystore>` / `--sender <addr>` from the CLI.
        uint256 deployerPk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        if (deployerPk != 0) {
            vm.startBroadcast(deployerPk);
        } else {
            vm.startBroadcast();
        }
        _applyRewire(inputs);
        vm.stopBroadcast();

        Snapshot memory after_ = _snapshot(inputs);
        _logSnapshot("after", after_);
        _verifyPostState(inputs, after_);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _readInputs() internal view returns (Inputs memory inputs) {
        // V2G-P keystore mode: derive caller from PK when set, otherwise from
        // `DEPLOYER_ADDRESS` env (defaulting to the canonical V2 deployer EOA).
        uint256 deployerPk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address envDeployer = vm.envOr("DEPLOYER_ADDRESS", address(0xc35F7A8A103A9A4464adfaa76B9B514093D23C27));
        if (deployerPk != 0) {
            inputs.caller = vm.addr(deployerPk);
        } else {
            inputs.caller = envDeployer;
        }
        inputs.oldMarginEngine = _envAddressOrZero("OLD_MARGIN_ENGINE");
        inputs.newMarginEngine = _envAddressOrZero("NEW_MARGIN_ENGINE");
        inputs.collateralVault = _envAddressOrZero("COLLATERAL_VAULT");
        inputs.riskModule = _envAddressOrZero("RISK_MODULE");
        inputs.matchingEngine = _envAddressOrZero("MATCHING_ENGINE");
        inputs.optionMatchingEngine = _envAddressOrZero("OPTION_MATCHING_ENGINE");
        inputs.insuranceFund = _envAddressOrZero("INSURANCE_FUND");
        inputs.riskGovernor = _envAddressOrZero("RISK_GOVERNOR");
        inputs.rewireConfirmed = vm.envOr("REWIRE_MARGIN_ENGINE_V2_CONFIRM", false);
    }

    function _validateInputs(Inputs memory inputs) internal view {
        if (inputs.oldMarginEngine == address(0)) revert OldMarginEngineUnset();
        if (inputs.newMarginEngine == address(0)) revert NewMarginEngineUnset();
        if (inputs.collateralVault == address(0)) revert CollateralVaultUnset();
        if (inputs.riskModule == address(0)) revert RiskModuleUnset();
        if (inputs.matchingEngine == address(0)) revert MatchingEngineUnset();
        if (inputs.optionMatchingEngine == address(0)) revert OptionMatchingEngineUnset();
        if (inputs.insuranceFund == address(0)) revert InsuranceFundUnset();
        if (inputs.riskGovernor == address(0)) revert RiskGovernorUnset();

        _requireCode("OLD_MARGIN_ENGINE", inputs.oldMarginEngine);
        _requireCode("NEW_MARGIN_ENGINE", inputs.newMarginEngine);
        _requireCode("COLLATERAL_VAULT", inputs.collateralVault);
        _requireCode("RISK_MODULE", inputs.riskModule);
        _requireCode("MATCHING_ENGINE", inputs.matchingEngine);
        _requireCode("OPTION_MATCHING_ENGINE", inputs.optionMatchingEngine);
        _requireCode("INSURANCE_FUND", inputs.insuranceFund);
        _requireCode("RISK_GOVERNOR", inputs.riskGovernor);
    }

    function _snapshot(Inputs memory inputs) internal view returns (Snapshot memory s) {
        CollateralVault vault = CollateralVault(inputs.collateralVault);
        RiskModule rm = RiskModule(inputs.riskModule);
        MatchingEngine me = MatchingEngine(inputs.matchingEngine);
        OptionMatchingEngine ome = OptionMatchingEngine(inputs.optionMatchingEngine);
        InsuranceFund insurance = InsuranceFund(inputs.insuranceFund);
        RiskGovernor rg = RiskGovernor(inputs.riskGovernor);
        MarginEngine newEngine = MarginEngine(inputs.newMarginEngine);

        s.vaultMarginEngine = vault.marginEngine();
        s.vaultAuthorizesOld = vault.isAuthorizedEngine(inputs.oldMarginEngine);
        s.vaultAuthorizesNew = vault.isAuthorizedEngine(inputs.newMarginEngine);
        s.riskModuleMarginEngine = address(rm.marginEngine());
        s.matchingEngineMarginEngine = address(me.marginEngine());
        s.optionMatchingEngineMarginEngine = address(ome.marginEngine());
        s.insuranceAuthorizesOld = insurance.isBackstopCaller(inputs.oldMarginEngine);
        s.insuranceAuthorizesNew = insurance.isBackstopCaller(inputs.newMarginEngine);
        s.riskGovernorMarginEngine = rg.marginEngine();
        s.newEngineUseFeesManagerV2 = newEngine.useFeesManagerV2();
        s.newEngineFeesManagerV2 = address(newEngine.feesManagerV2());

        s.vaultOwner = vault.owner();
        s.riskModuleOwner = rm.owner();
        s.matchingEngineOwner = me.owner();
        s.optionMatchingEngineOwner = ome.owner();
        s.insuranceFundOwner = insurance.owner();
        s.riskGovernorOwner = rg.owner();
        s.newEngineOwner = newEngine.owner();
    }

    function _validatePreconditions(Inputs memory inputs, Snapshot memory s) internal pure {
        // Caller authority — every holder's owner must match the broadcaster.
        if (s.vaultOwner != inputs.caller) revert NotOwnerOf("CollateralVault", inputs.caller, s.vaultOwner);
        if (s.riskModuleOwner != inputs.caller) revert NotOwnerOf("RiskModule", inputs.caller, s.riskModuleOwner);
        if (s.matchingEngineOwner != inputs.caller) {
            revert NotOwnerOf("MatchingEngine", inputs.caller, s.matchingEngineOwner);
        }
        if (s.optionMatchingEngineOwner != inputs.caller) {
            revert NotOwnerOf("OptionMatchingEngine", inputs.caller, s.optionMatchingEngineOwner);
        }
        if (s.insuranceFundOwner != inputs.caller) {
            revert NotOwnerOf("InsuranceFund", inputs.caller, s.insuranceFundOwner);
        }
        if (s.riskGovernorOwner != inputs.caller) {
            revert NotOwnerOf("RiskGovernor", inputs.caller, s.riskGovernorOwner);
        }

        // Every dependent must currently point at the OLD MarginEngine. If anything diverges, abort —
        // the operator must investigate before any rewire is safe.
        if (s.vaultMarginEngine != inputs.oldMarginEngine) {
            revert UnexpectedOldEngine("CollateralVault", inputs.oldMarginEngine, s.vaultMarginEngine);
        }
        if (s.riskModuleMarginEngine != inputs.oldMarginEngine) {
            revert UnexpectedOldEngine("RiskModule", inputs.oldMarginEngine, s.riskModuleMarginEngine);
        }
        if (s.matchingEngineMarginEngine != inputs.oldMarginEngine) {
            revert UnexpectedOldEngine("MatchingEngine", inputs.oldMarginEngine, s.matchingEngineMarginEngine);
        }
        if (s.optionMatchingEngineMarginEngine != inputs.oldMarginEngine) {
            revert UnexpectedOldEngine(
                "OptionMatchingEngine", inputs.oldMarginEngine, s.optionMatchingEngineMarginEngine
            );
        }
        if (s.riskGovernorMarginEngine != inputs.oldMarginEngine) {
            revert UnexpectedOldEngine("RiskGovernor", inputs.oldMarginEngine, s.riskGovernorMarginEngine);
        }

        // V2 must still be disabled on the new engine before we rewire.
        if (s.newEngineUseFeesManagerV2) revert NewEngineUseFeesManagerV2NotFalse();
        if (s.newEngineFeesManagerV2 != address(0)) revert NewEngineFeesManagerV2NotZero();
    }

    function _applyRewire(Inputs memory inputs) internal {
        CollateralVault vault = CollateralVault(inputs.collateralVault);
        vault.setMarginEngine(inputs.newMarginEngine);
        // Revoke OLD from the explicit allowlist so it can no longer move vault funds.
        // (The implicit `engine == marginEngine` check in CollateralVault now points at NEW.)
        vault.setAuthorizedEngine(inputs.oldMarginEngine, false);
        // Authorize NEW in the explicit allowlist too, mirroring the WireCore pattern.
        vault.setAuthorizedEngine(inputs.newMarginEngine, true);

        RiskModule(inputs.riskModule).setMarginEngine(inputs.newMarginEngine);
        MatchingEngine(inputs.matchingEngine).setMarginEngine(inputs.newMarginEngine);
        OptionMatchingEngine(inputs.optionMatchingEngine).setEngine(inputs.newMarginEngine);

        InsuranceFund insurance = InsuranceFund(inputs.insuranceFund);
        insurance.setBackstopCaller(inputs.oldMarginEngine, false);
        insurance.setBackstopCaller(inputs.newMarginEngine, true);

        RiskGovernor(inputs.riskGovernor).setMarginEngineTarget(inputs.newMarginEngine);
    }

    function _verifyPostState(Inputs memory inputs, Snapshot memory s) internal pure {
        if (s.vaultMarginEngine != inputs.newMarginEngine) {
            revert VaultMarginEngineMismatch(inputs.newMarginEngine, s.vaultMarginEngine);
        }
        if (s.vaultAuthorizesOld) revert VaultStillAuthorizesOld();
        if (!s.vaultAuthorizesNew) revert VaultDoesNotAuthorizeNew();

        if (s.riskModuleMarginEngine != inputs.newMarginEngine) {
            revert RiskModuleMismatch(inputs.newMarginEngine, s.riskModuleMarginEngine);
        }
        if (s.matchingEngineMarginEngine != inputs.newMarginEngine) {
            revert MatchingEngineMismatch(inputs.newMarginEngine, s.matchingEngineMarginEngine);
        }
        if (s.optionMatchingEngineMarginEngine != inputs.newMarginEngine) {
            revert OptionMatchingEngineMismatch(inputs.newMarginEngine, s.optionMatchingEngineMarginEngine);
        }

        if (s.insuranceAuthorizesOld) revert InsuranceFundStillAuthorizesOld();
        if (!s.insuranceAuthorizesNew) revert InsuranceFundDoesNotAuthorizeNew();
        if (s.riskGovernorMarginEngine != inputs.newMarginEngine) {
            revert RiskGovernorMismatch(inputs.newMarginEngine, s.riskGovernorMarginEngine);
        }

        // V2 must STILL be disabled on the new engine after the rewire.
        if (s.newEngineUseFeesManagerV2) revert UseFeesManagerV2FlippedOn();
    }

    function _logInputs(Inputs memory inputs) internal view {
        console2.log("MarginEngineV2 rewire preflight V2D-L");
        console2.log("chainId", block.chainid);
        console2.log("caller (sanitized, no key)", inputs.caller);
        console2.log("OLD_MARGIN_ENGINE", inputs.oldMarginEngine);
        console2.log("NEW_MARGIN_ENGINE", inputs.newMarginEngine);
        console2.log("COLLATERAL_VAULT", inputs.collateralVault);
        console2.log("RISK_MODULE", inputs.riskModule);
        console2.log("MATCHING_ENGINE", inputs.matchingEngine);
        console2.log("OPTION_MATCHING_ENGINE", inputs.optionMatchingEngine);
        console2.log("INSURANCE_FUND", inputs.insuranceFund);
        console2.log("RISK_GOVERNOR", inputs.riskGovernor);
        console2.log("REWIRE_MARGIN_ENGINE_V2_CONFIRM", inputs.rewireConfirmed);
    }

    function _logSnapshot(string memory label, Snapshot memory s) internal pure {
        console2.log("State snapshot:", label);
        console2.log(" Vault.marginEngine()", s.vaultMarginEngine);
        console2.log(" Vault.isAuthorizedEngine(OLD)", s.vaultAuthorizesOld);
        console2.log(" Vault.isAuthorizedEngine(NEW)", s.vaultAuthorizesNew);
        console2.log(" RiskModule.marginEngine()", s.riskModuleMarginEngine);
        console2.log(" MatchingEngine.marginEngine()", s.matchingEngineMarginEngine);
        console2.log(" OptionMatchingEngine.marginEngine()", s.optionMatchingEngineMarginEngine);
        console2.log(" InsuranceFund.isBackstopCaller(OLD)", s.insuranceAuthorizesOld);
        console2.log(" InsuranceFund.isBackstopCaller(NEW)", s.insuranceAuthorizesNew);
        console2.log(" RiskGovernor.marginEngine()", s.riskGovernorMarginEngine);
        console2.log(" NEW.useFeesManagerV2()", s.newEngineUseFeesManagerV2);
        console2.log(" NEW.feesManagerV2()", s.newEngineFeesManagerV2);
    }

    function _requireCode(string memory name, address target) internal view {
        if (target.code.length == 0) revert NoCodeAt(name, target);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
