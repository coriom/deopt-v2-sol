// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {InsuranceFund} from "../../src/core/InsuranceFund.sol";
import {IOracle} from "../../src/oracle/IOracle.sol";
import {OracleRouter} from "../../src/oracle/OracleRouter.sol";
import {MockPriceSource} from "../../src/oracle/MockPriceSource.sol";
import {IPriceSource} from "../../src/oracle/IPriceSource.sol";
import {RiskModule} from "../../src/risk/RiskModule.sol";
import {CollateralSeizer} from "../../src/liquidation/CollateralSeizer.sol";
import {FeesManagerV2} from "../../src/fees/FeesManagerV2.sol";
import {PerpMarketRegistry} from "../../src/perp/PerpMarketRegistry.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";
import {PerpEngineTypes} from "../../src/perp/PerpEngineTypes.sol";
import {PerpRiskModule} from "../../src/perp/PerpRiskModule.sol";
import {PerpClearingAccountV2} from "../../src/perp/PerpClearingAccountV2.sol";
import {PerpMatchingEngineV2} from "../../src/matching/PerpMatchingEngineV2.sol";
import {IPerpEngineTrade} from "../../src/matching/IPerpEngineTrade.sol";

contract ReplacementToken is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract ReplacementOracle is IOracle {
    uint256 public updatedAt;
    uint256 public price1e8 = 2500e8;

    constructor() {
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 timestamp) external {
        updatedAt = timestamp;
    }

    function setPrice(uint256 price) external {
        price1e8 = price;
        updatedAt = block.timestamp;
    }

    function getPrice(address, address) external view returns (uint256, uint256) {
        return (price1e8, updatedAt);
    }

    function getPriceSafe(address, address) external view returns (uint256, uint256, bool) {
        return (price1e8, updatedAt, true);
    }
}

/// @notice Local-only replacement topology. The named Safe is a test actor, not a live signer.
contract PerpsV2ReplacementTopologyTest is Test {
    address internal constant SAFE = address(0x5afe);
    address internal constant DEPLOYER = address(0xd3);
    address internal constant EXECUTOR = 0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8;
    bytes32 internal constant SNAPSHOT = 0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d;

    ProtocolTimelock internal timelock;
    CollateralVault internal vault;
    ReplacementOracle internal oracle;
    ReplacementToken internal usdc;
    RiskModule internal legacyCollateralRisk;
    PerpClearingAccountV2 internal clearing;
    InsuranceFund internal insurance;

    PerpMarketRegistry internal pmr;
    FeesManagerV2 internal fees;
    CollateralSeizer internal seizer;
    PerpEngineV2 internal engine;
    PerpRiskModule internal risk;
    PerpMatchingEngineV2 internal pme;

    function setUp() public {
        vm.warp(1_789_715_700);
        timelock = new ProtocolTimelock(SAFE, SAFE, 1 days);
        oracle = new ReplacementOracle();
        usdc = new ReplacementToken();
        vault = new CollateralVault(address(timelock));
        insurance = new InsuranceFund(address(timelock), address(vault));
        clearing = new PerpClearingAccountV2(address(vault));
        legacyCollateralRisk =
            new RiskModule(address(timelock), address(vault), address(0x101), address(0x102), address(oracle));

        // D1-D6 are deliberately deployed by an EOA that owns none of them.
        vm.startPrank(DEPLOYER);
        pmr = new PerpMarketRegistry(address(timelock));
        fees = new FeesManagerV2(address(timelock), address(timelock));
        seizer = new CollateralSeizer(address(timelock), address(vault), address(oracle), address(legacyCollateralRisk));
        engine = new PerpEngineV2(address(timelock), address(pmr), address(vault), address(oracle));
        risk = new PerpRiskModule(address(timelock), address(vault), address(engine), address(oracle), address(usdc));
        pme = new PerpMatchingEngineV2(address(timelock), address(engine));
        vm.stopPrank();

        vm.startPrank(address(timelock));
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        legacyCollateralRisk.setRiskParams(address(usdc), 1, 10_000);
        pmr.setSettlementAssetAllowed(address(usdc), true);
        _createMarkets();
        pmr.setMaxExecutionDeviationBps(1, 100);
        pmr.setMaxExecutionDeviationBps(2, 100);

        engine.setMatchingEngine(address(pme));
        engine.setRiskModule(address(risk));
        engine.setCollateralSeizer(address(seizer));
        engine.setFeesManagerV2(address(fees));
        engine.setUseFeesManagerV2(true);
        engine.setClearingAccount(address(clearing));
        engine.setInsuranceFund(address(insurance));
        fees.setFeeConsumer(address(engine), true);

        // Constructor grants the owner executor; governance removes routine execution.
        pme.setExecutor(address(timelock), false);
        pme.setExecutor(EXECUTOR, true);
        pme.setGuardian(SAFE);
        pme.pause();

        pmr.setGuardian(SAFE);
        engine.setGuardian(SAFE);
        risk.setGuardian(SAFE);
        risk.setMaxOracleDelay(600);
        engine.setEmergencyModes(true, true, true, true);
        pmr.setEmergencyModes(true, true);
        pmr.pause();
        vm.stopPrank();

        usdc.mint(address(this), 1_000_000_000);
        usdc.approve(address(clearing), 1_000_000_000);
        clearing.fundClearing(address(usdc), 1_000_000_000);
    }

    function _createMarkets() internal {
        pmr.createMarket(
            address(0x201),
            address(usdc),
            address(oracle),
            bytes32("ETH-PERP"),
            PerpMarketRegistry.RiskConfig(1000, 750, 500, 10_000_000_000, 50_000_000_000, true),
            PerpMarketRegistry.LiquidationConfig(5000, 100, 50, 60),
            PerpMarketRegistry.FundingConfig(false, 0, 0, 0, 0, 0)
        );
        pmr.createMarket(
            address(0x202),
            address(usdc),
            address(oracle),
            bytes32("BTC-PERP"),
            PerpMarketRegistry.RiskConfig(1200, 800, 400, 1_000_000_000, 10_000_000_000, true),
            PerpMarketRegistry.LiquidationConfig(5000, 80, 50, 60),
            PerpMarketRegistry.FundingConfig(false, 0, 0, 0, 0, 0)
        );
    }

    function testSixDirectOwnersAndWiring() public view {
        address owner = address(timelock);
        assertEq(pmr.owner(), owner);
        assertEq(pmr.pendingOwner(), address(0));
        assertEq(fees.owner(), owner);
        assertEq(seizer.owner(), owner);
        assertEq(seizer.pendingOwner(), address(0));
        assertEq(engine.owner(), owner);
        assertEq(engine.pendingOwner(), address(0));
        assertEq(risk.owner(), owner);
        assertEq(risk.pendingOwner(), address(0));
        assertEq(pme.owner(), owner);
        assertEq(pme.pendingOwner(), address(0));
        assertEq(engine.marketRegistry(), address(pmr));
        assertEq(engine.collateralVault(), address(vault));
        assertEq(engine.oracle(), address(oracle));
        assertEq(engine.riskModule(), address(risk));
        assertEq(engine.matchingEngine(), address(pme));
        assertEq(address(engine.feesManagerV2()), address(fees));
        assertEq(engine.collateralSeizer(), address(seizer));
        assertEq(address(risk.perpEngine()), address(engine));
        assertEq(address(pme.perpEngine()), address(engine));
        assertEq(risk.guardian(), SAFE);
        assertEq(address(seizer.riskModule()), address(legacyCollateralRisk));
        assertTrue(pme.paused());
        assertTrue(engine.tradingPaused());
        assertTrue(pmr.paused());
        assertFalse(pme.isExecutor(owner));
        assertTrue(pme.isExecutor(EXECUTOR));
    }

    function testDeterministicFixtureReplacementAddresses() public {
        emit log_named_address("replacement_pmr", address(pmr));
        emit log_named_address("replacement_fees", address(fees));
        emit log_named_address("replacement_seizer", address(seizer));
        emit log_named_address("replacement_engine", address(engine));
        emit log_named_address("replacement_risk", address(risk));
        emit log_named_address("replacement_pme", address(pme));
        emit log_named_bytes32("replacement_pmr_runtime", keccak256(address(pmr).code));
        emit log_named_bytes32("replacement_fees_runtime", keccak256(address(fees).code));
        emit log_named_bytes32("replacement_seizer_runtime", keccak256(address(seizer).code));
        emit log_named_bytes32("replacement_engine_runtime", keccak256(address(engine).code));
        emit log_named_bytes32("replacement_risk_runtime", keccak256(address(risk).code));
        emit log_named_bytes32("replacement_pme_runtime", keccak256(address(pme).code));
    }

    function testLegacyFeeLiabilityNotCopied() public {
        FeesManagerV2 legacyFees = new FeesManagerV2(address(timelock), address(timelock));
        bytes32 leaf = legacyFees.hashTierLeaf(
            address(this), 1, 10, 100, 0, uint64(block.timestamp), uint64(block.timestamp + 1 days)
        );
        vm.startPrank(address(timelock));
        legacyFees.fundRebateBudget(address(usdc), 999_977);
        legacyFees.setMerkleRoot(leaf, uint64(block.timestamp), uint64(block.timestamp + 1 days));
        vm.stopPrank();
        uint256 custodyBefore = usdc.balanceOf(address(vault));
        legacyFees.claimTier(
            address(this), 1, 10, 100, 0, uint64(block.timestamp), uint64(block.timestamp + 1 days), new bytes32[](0)
        );
        assertEq(legacyFees.rebateBudget(address(usdc)), 999_977);
        assertEq(legacyFees.currentTier(address(this)), 1);
        assertEq(fees.rebateBudget(address(usdc)), 0);
        assertEq(fees.merkleRoot(), bytes32(0));
        assertEq(fees.protocolFeeVault(), address(0));
        vm.expectRevert(FeesManagerV2.NoMerkleRoot.selector);
        fees.claimTier(address(this), 0, 0, 0, 0, 0, 0, new bytes32[](0));
        assertEq(usdc.balanceOf(address(vault)), custodyBefore);
    }

    function testGuardianCanTightenButCannotClearMarketCloseOnly() public {
        vm.prank(SAFE);
        engine.setMarketEmergencyCloseOnly(1, true);
        assertTrue(engine.marketEmergencyCloseOnly(1));
        vm.prank(SAFE);
        vm.expectRevert();
        engine.setMarketEmergencyCloseOnly(1, false);
        vm.prank(address(timelock));
        engine.setMarketEmergencyCloseOnly(1, false);
        assertFalse(engine.marketEmergencyCloseOnly(1));
    }

    function testRiskAndPmeGuardiansCannotReleaseMaintenance() public {
        assertTrue(pme.paused());
        vm.prank(SAFE);
        vm.expectRevert();
        pme.unpause();
        vm.prank(SAFE);
        risk.pause();
        assertTrue(risk.paused());
        vm.prank(SAFE);
        vm.expectRevert();
        risk.unpause();
        vm.prank(EXECUTOR);
        vm.expectRevert();
        risk.unpause();
        vm.prank(address(timelock));
        risk.unpause();
        assertFalse(risk.paused());
    }

    function testPmrCanonicalParameterTupleEquivalence() public view {
        assertEq(pmr.totalMarkets(), 2);
        assertEq(pmr.nextMarketId(), 3);
        assertEq(pmr.marketAt(0), 1);
        assertEq(pmr.marketAt(1), 2);
        assertTrue(pmr.isSettlementAssetAllowed(address(usdc)));
        PerpMarketRegistry.RiskConfig memory r = pmr.getRiskConfig(1);
        assertEq(r.initialMarginBps, 1000);
        assertEq(r.maintenanceMarginBps, 750);
        assertEq(r.liquidationPenaltyBps, 500);
        assertEq(r.maxPositionSize1e8, 10_000_000_000);
        assertEq(r.maxOpenInterest1e8, 50_000_000_000);
        assertTrue(r.reduceOnlyDuringCloseOnly);
        PerpMarketRegistry.LiquidationConfig memory l = pmr.getLiquidationConfig(1);
        assertEq(l.closeFactorBps, 5000);
        assertEq(l.priceSpreadBps, 100);
        assertEq(l.minImprovementBps, 50);
        assertEq(l.oracleMaxDelay, 60);
        PerpMarketRegistry.FundingConfig memory f = pmr.getFundingConfig(1);
        assertFalse(f.isEnabled);
        assertEq(f.fundingInterval, 0);
        assertEq(f.maxFundingRateBps, 0);
        assertEq(f.maxSkewFundingBps, 0);
        assertEq(f.oracleClampBps, 0);
        assertEq(f.impactMidMaxDelay, 0);
        assertEq(pmr.getMaxExecutionDeviationBps(1), 100);
        r = pmr.getRiskConfig(2);
        assertEq(r.initialMarginBps, 1200);
        assertEq(r.maintenanceMarginBps, 800);
        assertEq(r.liquidationPenaltyBps, 400);
        assertEq(r.maxPositionSize1e8, 1_000_000_000);
        assertEq(r.maxOpenInterest1e8, 10_000_000_000);
        assertTrue(r.reduceOnlyDuringCloseOnly);
        l = pmr.getLiquidationConfig(2);
        assertEq(l.closeFactorBps, 5000);
        assertEq(l.priceSpreadBps, 80);
        assertEq(l.minImprovementBps, 50);
        assertEq(l.oracleMaxDelay, 60);
        f = pmr.getFundingConfig(2);
        assertFalse(f.isEnabled);
        assertEq(f.fundingInterval, 0);
        assertEq(f.maxFundingRateBps, 0);
        assertEq(f.maxSkewFundingBps, 0);
        assertEq(f.oracleClampBps, 0);
        assertEq(f.impactMidMaxDelay, 0);
        assertEq(pmr.getMaxExecutionDeviationBps(2), 100);
    }

    function testMigrationReplayLeavesSharedVaultUntouched() public {
        uint256 ledgerBefore = vault.balances(address(clearing), address(usdc));
        uint256 custodyBefore = usdc.balanceOf(address(vault));
        assertEq(ledgerBefore, 1_000_000_000);
        assertEq(custodyBefore, 1_000_000_000);

        address[6] memory traders = [
            address(0x290bD12C93E467Bf51c51f5273D35bdDb19e9274),
            address(0x475Fe397FA56884952D350aa9EE1c3946964BC0C),
            address(0x66858286fEEA78a05eA093673EA1535E0A52002d),
            address(0x77cA9DD6cCce2D692FB23877a2db7178807b0020),
            address(0x8B94A83D1AD3bD2337b1886E7962CA8E0bba9A34),
            address(0xff287410852B9328437eaC353720e5476bC5F837)
        ];
        int256[6] memory sizes = [int256(1000), -2, -1_000_000, -1000, 2, 1_000_000];
        int256[6] memory notionals = [int256(3_000_000), -6000, -2_468_310_000, -3_000_000, 6000, 2_468_310_000];
        vm.startPrank(address(timelock));
        for (uint256 i; i < 6; i++) {
            engine.adminSeedPosition(traders[i], 1, sizes[i], notionals[i], 0);
        }
        engine.adminSeedMarketFunding(1, 0, 1_789_715_546);
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("MigrationPositionAlreadySeeded(address,uint256)")), traders[0], 1)
        );
        engine.adminSeedPosition(traders[0], 1, sizes[0], notionals[0], 0);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("MigrationMarketFundingAlreadySeeded(uint256)")), 1));
        engine.adminSeedMarketFunding(1, 0, 1_789_715_546);
        vm.stopPrank();
        for (uint256 i; i < 6; i++) {
            PerpEngineTypes.Position memory p = engine.positions(traders[i], 1);
            assertEq(p.size1e8, sizes[i]);
            assertEq(p.openNotional1e8, notionals[i]);
            assertEq(p.lastCumulativeFundingRate1e18, 0);
            assertEq(engine.getTraderMarketsLength(traders[i]), 1);
        }
        PerpEngineTypes.MarketState memory market = engine.marketState(1);
        assertEq(market.longOpenInterest1e8, 1_001_002);
        assertEq(market.shortOpenInterest1e8, 1_001_002);
        assertEq(market.cumulativeFundingRate1e18, 0);
        assertEq(market.lastFundingTimestamp, 1_789_715_546);
        market = engine.marketState(2);
        assertEq(market.longOpenInterest1e8, 0);
        assertEq(market.shortOpenInterest1e8, 0);
        assertEq(market.cumulativeFundingRate1e18, 0);
        assertEq(market.lastFundingTimestamp, 0);
        assertEq(engine.totalResidualBadDebtBase(), 0);
        assertEq(vault.balances(address(clearing), address(usdc)), ledgerBefore);
        assertEq(usdc.balanceOf(address(vault)), custodyBefore);
        vm.prank(address(timelock));
        engine.sealMigration(SNAPSHOT);
        assertEq(engine.migrationSnapshotHash(), SNAPSHOT);
        assertEq(uint8(engine.migrationState()), 1);
        assertEq(vault.balances(address(clearing), address(usdc)), ledgerBefore);
        assertEq(usdc.balanceOf(address(vault)), custodyBefore);
    }

    function testSafeCannotReleaseButTimelockCanAfterDeployerLoss() public {
        vm.prank(SAFE);
        vm.expectRevert();
        engine.setEmergencyModes(false, true, true, true);
        vm.prank(DEPLOYER);
        vm.expectRevert();
        engine.setEmergencyModes(false, false, false, false);
        // Real timelock queue/execute path, without deployer authority.
        bytes memory data = abi.encodeWithSignature("setEmergencyModes(bool,bool,bool,bool)", false, true, true, true);
        uint256 eta = block.timestamp + 1 days;
        vm.prank(SAFE);
        timelock.queueTransaction(address(engine), 0, data, eta);
        vm.warp(eta);
        vm.prank(SAFE);
        timelock.executeTransaction(address(engine), 0, data, eta);
        assertFalse(engine.tradingPaused());
        assertTrue(engine.fundingPaused());
    }

    function testDualVaultInsuranceAuthorizationRequiresGovernanceAndClosedEngine() public {
        PerpEngineV2 historical = new PerpEngineV2(address(timelock), address(pmr), address(vault), address(oracle));
        vm.startPrank(address(timelock));
        historical.setEmergencyModes(true, true, true, true);
        vault.setAuthorizedEngine(address(historical), true);
        insurance.setBackstopCaller(address(historical), true);
        vault.setAuthorizedEngine(address(engine), true);
        insurance.setBackstopCaller(address(engine), true);
        vm.stopPrank();
        assertTrue(vault.isAuthorizedEngine(address(historical)));
        assertTrue(vault.isAuthorizedEngine(address(engine)));
        assertTrue(insurance.isBackstopCaller(address(historical)));
        assertTrue(insurance.isBackstopCaller(address(engine)));
        assertTrue(historical.tradingPaused());
        assertTrue(historical.liquidationPaused());
        assertTrue(historical.fundingPaused());
        assertTrue(historical.collateralOpsPaused());
        assertTrue(pme.paused());
        assertTrue(engine.tradingPaused());
        assertTrue(engine.liquidationPaused());
        assertTrue(engine.fundingPaused());
        assertTrue(engine.collateralOpsPaused());
        vm.prank(SAFE);
        vm.expectRevert();
        vault.setAuthorizedEngine(address(historical), false);
        vm.prank(DEPLOYER);
        vm.expectRevert();
        insurance.setBackstopCaller(address(historical), false);
        vm.startPrank(address(timelock));
        vault.setAuthorizedEngine(address(historical), false);
        insurance.setBackstopCaller(address(historical), false);
        vm.stopPrank();
        assertFalse(vault.isAuthorizedEngine(address(historical)));
        assertFalse(insurance.isBackstopCaller(address(historical)));
        assertTrue(vault.isAuthorizedEngine(address(engine)));
        assertTrue(insurance.isBackstopCaller(address(engine)));
    }

    function testFundingRequiresSealAndOwnerControlledMaintenanceRelease() public {
        vm.prank(address(timelock));
        engine.unpauseFunding();
        vm.expectRevert(bytes4(keccak256("MigrationNotSealed()")));
        engine.updateFunding(2);
        vm.prank(SAFE);
        engine.pauseFunding();
        vm.prank(address(timelock));
        engine.sealMigration(SNAPSHOT);
        vm.expectRevert(PerpEngineTypes.FundingPaused.selector);
        engine.updateFunding(2);
        vm.prank(SAFE);
        vm.expectRevert(PerpEngineTypes.NotAuthorized.selector);
        engine.unpauseFunding();
        vm.prank(address(timelock));
        engine.unpauseFunding();
        uint256 custodyBefore = usdc.balanceOf(address(vault));
        engine.updateFunding(2);
        assertEq(engine.marketState(2).lastFundingTimestamp, block.timestamp);
        assertEq(usdc.balanceOf(address(vault)), custodyBefore);
    }

    function testRiskFreshness600RejectsOtherwiseAvailableStaleQuote() public {
        ReplacementToken secondary = new ReplacementToken();
        vm.prank(address(timelock));
        vault.setCollateralToken(address(secondary), true, 6, 10_000);
        secondary.mint(address(this), 1_000);
        secondary.approve(address(vault), 1_000);
        vault.deposit(address(secondary), 1_000);
        assertEq(risk.maxOracleDelay(), 600);
        assertEq(risk.computeCollateralEquity(address(this)), 2_500_000);
        vm.warp(block.timestamp + 601);
        (uint256 quotedPrice,) = oracle.getPrice(address(secondary), address(usdc));
        assertEq(quotedPrice, 2500e8);
        // Risk fails closed by excluding stale non-base collateral, not by
        // accepting the still-present quote or claiming the router reverted.
        assertEq(risk.computeCollateralEquity(address(this)), 0);
    }

    function testRiskFreshnessBoundaryAccepts600AndRejects601Seconds() public {
        ReplacementToken secondary = new ReplacementToken();
        vm.prank(address(timelock));
        vault.setCollateralToken(address(secondary), true, 6, 10_000);
        secondary.mint(address(this), 1_000);
        secondary.approve(address(vault), 1_000);
        vault.deposit(address(secondary), 1_000);

        uint256 pricedAt = oracle.updatedAt();
        vm.warp(pricedAt + 599);
        assertEq(risk.computeCollateralEquity(address(this)), 2_500_000);
        vm.warp(pricedAt + 600);
        assertEq(risk.computeCollateralEquity(address(this)), 2_500_000);
        vm.warp(pricedAt + 601);
        assertEq(risk.computeCollateralEquity(address(this)), 0);
    }

    function testReplacementRiskMarginEquityAndWithdrawableAgainstSeededPosition() public {
        address trader = address(0xD501);
        usdc.mint(trader, 100_000_000);
        vm.startPrank(trader);
        usdc.approve(address(vault), 100_000_000);
        vault.deposit(address(usdc), 100_000_000);
        vm.stopPrank();

        vm.prank(address(timelock));
        engine.adminSeedPosition(trader, 1, 1_000_000, 2_500_000_000, 0);

        PerpRiskModule.AccountRisk memory account = risk.computeAccountRisk(trader);
        assertEq(account.equityBase, 100_000_000);
        assertEq(account.initialMarginBase, 2_500_000);
        assertEq(account.maintenanceMarginBase, 1_875_000);
        assertEq(risk.computeFreeCollateral(trader), 97_500_000);
        assertEq(risk.getWithdrawableAmount(trader, address(usdc)), 97_500_000);
    }

    function testRouter1500SecondQuoteStillFailsRisk600SecondGate() public {
        ReplacementToken secondary = new ReplacementToken();
        MockPriceSource primary = new MockPriceSource(2500e8, block.timestamp);
        MockPriceSource backup = new MockPriceSource(2500e8, block.timestamp);
        OracleRouter router = new OracleRouter(address(timelock));
        vm.startPrank(address(timelock));
        vault.setCollateralToken(address(secondary), true, 6, 10_000);
        router.setMaxOracleDelay(1500);
        router.setFeed(
            address(secondary),
            address(usdc),
            IPriceSource(address(primary)),
            IPriceSource(address(backup)),
            1500,
            100,
            true
        );
        risk.setOracle(address(router));
        vm.stopPrank();
        secondary.mint(address(this), 1_000);
        secondary.approve(address(vault), 1_000);
        vault.deposit(address(secondary), 1_000);
        assertEq(risk.computeCollateralEquity(address(this)), 2_500_000);
        vm.warp(block.timestamp + 601);
        (uint256 price, uint256 updatedAt, bool routerOk) = router.getPriceSafe(address(secondary), address(usdc));
        assertEq(price, 2500e8);
        assertTrue(routerOk);
        assertEq(block.timestamp - updatedAt, 601);
        assertEq(risk.computeCollateralEquity(address(this)), 0);
    }

    function testReplacementSeizerPlannerAuthorityAndSpread() public {
        assertEq(address(seizer.collateralVault()), address(vault));
        assertEq(address(seizer.oracle()), address(oracle));
        assertEq(address(seizer.riskModule()), address(legacyCollateralRisk));
        vm.prank(DEPLOYER);
        vm.expectRevert(CollateralSeizer.NotAuthorized.selector);
        seizer.setTokenSeizeConfig(address(usdc), 100, true);
        vm.prank(SAFE);
        vm.expectRevert(CollateralSeizer.NotAuthorized.selector);
        seizer.setTokenSeizeConfig(address(usdc), 100, true);
        vm.prank(address(timelock));
        seizer.setTokenSeizeConfig(address(usdc), 100, true);
        (uint16 spread, bool enabled, bool isSet) = seizer.seizeConfigs(address(usdc));
        assertEq(spread, 100);
        assertTrue(enabled && isSet);
        (uint256 gross, uint256 effective, bool ok) = seizer.previewEffectiveBaseValue(address(usdc), 1_000_000);
        assertTrue(ok);
        assertEq(gross, 1_000_000);
        assertEq(effective, 990_000);
        address trader = address(0x515E);
        usdc.mint(trader, 1_000_000);
        vm.startPrank(trader);
        usdc.approve(address(vault), 1_000_000);
        vault.deposit(address(usdc), 1_000_000);
        vm.stopPrank();
        (address[] memory tokens, uint256[] memory amounts, uint256 covered) =
            seizer.computeSeizurePlan(trader, 495_000);
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(usdc));
        assertEq(amounts[0], 500_000);
        assertEq(covered, 495_000);
    }

    function testReplacementLiquidationMaintenanceGate() public {
        vm.startPrank(address(timelock));
        vault.setAuthorizedEngine(address(engine), true);
        insurance.setBackstopCaller(address(engine), true);
        engine.adminSeedPosition(address(0xA111), 1, 1_000_000, 2_468_310_000, 0);
        engine.adminSeedMarketFunding(1, 0, 1_789_715_546);
        engine.sealMigration(SNAPSHOT);
        vm.stopPrank();
        vm.prank(address(0xB222));
        vm.expectRevert(PerpEngineTypes.LiquidationPaused.selector);
        engine.liquidate(address(0xA111), 1, 500_000);
    }

    function testLostDeployerKeyLifecycle() public {
        // No prank of DEPLOYER occurs after this fixture's construction.
        address governance = address(timelock);
        assertEq(pmr.owner(), governance);
        assertEq(fees.owner(), governance);
        assertEq(seizer.owner(), governance);
        assertEq(engine.owner(), governance);
        assertEq(risk.owner(), governance);
        assertEq(pme.owner(), governance);
        vm.prank(DEPLOYER);
        vm.expectRevert();
        fees.setFeeConsumer(address(engine), false);
        vm.prank(EXECUTOR);
        vm.expectRevert();
        pme.setEngine(address(0xdead));
        vm.prank(SAFE);
        risk.pause();
        vm.prank(SAFE);
        vm.expectRevert();
        risk.unpause();
        vm.prank(SAFE);
        vm.expectRevert(PerpEngineTypes.GuardianCannotRelaxEmergency.selector);
        engine.setEmergencyModes(false, true, true, true);
        vm.startPrank(governance);
        seizer.setTokenSeizeConfig(address(usdc), 5, true);
        fees.setFeeConsumer(address(engine), true);
        risk.setMaxOracleDelay(600);
        pmr.unpause();
        pmr.unpauseConfig();
        pmr.setMaxExecutionDeviationBps(1, 100);
        pmr.pauseConfig();
        pmr.pause();
        engine.adminSeedPosition(address(0x1234), 1, 1_000, 3_000_000, 0);
        engine.adminSeedMarketFunding(1, 0, 1_789_715_546);
        engine.sealMigration(SNAPSHOT);
        risk.unpause();
        engine.unpauseFunding();
        vm.stopPrank();
        assertEq(uint8(engine.migrationState()), 1);
        assertEq(engine.migrationSnapshotHash(), SNAPSHOT);
        assertFalse(risk.paused());
        assertFalse(engine.fundingPaused());
        assertTrue(engine.tradingPaused());
        assertTrue(pme.paused());
    }

    function testReplacementTopologyCloseSettles244274OnceAndSeparatesFees() public {
        address longTrader = address(0xA111);
        address shortTrader = address(0xB222);
        uint256 depositAmount = 100_000_000_000;
        for (uint256 i; i < 2; i++) {
            address trader = i == 0 ? longTrader : shortTrader;
            usdc.mint(trader, depositAmount);
            vm.startPrank(trader);
            usdc.approve(address(vault), depositAmount);
            vault.deposit(address(usdc), depositAmount);
            vm.stopPrank();
        }
        vm.startPrank(address(timelock));
        vault.setAuthorizedEngine(address(engine), true);
        insurance.setBackstopCaller(address(engine), true);
        engine.adminSeedPosition(longTrader, 1, 1_000_000, 2_468_310_000, 0);
        engine.adminSeedPosition(shortTrader, 1, -1_000_000, -2_468_310_000, 0);
        engine.adminSeedMarketFunding(1, 0, 1_789_715_546);
        engine.sealMigration(SNAPSHOT);
        engine.unpauseTrading();
        engine.unpauseFunding();
        vm.stopPrank();
        oracle.setPrice(249_273_743_964);
        uint256 longBefore = vault.balances(longTrader, address(usdc));
        uint256 shortBefore = vault.balances(shortTrader, address(usdc));
        uint256 clearingBefore = vault.balances(address(clearing), address(usdc));
        uint256 feeBefore = vault.balances(address(timelock), address(usdc));
        uint256 custodyBefore = usdc.balanceOf(address(vault));
        // Isolate Engine economics from signature verification, which is
        // independently covered by the replacement-domain PME suite.
        vm.prank(address(pme));
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: shortTrader,
                seller: longTrader,
                marketId: 1,
                sizeDelta1e8: 1_000_000,
                executionPrice1e8: 249_273_743_964,
                buyerIsMaker: false
            })
        );
        assertEq(engine.positions(longTrader, 1).size1e8, 0);
        assertEq(engine.positions(shortTrader, 1).size1e8, 0);
        assertEq(int256(vault.balances(longTrader, address(usdc))) - int256(longBefore), 244_274 - 1_247);
        assertEq(int256(vault.balances(shortTrader, address(usdc))) - int256(shortBefore), -244_274 - 7_479);
        assertEq(vault.balances(address(clearing), address(usdc)), clearingBefore);
        assertEq(vault.balances(address(timelock), address(usdc)) - feeBefore, 1_247 + 7_479);
        assertEq(usdc.balanceOf(address(vault)), custodyBefore);
    }

    function testReplacementLiquidationUsesSharedVaultSeizerAndInsurance() public {
        address trader = address(0xA111);
        address liquidator = address(0xB222);
        address offset = address(0xC333);
        for (uint256 i; i < 3; i++) {
            address account = i == 0 ? trader : i == 1 ? liquidator : offset;
            uint256 amount = i == 0 ? 250_000_000 : 100_000_000_000;
            usdc.mint(account, amount);
            vm.startPrank(account);
            usdc.approve(address(vault), amount);
            vault.deposit(address(usdc), amount);
            vm.stopPrank();
        }
        vm.startPrank(address(timelock));
        vault.setAuthorizedEngine(address(engine), true);
        // InsuranceFund itself calls Vault.transferBetweenAccounts during a
        // shortfall payout. This separate ACL must be verified on the shared
        // deployment before relying on liquidation backstop coverage.
        vault.setAuthorizedEngine(address(insurance), true);
        insurance.setTokenAllowed(address(usdc), true);
        insurance.setBackstopCaller(address(engine), true);
        engine.adminSeedPosition(trader, 1, 100_000_000, 250_000_000_000, 0);
        engine.adminSeedPosition(offset, 1, -100_000_000, -250_000_000_000, 0);
        engine.adminSeedMarketFunding(1, 0, 1_789_715_546);
        engine.sealMigration(SNAPSHOT);
        engine.unpauseLiquidation();
        engine.unpauseFunding();
        vm.stopPrank();
        usdc.mint(address(insurance), 100_000_000);
        vm.prank(address(timelock));
        insurance.depositToVault(address(usdc), 100_000_000);
        vm.prank(address(engine));
        assertEq(insurance.coverVaultShortfall(address(usdc), liquidator, 1_000_000), 1_000_000);
        oracle.setPrice(2400e8);
        assertTrue(
            risk.computeAccountRisk(trader).equityBase < int256(risk.computeAccountRisk(trader).maintenanceMarginBase)
        );
        uint256 insuranceBefore = vault.balances(address(insurance), address(usdc));
        vm.prank(liquidator);
        engine.liquidate(trader, 1, 50_000_000);
        assertEq(engine.positions(trader, 1).size1e8, 50_000_000);
        assertTrue(vault.balances(address(insurance), address(usdc)) <= insuranceBefore);
        assertTrue(engine.tradingPaused());
    }
}
