// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {CollateralVault} from "../src/collateral/CollateralVault.sol";
import {OptionProductRegistry} from "../src/OptionProductRegistry.sol";
import {RiskModule} from "../src/risk/RiskModule.sol";
import {MarginEngine} from "../src/margin/MarginEngine.sol";
import {OptionMatchingEngine} from "../src/matching/OptionMatchingEngine.sol";
import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";
import {InsuranceFund} from "../src/core/InsuranceFund.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {V14LocalPriceSource} from "./LocalOptionsPriceSourceV14.sol";
import {
    VerifiedOptionSettlementOwner,
    IHistoricalChainlinkFeed,
    IHistoricalPyth
} from "../src/settlement/VerifiedOptionSettlementOwner.sol";
import {ScenarioOptionERC20, ScenarioOptionOracle} from "../test/scenario/options/OptionSettlementFlow.t.sol";

/// @dev Deterministic local-only feed. Production settlement uses real historical feeds.
contract LocalHistoricalChainlinkFeed is IHistoricalChainlinkFeed {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }
    mapping(uint80 => Round) public rounds;

    function setRound(uint80 id, int256 answer, uint256 updatedAt) external {
        rounds[id] = Round({answer: answer, updatedAt: updatedAt});
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory round = rounds[id];
        require(round.updatedAt != 0, "missing local round");
        return (id, round.answer, round.updatedAt, round.updatedAt, id);
    }
}

/// @dev Fail-closed local placeholder. Authentic Pyth Core is covered by fork tests.
contract LocalPythUnavailable is IHistoricalPyth {
    function getUpdateFee(bytes[] calldata) external pure returns (uint256) {
        return 0;
    }

    function parsePriceFeedUpdatesUnique(bytes[] calldata, bytes32[] calldata, uint64, uint64)
        external
        payable
        returns (PriceFeed[] memory)
    {
        revert("Pyth unavailable in local E2E");
    }
}

/// @notice Local Anvil only. Never use this script with a public RPC.
contract OptionsLocalAnvilE2E is Script {
    uint256 internal constant OWNER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant BUYER_PK = 0xB0B;
    uint256 internal constant SELLER_PK = 0xCA11;
    uint256 internal constant STRIKE = 2_000 * 1e8;
    uint128 internal constant PREMIUM = 100 * 1e6;

    function run() external {
        require(block.chainid == 31337 || block.chainid == 84532, "local Anvil chain only");
        // Base Sepolia's chain ID is allowed only when the RPC proves it is
        // Anvil. A public Base Sepolia endpoint cannot answer this method.
        require(vm.rpc("anvil_nodeInfo", "[]").length != 0, "Anvil RPC required");
        address owner = vm.addr(OWNER_PK);
        address buyer = vm.addr(BUYER_PK);
        address seller = vm.addr(SELLER_PK);
        bool verifiedSettlement = vm.envOr("OPTIONS_V13_VERIFIED_SETTLEMENT", false);
        bool v14Router = vm.envOr("OPTIONS_V14_ROUTER", false);
        bool dualRegistry = vm.envOr("OPTIONS_V16_DUAL_REGISTRY", false);
        require(!dualRegistry || verifiedSettlement, "dual Registry requires dedicated verified stack");
        require(!v14Router || verifiedSettlement, "V14 router requires verified settlement");

        vm.startBroadcast(OWNER_PK);
        CollateralVault vault = new CollateralVault(owner);
        OptionProductRegistry registry = new OptionProductRegistry(owner);
        ScenarioOptionOracle oracle;
        OracleRouter router;
        V14LocalPriceSource primary;
        V14LocalPriceSource secondary;
        address riskOracle;
        if (v14Router) {
            primary = new V14LocalPriceSource();
            secondary = new V14LocalPriceSource();
            router = new OracleRouter(owner);
            riskOracle = address(router);
        } else {
            oracle = new ScenarioOptionOracle();
            riskOracle = address(oracle);
        }
        MarginEngine engine = new MarginEngine(owner, address(registry), address(vault), riskOracle);
        InsuranceFund insurance = new InsuranceFund(owner, address(vault));
        ScenarioOptionERC20 usdc = new ScenarioOptionERC20("Mock USDC", "mUSDC", 6);
        ScenarioOptionERC20 weth = new ScenarioOptionERC20("Mock WETH", "mWETH", 18);
        RiskModule risk = new RiskModule(owner, address(vault), address(registry), address(engine), riskOracle);
        OptionMatchingEngine matching = new OptionMatchingEngine(owner, address(engine), address(registry));
        FeesManagerV2 feesManagerV2 = new FeesManagerV2(owner, owner);
        CollateralVault legacyVault;
        OptionProductRegistry legacyRegistry;
        MarginEngine legacyEngine;
        OptionMatchingEngine legacyMatching;
        FeesManagerV2 legacyFees;

        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setMarginEngine(address(engine));
        vault.setAuthorizedEngine(address(insurance), true);
        insurance.setTokenAllowed(address(usdc), true);
        insurance.setBackstopCaller(address(engine), true);
        registry.setSettlementAssetAllowed(address(usdc), true);
        registry.setUnderlyingConfig(
            address(weth),
            OptionProductRegistry.UnderlyingConfig({
                oracle: riskOracle,
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
        if (verifiedSettlement) vault.setRiskModule(address(risk));
        engine.setRiskModule(address(risk));
        engine.syncRiskParamsFromRiskModule();
        engine.setMatchingEngine(address(matching));
        engine.setInsuranceFund(address(insurance));
        matching.setExecutor(owner, true);
        feesManagerV2.setRebateFundingAccount(owner);
        feesManagerV2.setFeeConsumer(address(engine), true);
        engine.setFeesManagerV2(address(feesManagerV2));
        engine.setUseFeesManagerV2(true);
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 optionId;
        VerifiedOptionSettlementOwner verifier;
        LocalHistoricalChainlinkFeed historicalFeed;
        if (verifiedSettlement) {
            historicalFeed = new LocalHistoricalChainlinkFeed();
            LocalPythUnavailable unavailablePyth = new LocalPythUnavailable();
            address[2] memory underlyings = [address(weth), address(0x1234)];
            address[2] memory feeds = [address(historicalFeed), address(historicalFeed)];
            bytes32[2] memory pythIds = [bytes32(uint256(1)), bytes32(uint256(2))];
            verifier = new VerifiedOptionSettlementOwner(
                address(registry),
                owner,
                owner,
                address(usdc),
                address(unavailablePyth),
                underlyings,
                feeds,
                pythIds,
                1_500,
                1_500,
                2 days,
                100,
                100
            );
            registry.pauseCreation();
            registry.pauseSettlement();
            registry.transferOwnership(address(verifier));
            verifier.acceptRegistryOwnership();
            optionId = verifier.createInactiveCallSeries(address(weth), expiry, uint64(STRIKE));
            verifier.executeRegistryAdmin(abi.encodeCall(registry.setSeriesActive, (optionId, true)));
            verifier.executeRegistryAdmin(abi.encodeCall(registry.unpauseSettlement, ()));
        } else {
            optionId = registry.createSeries(address(weth), address(usdc), expiry, uint64(STRIKE), true, true);
        }
        if (v14Router) {
            primary.set(STRIKE, block.timestamp, true);
            secondary.set(STRIKE, block.timestamp, true);
            router.setMaxOracleDelay(1_500);
            router.setFeed(address(weth), address(usdc), primary, secondary, 1_500, 100, true);
        } else {
            oracle.setPrice(address(weth), address(usdc), STRIKE, block.timestamp, true);
        }
        if (dualRegistry) {
            // Candidate closed-beta limits; effective only in this local run.
            vault.setTokenDepositCap(address(usdc), 2_000 * 1e6);
            engine.setSeriesShortOpenInterestCap(optionId, 1);
            // Separate local legacy stack with the same assets, expiry and
            // raw optionId. Its vault and economic obligations remain distinct.
            legacyVault = new CollateralVault(owner);
            legacyRegistry = new OptionProductRegistry(owner);
            ScenarioOptionOracle legacyOracle = new ScenarioOptionOracle();
            legacyEngine = new MarginEngine(owner, address(legacyRegistry), address(legacyVault), address(legacyOracle));
            RiskModule legacyRisk = new RiskModule(owner, address(legacyVault), address(legacyRegistry), address(legacyEngine), address(legacyOracle));
            legacyMatching = new OptionMatchingEngine(owner, address(legacyEngine), address(legacyRegistry));
            legacyFees = new FeesManagerV2(owner, owner);
            legacyVault.setCollateralToken(address(usdc), true, 6, 10_000);
            legacyVault.setMarginEngine(address(legacyEngine));
            legacyVault.setRiskModule(address(legacyRisk));
            legacyRegistry.setSettlementAssetAllowed(address(usdc), true);
            legacyRegistry.setUnderlyingConfig(address(weth), OptionProductRegistry.UnderlyingConfig({
                oracle: address(legacyOracle), spotShockDownBps: 3_000, spotShockUpBps: 3_000,
                volShockDownBps: 0, volShockUpBps: 2_000, isEnabled: true
            }));
            legacyRegistry.setOptionRiskConfig(address(weth), OptionProductRegistry.OptionRiskConfig({
                baseMaintenanceMarginPerContract: 10 * 1e6, imFactorBps: 12_000,
                oracleDownMmMultiplierBps: 20_000, isConfigured: true
            }));
            legacyRisk.setRiskParams(address(usdc), 10 * 1e6, 12_000);
            legacyRisk.syncCollateralTokensFromVault();
            legacyEngine.setRiskModule(address(legacyRisk));
            legacyEngine.syncRiskParamsFromRiskModule();
            legacyEngine.setMatchingEngine(address(legacyMatching));
            legacyMatching.setExecutor(owner, true);
            legacyFees.setFeeConsumer(address(legacyEngine), true);
            legacyEngine.setFeesManagerV2(address(legacyFees));
            legacyEngine.setUseFeesManagerV2(true);
            legacyOracle.setPrice(address(weth), address(usdc), STRIKE, block.timestamp, true);
            uint256 legacyOptionId = legacyRegistry.createSeries(address(weth), address(usdc), expiry, uint64(STRIKE), true, true);
            require(legacyOptionId == optionId, "raw optionId collision required");
            require(address(legacyVault) != address(vault), "Vault isolation required");
            require(address(legacyRegistry) != address(registry), "Registry isolation required");
        }
        usdc.mint(buyer, uint256(dualRegistry ? 3_000 : 10_000) * 1e6);
        usdc.mint(seller, uint256(dualRegistry ? 3_000 : 10_000) * 1e6);
        payable(buyer).transfer(1 ether);
        payable(seller).transfer(1 ether);
        vm.stopBroadcast();

        vm.startBroadcast(BUYER_PK);
        usdc.approve(address(vault), dualRegistry ? 1_001 * 1e6 : 10_000 * 1e6);
        vault.deposit(address(usdc), dualRegistry ? 1_000 * 1e6 : 10_000 * 1e6);
        if (dualRegistry) {
            usdc.approve(address(legacyVault), 2_000 * 1e6);
            legacyVault.deposit(address(usdc), 2_000 * 1e6);
        }
        vm.stopBroadcast();

        vm.startBroadcast(SELLER_PK);
        usdc.approve(address(vault), dualRegistry ? 1_001 * 1e6 : 10_000 * 1e6);
        vault.deposit(address(usdc), dualRegistry ? 1_000 * 1e6 : 10_000 * 1e6);
        if (dualRegistry) {
            usdc.approve(address(legacyVault), 2_000 * 1e6);
            legacyVault.deposit(address(usdc), 2_000 * 1e6);
        }
        vm.stopBroadcast();

        if (dualRegistry) {
            OptionMatchingEngine.OptionTrade memory legacyTrade = OptionMatchingEngine.OptionTrade({
                intentId: keccak256("deopt-v16-legacy-position"), buyer: buyer, seller: seller,
                optionId: optionId, underlying: address(weth), settlementAsset: address(usdc),
                expiry: expiry, strike1e8: uint64(STRIKE), isCall: true,
                contractSize1e8: uint128(1e8), quantity: 1,
                premiumPerContract: PREMIUM, buyerIsMaker: true,
                buyerNonce: 0, sellerNonce: 0, deadline: block.timestamp + 1 hours
            });
            bytes32 legacyDigest = legacyMatching.hashTrade(legacyTrade);
            (uint8 lbv, bytes32 lbr, bytes32 lbs) = vm.sign(BUYER_PK, legacyDigest);
            (uint8 lsv, bytes32 lsr, bytes32 lss) = vm.sign(SELLER_PK, legacyDigest);
            vm.startBroadcast(OWNER_PK);
            legacyMatching.executeTrade(legacyTrade, abi.encodePacked(lbr, lbs, lbv), abi.encodePacked(lsr, lss, lsv));
            legacyTrade.intentId = keccak256("deopt-v17-legacy-second-fill");
            legacyTrade.buyerNonce = 1;
            legacyTrade.sellerNonce = 1;
            legacyDigest = legacyMatching.hashTrade(legacyTrade);
            (lbv, lbr, lbs) = vm.sign(BUYER_PK, legacyDigest);
            (lsv, lsr, lss) = vm.sign(SELLER_PK, legacyDigest);
            legacyMatching.executeTrade(legacyTrade, abi.encodePacked(lbr, lbs, lbv), abi.encodePacked(lsr, lss, lsv));
            vm.stopBroadcast();
            require(legacyEngine.positions(buyer, optionId).quantity == 2, "legacy buyer position");
            require(legacyEngine.positions(seller, optionId).quantity == -2, "legacy seller position");
            require(engine.positions(buyer, optionId).quantity == 0, "dedicated buyer must start empty");
        }

        console2.log("MATCHING_ENGINE", address(matching));
        console2.log("MARGIN_ENGINE", address(engine));
        console2.log("OPTION_ID", optionId);
        console2.log("BUYER", buyer);
        console2.log("SELLER", seller);
        console2.log("REGISTRY", address(registry));
        console2.log("VAULT", address(vault));
        console2.log("FEES_MANAGER_V2", address(feesManagerV2));
        if (dualRegistry) {
            console2.log("LEGACY_REGISTRY", address(legacyRegistry));
            console2.log("LEGACY_VAULT", address(legacyVault));
            console2.log("LEGACY_MARGIN_ENGINE", address(legacyEngine));
            console2.log("LEGACY_MATCHING_ENGINE", address(legacyMatching));
            console2.log("LEGACY_FEES_MANAGER_V2", address(legacyFees));
        }
        if (v14Router) {
            console2.log("V14_ROUTER", address(router));
            console2.log("V14_PRIMARY", address(primary));
            console2.log("V14_SECONDARY", address(secondary));
            require(address(engine.oracle()) == address(router), "engine router wiring");
            require(address(risk.oracle()) == address(router), "risk router wiring");
        }
        if (verifiedSettlement) {
            console2.log("VERIFIED_SETTLEMENT_OWNER", address(verifier));
            console2.log("LOCAL_HISTORICAL_FEED", address(historicalFeed));
            require(registry.owner() == address(verifier), "verifier does not own dedicated registry");
            require(vault.marginEngine() == address(engine), "dedicated vault engine wiring");
            require(address(vault.riskModule()) == address(risk), "dedicated vault risk wiring");
            require(address(engine.optionRegistry()) == address(registry), "dedicated registry wiring");
            require(address(engine.collateralVault()) == address(vault), "dedicated vault wiring");
            require(address(matching.optionRegistry()) == address(registry), "matching registry wiring");
            require(address(matching.marginEngine()) == address(engine), "matching engine wiring");
            require(vault.isAuthorizedEngine(address(insurance)), "insurance authorization");
        }
        if (vm.envOr("OPTIONS_V4_DEPLOY_ONLY", false)) return;

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
    }
}
