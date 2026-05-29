// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {CollateralVault} from "../src/collateral/CollateralVault.sol";
import {InsuranceFund} from "../src/core/InsuranceFund.sol";
import {PerpEngine} from "../src/perp/PerpEngine.sol";
import {PerpEngineTypes} from "../src/perp/PerpEngineTypes.sol";
import {PerpMarketRegistry} from "../src/perp/PerpMarketRegistry.sol";
import {PerpMatchingEngine} from "../src/matching/PerpMatchingEngine.sol";
import {PerpRiskModule} from "../src/perp/PerpRiskModule.sol";

/// @title RewirePerpEngineV2
/// @notice Safe-by-default V2F-D rewire script that repoints every live PerpEngine dependent at
///         a freshly deployed FeesManagerV2-compatible PerpEngine, but only after the **Strategy A
///         drain invariants** are satisfied on the old engine.
/// @dev
///  V2F-C selected Strategy A — "drain then rewire" — for the live perp state. That means this
///  script must hard-refuse to broadcast unless every live market on the OLD PerpEngine has
///  zero open interest and the engine carries zero residual bad debt. The drain itself is
///  carried out off-script (testnet operators use the engine's existing levers:
///  `setMarketEmergencyCloseOnly`, `setMarketActivationState`, `PerpMatchingEngine.pause`).
///
///  Default (no confirmation flag): reads the before-state of every dependent + the OLD engine
///  drain state and aborts without sending any transaction.
///
///  With `REWIRE_PERP_ENGINE_V2_CONFIRM=true`, the script runs the rewire setters in a
///  deterministic order, then re-reads each dependent and reverts on any mismatch. The new
///  engine's `useFeesManagerV2` must remain `false` through the rewire — defense against
///  accidental V1 → V2 drift.
///
///  Override flag (use with extreme care):
///   - `REWIRE_PERP_ENGINE_V2_ALLOW_NONZERO_STATE=true`
///   - Even with confirm, the Strategy A invariants are enforced unless this flag is set.
///   - This flag exists for explicitly documented emergency scenarios (e.g., abandoned testnet
///     state that operators have agreed to orphan). It must never be set on mainnet without
///     a documented incident response approval.
///
///  Required env when `REWIRE_PERP_ENGINE_V2_CONFIRM=true`:
///    - `DEPLOYER_PRIVATE_KEY` (must equal `owner()` on every dependent below)
///    - `OLD_PERP_ENGINE`
///    - `NEW_PERP_ENGINE`
///    - `COLLATERAL_VAULT`
///    - `PERP_MATCHING_ENGINE`
///    - `PERP_RISK_MODULE`
///    - `INSURANCE_FUND`
contract RewirePerpEngineV2 is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Inputs {
        address caller;
        address oldPerpEngine;
        address newPerpEngine;
        address collateralVault;
        address perpMatchingEngine;
        address perpRiskModule;
        address insuranceFund;
        bool rewireConfirmed;
        bool allowNonzeroOldState;
    }

    struct DrainState {
        uint256 totalMarkets;
        uint256[] marketIds;
        uint256[] longOI;
        uint256[] shortOI;
        uint256 totalResidualBadDebtBase;
        bool oldEngineTradingPaused;
        bool matchingEnginePaused;
    }

    struct Snapshot {
        // OLD/NEW dependent pointers.
        bool vaultAuthorizesOld;
        bool vaultAuthorizesNew;
        address matchingEnginePerpEngine;
        address riskModulePerpEngine;
        bool insuranceAuthorizesOld;
        bool insuranceAuthorizesNew;
        // New-engine self-state invariants.
        bool newEngineUseFeesManagerV2;
        address newEngineFeesManagerV2;
        // Caller authority on each holder.
        address vaultOwner;
        address matchingEngineOwner;
        address riskModuleOwner;
        address insuranceFundOwner;
        address newEngineOwner;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error OldPerpEngineUnset();
    error NewPerpEngineUnset();
    error CollateralVaultUnset();
    error PerpMatchingEngineUnset();
    error PerpRiskModuleUnset();
    error InsuranceFundUnset();
    error NoCodeAt(string name, address target);

    error NotOwnerOf(string holder, address caller, address owner);
    error UnexpectedOldEngine(string holder, address expected, address actual);
    error NewEngineUseFeesManagerV2NotFalse();
    error NewEngineFeesManagerV2NotZero();

    // Strategy A drain invariants.
    error OldEngineMarketHasNonzeroLongOI(uint256 marketId, uint256 longOI);
    error OldEngineMarketHasNonzeroShortOI(uint256 marketId, uint256 shortOI);
    error OldEngineHasResidualBadDebt(uint256 totalResidualBadDebtBase);

    error VaultStillAuthorizesOld();
    error VaultDoesNotAuthorizeNew();
    error MatchingEngineMismatch(address expected, address actual);
    error RiskModuleMismatch(address expected, address actual);
    error InsuranceFundStillAuthorizesOld();
    error InsuranceFundDoesNotAuthorizeNew();
    error UseFeesManagerV2FlippedOn();

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        Inputs memory inputs = _readInputs();
        _validateInputs(inputs);
        _logInputs(inputs);

        // Strategy A invariants are evaluated first because they are the canonical precondition
        // and they only need to read the OLD engine. If the OLD engine is not drained, no
        // downstream check (including NEW-engine V2 self-checks) matters.
        DrainState memory drain = _readDrainState(inputs);
        _logDrain("OLD engine drain state", drain);
        _enforceDrainInvariants(inputs, drain);

        Snapshot memory before_ = _snapshot(inputs);
        _logSnapshot("before", before_);
        _validatePreconditions(inputs, before_);

        if (!inputs.rewireConfirmed) {
            console2.log("REWIRE_PERP_ENGINE_V2_CONFIRM is not set to true; preflight done, no transactions sent.");
            return;
        }

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPk);
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
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        inputs.caller = vm.addr(deployerPk);
        inputs.oldPerpEngine = _envAddressOrZero("OLD_PERP_ENGINE");
        inputs.newPerpEngine = _envAddressOrZero("NEW_PERP_ENGINE");
        inputs.collateralVault = _envAddressOrZero("COLLATERAL_VAULT");
        inputs.perpMatchingEngine = _envAddressOrZero("PERP_MATCHING_ENGINE");
        inputs.perpRiskModule = _envAddressOrZero("PERP_RISK_MODULE");
        inputs.insuranceFund = _envAddressOrZero("INSURANCE_FUND");
        inputs.rewireConfirmed = vm.envOr("REWIRE_PERP_ENGINE_V2_CONFIRM", false);
        inputs.allowNonzeroOldState = vm.envOr("REWIRE_PERP_ENGINE_V2_ALLOW_NONZERO_STATE", false);
    }

    function _validateInputs(Inputs memory inputs) internal view {
        if (inputs.oldPerpEngine == address(0)) revert OldPerpEngineUnset();
        if (inputs.newPerpEngine == address(0)) revert NewPerpEngineUnset();
        if (inputs.collateralVault == address(0)) revert CollateralVaultUnset();
        if (inputs.perpMatchingEngine == address(0)) revert PerpMatchingEngineUnset();
        if (inputs.perpRiskModule == address(0)) revert PerpRiskModuleUnset();
        if (inputs.insuranceFund == address(0)) revert InsuranceFundUnset();

        _requireCode("OLD_PERP_ENGINE", inputs.oldPerpEngine);
        _requireCode("NEW_PERP_ENGINE", inputs.newPerpEngine);
        _requireCode("COLLATERAL_VAULT", inputs.collateralVault);
        _requireCode("PERP_MATCHING_ENGINE", inputs.perpMatchingEngine);
        _requireCode("PERP_RISK_MODULE", inputs.perpRiskModule);
        _requireCode("INSURANCE_FUND", inputs.insuranceFund);
    }

    function _readDrainState(Inputs memory inputs) internal view returns (DrainState memory drain) {
        PerpEngine oldEngine = PerpEngine(inputs.oldPerpEngine);

        // Pull market enumeration from the PerpMarketRegistry the OLD engine points at, so
        // we always check the exact market set the OLD engine knows about.
        address registry = oldEngine.marketRegistry();
        PerpMarketRegistry reg = PerpMarketRegistry(registry);

        uint256[] memory marketIds = reg.getAllMarketIds();
        drain.totalMarkets = marketIds.length;
        drain.marketIds = marketIds;
        drain.longOI = new uint256[](marketIds.length);
        drain.shortOI = new uint256[](marketIds.length);

        for (uint256 i = 0; i < marketIds.length; i++) {
            uint256 marketId = marketIds[i];
            PerpEngineTypes.MarketState memory s = oldEngine.marketState(marketId);
            drain.longOI[i] = s.longOpenInterest1e8;
            drain.shortOI[i] = s.shortOpenInterest1e8;
        }

        drain.totalResidualBadDebtBase = oldEngine.totalResidualBadDebtBase();
        drain.oldEngineTradingPaused = oldEngine.tradingPaused();

        // Matching pause is informational only; not part of the hard invariant set.
        try PerpMatchingEngine(inputs.perpMatchingEngine).paused() returns (bool p) {
            drain.matchingEnginePaused = p;
        } catch {}
    }

    function _snapshot(Inputs memory inputs) internal view returns (Snapshot memory s) {
        CollateralVault vault = CollateralVault(inputs.collateralVault);
        PerpMatchingEngine matching = PerpMatchingEngine(inputs.perpMatchingEngine);
        PerpRiskModule risk = PerpRiskModule(inputs.perpRiskModule);
        InsuranceFund insurance = InsuranceFund(inputs.insuranceFund);
        PerpEngine newEngine = PerpEngine(inputs.newPerpEngine);

        s.vaultAuthorizesOld = vault.isEngineAuthorized(inputs.oldPerpEngine);
        s.vaultAuthorizesNew = vault.isEngineAuthorized(inputs.newPerpEngine);
        s.matchingEnginePerpEngine = address(matching.perpEngine());
        s.riskModulePerpEngine = address(risk.perpEngine());
        s.insuranceAuthorizesOld = insurance.isBackstopCaller(inputs.oldPerpEngine);
        s.insuranceAuthorizesNew = insurance.isBackstopCaller(inputs.newPerpEngine);

        s.newEngineUseFeesManagerV2 = newEngine.useFeesManagerV2();
        s.newEngineFeesManagerV2 = address(newEngine.feesManagerV2());

        s.vaultOwner = vault.owner();
        s.matchingEngineOwner = matching.owner();
        s.riskModuleOwner = risk.owner();
        s.insuranceFundOwner = insurance.owner();
        s.newEngineOwner = newEngine.owner();
    }

    function _validatePreconditions(Inputs memory inputs, Snapshot memory s) internal pure {
        // Caller authority — every holder's owner must match the broadcaster.
        if (s.vaultOwner != inputs.caller) revert NotOwnerOf("CollateralVault", inputs.caller, s.vaultOwner);
        if (s.matchingEngineOwner != inputs.caller) {
            revert NotOwnerOf("PerpMatchingEngine", inputs.caller, s.matchingEngineOwner);
        }
        if (s.riskModuleOwner != inputs.caller) {
            revert NotOwnerOf("PerpRiskModule", inputs.caller, s.riskModuleOwner);
        }
        if (s.insuranceFundOwner != inputs.caller) {
            revert NotOwnerOf("InsuranceFund", inputs.caller, s.insuranceFundOwner);
        }

        // Every dependent must currently point at the OLD PerpEngine.
        if (s.matchingEnginePerpEngine != inputs.oldPerpEngine) {
            revert UnexpectedOldEngine("PerpMatchingEngine", inputs.oldPerpEngine, s.matchingEnginePerpEngine);
        }
        if (s.riskModulePerpEngine != inputs.oldPerpEngine) {
            revert UnexpectedOldEngine("PerpRiskModule", inputs.oldPerpEngine, s.riskModulePerpEngine);
        }

        // V2 must still be disabled on the new engine before we rewire.
        if (s.newEngineUseFeesManagerV2) revert NewEngineUseFeesManagerV2NotFalse();
        if (s.newEngineFeesManagerV2 != address(0)) revert NewEngineFeesManagerV2NotZero();
    }

    function _enforceDrainInvariants(Inputs memory inputs, DrainState memory drain) internal pure {
        if (inputs.allowNonzeroOldState) {
            // Operator has explicitly accepted the risk of orphaning live state. Skip the
            // invariants but the override is logged elsewhere for review.
            return;
        }

        for (uint256 i = 0; i < drain.marketIds.length; i++) {
            uint256 marketId = drain.marketIds[i];
            if (drain.longOI[i] != 0) {
                revert OldEngineMarketHasNonzeroLongOI(marketId, drain.longOI[i]);
            }
            if (drain.shortOI[i] != 0) {
                revert OldEngineMarketHasNonzeroShortOI(marketId, drain.shortOI[i]);
            }
        }

        if (drain.totalResidualBadDebtBase != 0) {
            revert OldEngineHasResidualBadDebt(drain.totalResidualBadDebtBase);
        }
    }

    function _applyRewire(Inputs memory inputs) internal {
        CollateralVault vault = CollateralVault(inputs.collateralVault);
        // The vault uses an explicit authorized-engine allowlist for the perp engine. We
        // revoke OLD, then add NEW, mirroring the WireCore pattern.
        vault.setAuthorizedEngine(inputs.oldPerpEngine, false);
        vault.setAuthorizedEngine(inputs.newPerpEngine, true);

        PerpMatchingEngine(inputs.perpMatchingEngine).setEngine(inputs.newPerpEngine);
        PerpRiskModule(inputs.perpRiskModule).setPerpEngine(inputs.newPerpEngine);

        InsuranceFund insurance = InsuranceFund(inputs.insuranceFund);
        insurance.setBackstopCaller(inputs.oldPerpEngine, false);
        insurance.setBackstopCaller(inputs.newPerpEngine, true);
    }

    function _verifyPostState(Inputs memory inputs, Snapshot memory s) internal pure {
        if (s.vaultAuthorizesOld) revert VaultStillAuthorizesOld();
        if (!s.vaultAuthorizesNew) revert VaultDoesNotAuthorizeNew();

        if (s.matchingEnginePerpEngine != inputs.newPerpEngine) {
            revert MatchingEngineMismatch(inputs.newPerpEngine, s.matchingEnginePerpEngine);
        }
        if (s.riskModulePerpEngine != inputs.newPerpEngine) {
            revert RiskModuleMismatch(inputs.newPerpEngine, s.riskModulePerpEngine);
        }

        if (s.insuranceAuthorizesOld) revert InsuranceFundStillAuthorizesOld();
        if (!s.insuranceAuthorizesNew) revert InsuranceFundDoesNotAuthorizeNew();

        // V2 must STILL be disabled on the new engine after the rewire.
        if (s.newEngineUseFeesManagerV2) revert UseFeesManagerV2FlippedOn();
    }

    function _logInputs(Inputs memory inputs) internal view {
        console2.log("PerpEngineV2 rewire preflight V2F-D");
        console2.log("chainId", block.chainid);
        console2.log("caller (sanitized, no key)", inputs.caller);
        console2.log("OLD_PERP_ENGINE", inputs.oldPerpEngine);
        console2.log("NEW_PERP_ENGINE", inputs.newPerpEngine);
        console2.log("COLLATERAL_VAULT", inputs.collateralVault);
        console2.log("PERP_MATCHING_ENGINE", inputs.perpMatchingEngine);
        console2.log("PERP_RISK_MODULE", inputs.perpRiskModule);
        console2.log("INSURANCE_FUND", inputs.insuranceFund);
        console2.log("REWIRE_PERP_ENGINE_V2_CONFIRM", inputs.rewireConfirmed);
        console2.log("REWIRE_PERP_ENGINE_V2_ALLOW_NONZERO_STATE", inputs.allowNonzeroOldState);
    }

    function _logDrain(string memory label, DrainState memory d) internal pure {
        console2.log("Drain snapshot:", label);
        console2.log(" OLD.tradingPaused()", d.oldEngineTradingPaused);
        console2.log(" PerpMatchingEngine.paused()", d.matchingEnginePaused);
        console2.log(" OLD.totalResidualBadDebtBase()", d.totalResidualBadDebtBase);
        console2.log(" markets enumerated by registry", d.totalMarkets);
        for (uint256 i = 0; i < d.marketIds.length; i++) {
            console2.log(" marketId", d.marketIds[i]);
            console2.log("   longOpenInterest1e8", d.longOI[i]);
            console2.log("   shortOpenInterest1e8", d.shortOI[i]);
        }
    }

    function _logSnapshot(string memory label, Snapshot memory s) internal pure {
        console2.log("State snapshot:", label);
        console2.log(" Vault.isEngineAuthorized(OLD)", s.vaultAuthorizesOld);
        console2.log(" Vault.isEngineAuthorized(NEW)", s.vaultAuthorizesNew);
        console2.log(" PerpMatchingEngine.perpEngine()", s.matchingEnginePerpEngine);
        console2.log(" PerpRiskModule.perpEngine()", s.riskModulePerpEngine);
        console2.log(" InsuranceFund.isBackstopCaller(OLD)", s.insuranceAuthorizesOld);
        console2.log(" InsuranceFund.isBackstopCaller(NEW)", s.insuranceAuthorizesNew);
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
