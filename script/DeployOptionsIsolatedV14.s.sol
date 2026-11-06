// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {CollateralVault} from "../src/collateral/CollateralVault.sol";
import {OptionProductRegistry} from "../src/OptionProductRegistry.sol";
import {MarginEngine} from "../src/margin/MarginEngine.sol";
import {RiskModule} from "../src/risk/RiskModule.sol";
import {OptionMatchingEngine} from "../src/matching/OptionMatchingEngine.sol";
import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";
import {InsuranceFund} from "../src/core/InsuranceFund.sol";
import {VerifiedOptionSettlementOwner} from "../src/settlement/VerifiedOptionSettlementOwner.sol";

/// @notice V14 deployment candidate only. No trading series or funding is created here.
/// @dev Nine consecutive CREATE transactions make address prediction depend
///      solely on the deployment EOA's fresh pending nonce. Configuration and
///      ownership are Timelock-governed follow-up operations.
contract DeployOptionsIsolatedV14 is Script {
    address internal constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address internal constant GUARDIAN = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address internal constant MUSDC = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address internal constant MWETH = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02;
    address internal constant MWBTC = 0x9D871aC7595E8Da271E866608E5145252047967c;
    address internal constant CHAINLINK_ETH = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    address internal constant CHAINLINK_BTC = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298;
    address internal constant PYTH_CORE = 0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83;
    bytes32 internal constant PYTH_ETH_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 internal constant PYTH_BTC_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;

    function run() external {
        require(block.chainid == 84532, "Base Sepolia only");
        require(vm.envOr("OPTIONS_V14_DEPLOY_ALLOWED", false), "V14 release gate closed");
        require(
            TIMELOCK.code.length > 0 && GUARDIAN.code.length > 0 && MUSDC.code.length > 0 && MWETH.code.length > 0
                && MWBTC.code.length > 0,
            "missing dependency"
        );
        require(
            CHAINLINK_ETH.code.length > 0 && CHAINLINK_BTC.code.length > 0 && PYTH_CORE.code.length > 0,
            "missing oracle"
        );

        address[2] memory underlyings = [MWETH, MWBTC];
        address[2] memory feeds = [CHAINLINK_ETH, CHAINLINK_BTC];
        bytes32[2] memory ids = [PYTH_ETH_ID, PYTH_BTC_ID];

        vm.startBroadcast();
        OracleRouter router = new OracleRouter(TIMELOCK);
        CollateralVault vault = new CollateralVault(TIMELOCK);
        OptionProductRegistry registry = new OptionProductRegistry(TIMELOCK);
        MarginEngine margin = new MarginEngine(TIMELOCK, address(registry), address(vault), address(router));
        RiskModule risk = new RiskModule(TIMELOCK, address(vault), address(registry), address(margin), address(router));
        OptionMatchingEngine matching = new OptionMatchingEngine(TIMELOCK, address(margin), address(registry));
        FeesManagerV2 fees = new FeesManagerV2(TIMELOCK, TIMELOCK);
        InsuranceFund insurance = new InsuranceFund(TIMELOCK, address(vault));
        VerifiedOptionSettlementOwner verifier = new VerifiedOptionSettlementOwner(
            address(registry),
            TIMELOCK,
            GUARDIAN,
            MUSDC,
            PYTH_CORE,
            underlyings,
            feeds,
            ids,
            1_500,
            1_500,
            2 days,
            100,
            100
        );
        vm.stopBroadcast();

        require(address(margin.optionRegistry()) == address(registry), "registry mismatch");
        require(address(margin.collateralVault()) == address(vault), "vault mismatch");
        require(address(matching.optionRegistry()) == address(registry), "matching mismatch");
        require(address(verifier.registry()) == address(registry), "verifier mismatch");
        console2.log("V14_ROUTER", address(router));
        console2.log("V14_VAULT", address(vault));
        console2.log("V14_REGISTRY", address(registry));
        console2.log("V14_MARGIN", address(margin));
        console2.log("V14_RISK", address(risk));
        console2.log("V14_MATCHING", address(matching));
        console2.log("V14_FEES", address(fees));
        console2.log("V14_INSURANCE", address(insurance));
        console2.log("V14_VERIFIER", address(verifier));
    }
}
