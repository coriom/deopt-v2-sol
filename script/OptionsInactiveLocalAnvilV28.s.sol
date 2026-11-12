// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {OptionProductRegistry} from "../src/OptionProductRegistry.sol";
import {CoveredCallMarginEngine} from "../src/experimental/CoveredCallMarginEngine.sol";
import {OptionMatchingEngine} from "../src/matching/OptionMatchingEngine.sol";
import {CoveredLocalTokenV18, CoveredLocalOracleV18} from "./OptionsCoveredLocalAnvilV18.s.sol";

/// @dev Local-only owner permits one atomic create/deactivate receipt. The
/// production Safe/Timelock path is separately proved by the V27 fork suite.
contract LocalInactiveSeriesOwnerV28 {
    function createLegacy(OptionProductRegistry registry, address weth, address usdc, uint64 expiry, uint64 strike)
        external
        returns (uint256)
    {
        return registry.createSeries(weth, usdc, expiry, strike, true, true);
    }

    function configure(OptionProductRegistry registry, address weth, address usdc, address oracle) external {
        registry.setSettlementAssetAllowed(usdc, true);
        registry.setUnderlyingConfig(weth, OptionProductRegistry.UnderlyingConfig(oracle, 3_000, 3_000, 0, 2_000, true));
    }

    function createAndDeactivate(
        OptionProductRegistry registry,
        address weth,
        address usdc,
        uint64 expiry,
        uint64 strike
    ) external returns (uint256 optionId) {
        optionId = registry.createSeries(weth, usdc, expiry, strike, true, true);
        registry.setSeriesActive(optionId, false);
        registry.pause();
    }

    function pauseMatcher(OptionMatchingEngine matcher) external {
        matcher.pause();
    }
}

/// @notice Disposable local fixture. Never submit this script to a public RPC.
contract OptionsInactiveLocalAnvilV28 is Script {
    uint256 private constant OWNER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        require(block.chainid == 84532, "local chain ID required");
        require(vm.rpc("anvil_nodeInfo", "[]").length != 0, "Anvil RPC required");
        vm.startBroadcast(OWNER_PK);
        CoveredLocalTokenV18 weth = new CoveredLocalTokenV18("mWETH", 18);
        CoveredLocalTokenV18 usdc = new CoveredLocalTokenV18("mUSDC", 6);
        CoveredLocalOracleV18 oracle = new CoveredLocalOracleV18();
        LocalInactiveSeriesOwnerV28 owner = new LocalInactiveSeriesOwnerV28();
        OptionProductRegistry legacy = new OptionProductRegistry(address(owner));
        OptionProductRegistry physical = new OptionProductRegistry(address(owner));
        owner.configure(legacy, address(weth), address(usdc), address(oracle));
        owner.configure(physical, address(weth), address(usdc), address(oracle));
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint64 strike = 2_100e8;
        // Same raw optionId in both Registries, deliberately.
        uint256 legacyId = owner.createLegacy(legacy, address(weth), address(usdc), expiry, strike);
        uint256 physicalId;
        if (!vm.envOr("OPTIONS_V28_DEPLOY_ONLY", false)) {
            physicalId = owner.createAndDeactivate(physical, address(weth), address(usdc), expiry, strike);
            require(legacyId == physicalId, "raw ID collision required");
        }
        CoveredCallMarginEngine engine =
            new CoveredCallMarginEngine(address(owner), address(physical), 0, address(oracle), 1_500, 48 hours);
        OptionMatchingEngine matcher = new OptionMatchingEngine(address(owner), address(engine), address(physical));
        owner.pauseMatcher(matcher);
        vm.stopBroadcast();
        console2.log("V28_PHYSICAL_REGISTRY", address(physical));
        console2.log("V28_LEGACY_REGISTRY", address(legacy));
        console2.log("V28_ENGINE", address(engine));
        console2.log("V28_MATCHER", address(matcher));
        console2.log("V28_OPTION_ID", physicalId);
        console2.log("V28_LEGACY_ID", legacyId);
        console2.log("V28_OWNER", address(owner));
        console2.log("V28_WETH", address(weth));
        console2.log("V28_USDC", address(usdc));
        console2.log("V28_EXPIRY", expiry);
    }
}
