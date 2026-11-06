// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {V14LocalPriceSource} from "../../../script/LocalOptionsPriceSourceV14.sol";
import {OracleRouter} from "../../../src/oracle/OracleRouter.sol";
import {CollateralVault} from "../../../src/collateral/CollateralVault.sol";
import {OptionProductRegistry} from "../../../src/OptionProductRegistry.sol";
import {RiskModule} from "../../../src/risk/RiskModule.sol";
import {MarginEngine} from "../../../src/margin/MarginEngine.sol";
import {OptionMatchingEngine} from "../../../src/matching/OptionMatchingEngine.sol";
import {FeesManagerV2} from "../../../src/fees/FeesManagerV2.sol";
import {InsuranceFund} from "../../../src/core/InsuranceFund.sol";
import {VerifiedOptionSettlementOwner} from "../../../src/settlement/VerifiedOptionSettlementOwner.sol";
import {LocalHistoricalChainlinkFeed, LocalPythUnavailable} from "../../../script/OptionsLocalAnvilE2E.s.sol";
import {ScenarioOptionERC20} from "./OptionSettlementFlow.t.sol";

/// @notice Dedicated stack only. Prices and tokens are deterministic local fixtures.
contract DedicatedOptionsStackV14Test is Test {
    uint256 private constant BUYER_PK = 0xB0B;
    uint256 private constant SELLER_PK = 0xCA11;
    uint256 private constant STRIKE = 2_000e8;
    uint128 private constant PREMIUM = 100e6;

    address private buyer;
    address private seller;
    uint64 private expiry;
    uint256 private optionId;
    ScenarioOptionERC20 private usdc;
    ScenarioOptionERC20 private weth;
    CollateralVault private vault;
    OptionProductRegistry private registry;
    OracleRouter private router;
    V14LocalPriceSource private primary;
    V14LocalPriceSource private secondary;
    RiskModule private risk;
    MarginEngine private engine;
    OptionMatchingEngine private matching;
    VerifiedOptionSettlementOwner private verifier;
    LocalHistoricalChainlinkFeed private history;

    function setUp() public {
        buyer = vm.addr(BUYER_PK);
        seller = vm.addr(SELLER_PK);
        expiry = uint64(block.timestamp + 7 days);
        usdc = new ScenarioOptionERC20("Test USDC", "mUSDC", 6);
        weth = new ScenarioOptionERC20("Test WETH", "mWETH", 18);
        vault = new CollateralVault(address(this));
        registry = new OptionProductRegistry(address(this));
        primary = new V14LocalPriceSource();
        secondary = new V14LocalPriceSource();
        router = new OracleRouter(address(this));
        primary.set(STRIKE, block.timestamp, true);
        secondary.set(STRIKE, block.timestamp, true);
        router.setMaxOracleDelay(1_500);
        router.setFeed(address(weth), address(usdc), primary, secondary, 1_500, 100, true);
        engine = new MarginEngine(address(this), address(registry), address(vault), address(router));
        risk = new RiskModule(address(this), address(vault), address(registry), address(engine), address(router));
        matching = new OptionMatchingEngine(address(this), address(engine), address(registry));
        FeesManagerV2 fees = new FeesManagerV2(address(this), address(this));
        InsuranceFund insurance = new InsuranceFund(address(this), address(vault));

        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setMarginEngine(address(engine));
        vault.setRiskModule(address(risk));
        vault.setAuthorizedEngine(address(insurance), true);
        insurance.setTokenAllowed(address(usdc), true);
        insurance.setBackstopCaller(address(engine), true);
        registry.setSettlementAssetAllowed(address(usdc), true);
        registry.setUnderlyingConfig(
            address(weth), OptionProductRegistry.UnderlyingConfig(address(router), 3_000, 3_000, 0, 2_000, true)
        );
        registry.setOptionRiskConfig(address(weth), OptionProductRegistry.OptionRiskConfig(10e6, 12_000, 20_000, true));
        risk.setRiskParams(address(usdc), 10e6, 12_000);
        risk.syncCollateralTokensFromVault();
        engine.setRiskModule(address(risk));
        engine.syncRiskParamsFromRiskModule();
        engine.setMatchingEngine(address(matching));
        engine.setInsuranceFund(address(insurance));
        matching.setExecutor(address(this), true);
        fees.setRebateFundingAccount(address(this));
        fees.setFeeConsumer(address(engine), true);
        engine.setFeesManagerV2(address(fees));
        engine.setUseFeesManagerV2(true);

        history = new LocalHistoricalChainlinkFeed();
        LocalPythUnavailable unavailable = new LocalPythUnavailable();
        address[2] memory underlyings = [address(weth), address(0x1234)];
        address[2] memory feeds = [address(history), address(history)];
        bytes32[2] memory ids = [bytes32(uint256(1)), bytes32(uint256(2))];
        verifier = new VerifiedOptionSettlementOwner(
            address(registry),
            address(this),
            address(this),
            address(usdc),
            address(unavailable),
            underlyings,
            feeds,
            ids,
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
        assertFalse(registry.getSeries(optionId).isActive);
        verifier.executeRegistryAdmin(abi.encodeCall(registry.setSeriesActive, (optionId, true)));
        verifier.executeRegistryAdmin(abi.encodeCall(registry.unpauseSettlement, ()));

        _deposit(buyer, 10_000e6);
        _deposit(seller, 10_000e6);
    }

    function _deposit(address wallet, uint256 amount) internal {
        usdc.mint(wallet, amount);
        vm.startPrank(wallet);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    function _fill(uint128 quantity) internal {
        uint256 nonce = matching.nonces(buyer);
        OptionMatchingEngine.OptionTrade memory trade = OptionMatchingEngine.OptionTrade({
            intentId: keccak256(abi.encode("v14-multifill", nonce)),
            buyer: buyer,
            seller: seller,
            optionId: optionId,
            underlying: address(weth),
            settlementAsset: address(usdc),
            expiry: expiry,
            strike1e8: uint64(STRIKE),
            isCall: true,
            contractSize1e8: 1e8,
            quantity: quantity,
            premiumPerContract: PREMIUM,
            buyerIsMaker: true,
            buyerNonce: nonce,
            sellerNonce: matching.nonces(seller),
            deadline: block.timestamp + 1 hours
        });
        bytes32 digest = matching.hashTrade(trade);
        (uint8 bv, bytes32 br, bytes32 bs) = vm.sign(BUYER_PK, digest);
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(SELLER_PK, digest);
        matching.executeTrade(trade, abi.encodePacked(br, bs, bv), abi.encodePacked(sr, ss, sv));
    }

    function fillForRevertTest(uint128 quantity) external {
        require(msg.sender == address(this), "test only");
        _fill(quantity);
    }

    function testMultipleSignedFillsConserveVaultAndSettle() public {
        uint256 totalBefore = vault.totalDepositedByToken(address(usdc));
        _fill(1);
        _fill(2);
        assertEq(engine.positions(buyer, optionId).quantity, 3);
        assertEq(engine.positions(seller, optionId).quantity, -3);
        assertEq(matching.nonces(buyer), 2);
        assertEq(matching.nonces(seller), 2);
        assertEq(vault.totalDepositedByToken(address(usdc)), totalBefore);
        assertEq(usdc.balanceOf(address(vault)), totalBefore);
        assertEq(vault.balances(buyer, address(usdc)), 10_000e6 - 300e6 - 15_000);
        assertEq(vault.balances(seller, address(usdc)), 10_000e6 + 300e6 - 75_000);

        history.setRound(101, 2_500e8, expiry - 10);
        history.setRound(102, 2_500e8, expiry + 10);
        vm.warp(expiry + 20);
        verifier.propose(optionId, 101, 102);
        vm.warp(block.timestamp + 2 days);
        verifier.resolve(optionId);
        verifier.finalize(optionId);
        engine.settleAccount(optionId, seller);
        engine.settleAccount(optionId, buyer);
        assertEq(engine.positions(buyer, optionId).quantity, 0);
        assertEq(engine.positions(seller, optionId).quantity, 0);
        assertEq(vault.balances(buyer, address(usdc)), 10_000e6 - 300e6 - 15_000 + 1_500e6);
        assertEq(vault.balances(seller, address(usdc)), 10_000e6 + 300e6 - 75_000 - 1_500e6);
        assertEq(vault.totalDepositedByToken(address(usdc)), totalBefore);
        assertEq(usdc.balanceOf(address(vault)), totalBefore);
    }

    function testDualSourceFailureBlocksNewRiskAndWithdrawal() public {
        _fill(1);
        primary.set(0, block.timestamp, false);
        secondary.set(0, block.timestamp, false);
        (,, bool ok) = router.getPriceSafe(address(weth), address(usdc));
        assertFalse(ok);
        vm.prank(seller);
        vm.expectRevert();
        vault.withdraw(address(usdc), 1);
        vm.expectRevert();
        this.fillForRevertTest(1);
    }

    function testDivergentLiveSourcesBlockNewRisk() public {
        _fill(1);
        secondary.set(2_050e8, block.timestamp, true);
        (,, bool ok) = router.getPriceSafe(address(weth), address(usdc));
        assertFalse(ok);
        vm.expectRevert();
        this.fillForRevertTest(1);
        vm.prank(seller);
        vm.expectRevert();
        vault.withdraw(address(usdc), 1);
    }

    function testLiquidationRequiresValidDualSourceAndPreservesAssets() public {
        address liquidator = vm.addr(0xD00D);
        _deposit(liquidator, 10_000e6);
        vm.prank(seller);
        vault.withdraw(address(usdc), 9_000e6);
        _fill(1);
        uint256 totalBefore = vault.totalDepositedByToken(address(usdc));
        uint256 assetsBefore = usdc.balanceOf(address(vault));

        primary.set(4_000e8, block.timestamp, true);
        secondary.set(4_000e8, block.timestamp, true);
        uint256[] memory ids = new uint256[](1);
        uint128[] memory quantities = new uint128[](1);
        ids[0] = optionId;
        quantities[0] = 1;

        primary.set(0, block.timestamp, false);
        secondary.set(0, block.timestamp, false);
        vm.prank(liquidator);
        vm.expectRevert();
        engine.liquidate(seller, ids, quantities);
        assertEq(engine.positions(seller, optionId).quantity, -1);

        primary.set(4_000e8, block.timestamp, true);
        secondary.set(4_000e8, block.timestamp, true);
        vm.prank(liquidator);
        engine.liquidate(seller, ids, quantities);
        assertEq(engine.positions(seller, optionId).quantity, 0);
        assertEq(engine.positions(liquidator, optionId).quantity, -1);
        assertEq(vault.totalDepositedByToken(address(usdc)), totalBefore);
        assertEq(usdc.balanceOf(address(vault)), assetsBefore);
    }
}
