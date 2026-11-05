// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {CollateralVault} from "../src/collateral/CollateralVault.sol";
import {OptionProductRegistry} from "../src/OptionProductRegistry.sol";
import {RiskModule} from "../src/risk/RiskModule.sol";
import {MarginEngine} from "../src/margin/MarginEngine.sol";
import {OptionMatchingEngine} from "../src/matching/OptionMatchingEngine.sol";
import {
    ScenarioOptionERC20,
    ScenarioOptionOracle,
    ScenarioOptionInsuranceFund
} from "../test/scenario/options/OptionSettlementFlow.t.sol";

/// @notice Local Anvil only. Never use this script with a public RPC.
contract OptionsLocalAnvilE2E is Script {
    uint256 internal constant OWNER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant BUYER_PK = 0xB0B;
    uint256 internal constant SELLER_PK = 0xCA11;
    uint256 internal constant STRIKE = 2_000 * 1e8;
    uint128 internal constant PREMIUM = 100 * 1e6;

    function run() external {
        require(block.chainid == 31337, "local Anvil only");
        address owner = vm.addr(OWNER_PK);
        address buyer = vm.addr(BUYER_PK);
        address seller = vm.addr(SELLER_PK);

        vm.startBroadcast(OWNER_PK);
        CollateralVault vault = new CollateralVault(owner);
        OptionProductRegistry registry = new OptionProductRegistry(owner);
        ScenarioOptionOracle oracle = new ScenarioOptionOracle();
        MarginEngine engine = new MarginEngine(owner, address(registry), address(vault), address(oracle));
        ScenarioOptionInsuranceFund insurance = new ScenarioOptionInsuranceFund(address(vault));
        ScenarioOptionERC20 usdc = new ScenarioOptionERC20("Mock USDC", "mUSDC", 6);
        ScenarioOptionERC20 weth = new ScenarioOptionERC20("Mock WETH", "mWETH", 18);
        RiskModule risk = new RiskModule(owner, address(vault), address(registry), address(engine), address(oracle));
        OptionMatchingEngine matching = new OptionMatchingEngine(owner, address(engine), address(registry));

        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setMarginEngine(address(engine));
        vault.setAuthorizedEngine(address(insurance), true);
        registry.setSettlementAssetAllowed(address(usdc), true);
        registry.setUnderlyingConfig(
            address(weth),
            OptionProductRegistry.UnderlyingConfig({
                oracle: address(oracle),
                spotShockDownBps: 3_000,
                spotShockUpBps: 3_000,
                volShockDownBps: 0,
                volShockUpBps: 2_000,
                isEnabled: true
            })
        );
        registry.setOptionRiskConfig(
            address(weth),
            OptionProductRegistry.OptionRiskConfig({
                baseMaintenanceMarginPerContract: 10 * 1e6,
                imFactorBps: 12_000,
                oracleDownMmMultiplierBps: 20_000,
                isConfigured: true
            })
        );
        risk.setRiskParams(address(usdc), 10 * 1e6, 12_000);
        risk.syncCollateralTokensFromVault();
        engine.setRiskModule(address(risk));
        engine.syncRiskParamsFromRiskModule();
        engine.setMatchingEngine(address(matching));
        engine.setInsuranceFund(address(insurance));
        matching.setExecutor(owner, true);
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 optionId = registry.createSeries(address(weth), address(usdc), expiry, uint64(STRIKE), true, true);
        oracle.setPrice(address(weth), address(usdc), STRIKE, block.timestamp, true);
        usdc.mint(buyer, 10_000 * 1e6);
        usdc.mint(seller, 10_000 * 1e6);
        payable(buyer).transfer(1 ether);
        payable(seller).transfer(1 ether);
        vm.stopBroadcast();

        vm.startBroadcast(BUYER_PK);
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(address(usdc), 10_000 * 1e6);
        vm.stopBroadcast();

        vm.startBroadcast(SELLER_PK);
        usdc.approve(address(vault), 10_000 * 1e6);
        vault.deposit(address(usdc), 10_000 * 1e6);
        vm.stopBroadcast();

        OptionMatchingEngine.OptionTrade memory trade = OptionMatchingEngine.OptionTrade({
            intentId: keccak256("deopt-local-anvil-e2e-v4"),
            buyer: buyer,
            seller: seller,
            optionId: optionId,
            underlying: address(weth),
            settlementAsset: address(usdc),
            expiry: expiry,
            strike1e8: uint64(STRIKE),
            isCall: true,
            contractSize1e8: uint128(1e8),
            quantity: 1,
            premiumPerContract: PREMIUM,
            buyerIsMaker: true,
            buyerNonce: 0,
            sellerNonce: 0,
            deadline: block.timestamp + 1 hours
        });
        bytes32 digest = matching.hashTrade(trade);
        (uint8 bv, bytes32 br, bytes32 bs) = vm.sign(BUYER_PK, digest);
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(SELLER_PK, digest);
        vm.startBroadcast(OWNER_PK);
        matching.executeTrade(trade, abi.encodePacked(br, bs, bv), abi.encodePacked(sr, ss, sv));
        vm.stopBroadcast();

        require(engine.positions(buyer, optionId).quantity == 1, "buyer position");
        require(engine.positions(seller, optionId).quantity == -1, "seller position");
        console2.log("MATCHING_ENGINE", address(matching));
        console2.log("MARGIN_ENGINE", address(engine));
        console2.log("OPTION_ID", optionId);
        console2.log("BUYER", buyer);
        console2.log("SELLER", seller);
        console2.log("REGISTRY", address(registry));
        console2.log("VAULT", address(vault));
    }
}
