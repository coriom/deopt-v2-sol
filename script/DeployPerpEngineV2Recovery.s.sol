// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {PerpEngineV2} from "../src/perp/PerpEngineV2.sol";

/// @title DeployPerpEngineV2Recovery
/// @notice PERPS_V2_BASE_SEPOLIA_RECOVERY_DEPLOYMENT_FREEZE_V1 §7 —
///         deploy a fresh PerpEngineV2 pointing at the NEW PerpMarketRegistry
///         (deployed by DeployPerpMarketRegistryV2.s.sol) while reusing every
///         other V2 dependency unchanged.
/// @dev
///  Scope: engine deployment + engine-side setter initialization only. This
///  script does NOT rebind PME_V2 / RISK_V2 / FMV2 / InsuranceFund / Vault —
///  those belong to later milestones (V2_REBIND_V1, TIMELOCK_*).
///  Post-deployment the engine is INERT: no matching engine is authorized on
///  it, no risk module downstream on the new engine, no Vault authorization,
///  and the migration state is `OPEN` (pre-seed).
///
///  Reused dependencies (byte-identical to current live wiring):
///    - PME_V2 (matching engine)   = 0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2
///    - RISK_V2 (risk module)      = 0x8C3d9F71cA59B908Fa200546A63ea62F9C932998
///    - CLEARING_V2                = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c
///    - FMV2 (fee manager)         = 0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f
///    - VAULT                      = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3
///    - ORACLE_ROUTER              = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581
///    - InsuranceFund              = 0x009f38440F058d095b61E0E2ee7fAbDF05BE7500
///    - CollateralSeizer           = 0x39F928b959cF58369E7C7a3B925e6cBfFA62B669
///    - Guardian (EOA)             = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27
///
///  Broadcast gate:
///    Default (no confirmation flag): read-only preflight.
///    With `PERP_ENGINE_V2_RECOVERY_DEPLOY_CONFIRM=true`: broadcasts the
///    canonical sequence.
///
///  Required env when broadcasting:
///    - `DEPLOYER_PRIVATE_KEY` (must resolve to expected OWNER)
///    - `PERP_MARKET_REGISTRY_V2_ADDRESS` (address of the NEW PMR from
///      DeployPerpMarketRegistryV2.s.sol; MUST have `getMaxExecutionDeviationBps`
///      selector present)
contract DeployPerpEngineV2Recovery is Script {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant EXPECTED_CHAIN_ID = 84532;
    address internal constant EXPECTED_OWNER = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;

    address internal constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address internal constant ORACLE_ROUTER = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581;

    address internal constant PME_V2 = 0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2;
    address internal constant RISK_V2 = 0x8C3d9F71cA59B908Fa200546A63ea62F9C932998;
    address internal constant CLEARING_V2 = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c;
    address internal constant FMV2 = 0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f;
    address internal constant INSURANCE_FUND = 0x009f38440F058d095b61E0E2ee7fAbDF05BE7500;
    address internal constant COLLATERAL_SEIZER = 0x39F928b959cF58369E7C7a3B925e6cBfFA62B669;
    address internal constant GUARDIAN = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;

    // Selector that must be present on the supplied PMR to prove it is
    // execution-guard-capable (this is the exact selector the deployed
    // OLD PMR lacks).
    bytes4 internal constant PMR_EXEC_GUARD_SELECTOR = 0x4d73d67f;

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error UnexpectedChain(uint256 chainId);
    error DeployerNotOwner(address deployer, address expectedOwner);
    error PmrAddressUnset();
    error PmrHasNoCode(address pmr);
    error PmrMissingExecutionGuardSelector(address pmr);
    error UnexpectedEngineOwner(address deployedOwner, address expected);
    error UnexpectedEngineRegistry(address actual, address expected);
    error UnexpectedEngineVault(address actual, address expected);
    error UnexpectedEngineOracle(address actual, address expected);
    error UnexpectedEngineMatching(address actual, address expected);
    error UnexpectedEngineRisk(address actual, address expected);
    error UnexpectedEngineClearing(address actual, address expected);
    error UnexpectedEngineInsurance(address actual, address expected);
    error UnexpectedEngineSeizer(address actual, address expected);
    error UnexpectedEngineFmv2(address actual, address expected);
    error UnexpectedEngineUseFmv2(bool actual, bool expected);
    error UnexpectedEngineGuardian(address actual, address expected);

    /*//////////////////////////////////////////////////////////////
                                    RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        if (block.chainid != EXPECTED_CHAIN_ID) revert UnexpectedChain(block.chainid);

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        if (deployer != EXPECTED_OWNER) revert DeployerNotOwner(deployer, EXPECTED_OWNER);

        address pmr = vm.envAddress("PERP_MARKET_REGISTRY_V2_ADDRESS");
        if (pmr == address(0)) revert PmrAddressUnset();
        if (pmr.code.length == 0) revert PmrHasNoCode(pmr);
        _requirePmrHasExecutionGuardSelector(pmr);

        bool confirm = vm.envOr("PERP_ENGINE_V2_RECOVERY_DEPLOY_CONFIRM", false);

        _log("PerpEngineV2 recovery deploy preflight");
        _log("chainId", block.chainid);
        _log("deployer", deployer);
        _log("NEW PMR", pmr);
        _log("confirm flag", confirm);

        if (!confirm) {
            console2.log("PERP_ENGINE_V2_RECOVERY_DEPLOY_CONFIRM=false; no broadcast");
            return;
        }

        vm.startBroadcast(deployerPk);

        PerpEngineV2 engine = new PerpEngineV2(deployer, pmr, VAULT, ORACLE_ROUTER);
        _log("deployed PerpEngineV2", address(engine));

        engine.setMatchingEngine(PME_V2);
        engine.setRiskModule(RISK_V2);
        engine.setClearingAccount(CLEARING_V2);
        engine.setInsuranceFund(INSURANCE_FUND);
        engine.setCollateralSeizer(COLLATERAL_SEIZER);
        engine.setFeesManagerV2(FMV2);
        engine.setUseFeesManagerV2(true);
        engine.setGuardian(GUARDIAN);

        vm.stopBroadcast();

        // Post-broadcast readback assertions — every stored pointer must
        // match the intended reused dependency.
        if (engine.owner() != deployer) revert UnexpectedEngineOwner(engine.owner(), deployer);
        if (engine.marketRegistry() != pmr) revert UnexpectedEngineRegistry(engine.marketRegistry(), pmr);
        if (engine.collateralVault() != VAULT) revert UnexpectedEngineVault(engine.collateralVault(), VAULT);
        if (engine.oracle() != ORACLE_ROUTER) revert UnexpectedEngineOracle(engine.oracle(), ORACLE_ROUTER);
        if (engine.matchingEngine() != PME_V2) revert UnexpectedEngineMatching(engine.matchingEngine(), PME_V2);
        if (engine.riskModule() != RISK_V2) revert UnexpectedEngineRisk(engine.riskModule(), RISK_V2);
        if (engine.clearingAccount() != CLEARING_V2) {
            revert UnexpectedEngineClearing(engine.clearingAccount(), CLEARING_V2);
        }
        if (engine.insuranceFund() != INSURANCE_FUND) {
            revert UnexpectedEngineInsurance(engine.insuranceFund(), INSURANCE_FUND);
        }
        if (engine.collateralSeizer() != COLLATERAL_SEIZER) {
            revert UnexpectedEngineSeizer(engine.collateralSeizer(), COLLATERAL_SEIZER);
        }
        if (address(engine.feesManagerV2()) != FMV2) {
            revert UnexpectedEngineFmv2(address(engine.feesManagerV2()), FMV2);
        }
        if (!engine.useFeesManagerV2()) revert UnexpectedEngineUseFmv2(engine.useFeesManagerV2(), true);
        if (engine.guardian() != GUARDIAN) revert UnexpectedEngineGuardian(engine.guardian(), GUARDIAN);

        _log("NEW ENGINE_V2 deployed at", address(engine));
        _log("wired dependencies verified byte-identical to current live wiring");
    }

    /// @dev Prove the target PMR implements the execution-price deviation
    ///      getter by attempting a staticcall that the OLD PMR bytecode
    ///      lacks. Reverting means the caller supplied a non-recovery PMR
    ///      and MUST abort before broadcasting the engine deploy.
    function _requirePmrHasExecutionGuardSelector(address pmr) internal view {
        (bool ok,) = pmr.staticcall(abi.encodeWithSelector(PMR_EXEC_GUARD_SELECTOR, uint256(1)));
        if (!ok) revert PmrMissingExecutionGuardSelector(pmr);
    }

    function _log(string memory label) internal pure {
        console2.log(label);
    }

    function _log(string memory label, uint256 v) internal pure {
        console2.log(label, v);
    }

    function _log(string memory label, address v) internal pure {
        console2.log(label, v);
    }

    function _log(string memory label, bool v) internal pure {
        console2.log(label, v);
    }
}
