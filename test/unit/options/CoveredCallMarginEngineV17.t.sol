// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IOracle} from "../../../src/oracle/IOracle.sol";
import {OptionProductRegistry} from "../../../src/OptionProductRegistry.sol";
import {OptionMatchingEngine} from "../../../src/matching/OptionMatchingEngine.sol";
import {CoveredCallMarginEngine} from "../../../src/experimental/CoveredCallMarginEngine.sol";

contract V17Token is ERC20 {
    uint8 private immutable digits;

    constructor(string memory symbol_, uint8 digits_) ERC20(symbol_, symbol_) {
        digits = digits_;
    }

    function decimals() public view override returns (uint8) {
        return digits;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract V18TaxedToken is V17Token {
    constructor() V17Token("taxed mWETH", 18) {}

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && amount > 1) {
            super._update(from, to, amount - 1);
            super._update(from, address(0), 1);
        } else {
            super._update(from, to, amount);
        }
    }
}

contract V17Oracle is IOracle {
    uint256 public price = 2_250e8;
    uint256 public updatedAt;

    constructor() {
        updatedAt = block.timestamp;
    }

    function set(uint256 p, uint256 t) external {
        price = p;
        updatedAt = t;
    }

    function getPrice(address, address) external view returns (uint256, uint256) {
        return (price, updatedAt);
    }

    function getPriceSafe(address, address) external view returns (uint256, uint256, bool) {
        return (price, updatedAt, price != 0);
    }
}

contract CoveredCallMarginEngineV17Test is Test {
    uint256 private constant BUYER_KEY = 0xB0B;
    uint256 private constant SELLER_KEY = 0xCA11;
    address private buyer;
    address private seller;
    V17Token private weth;
    V17Token private usdc;
    V17Oracle private oracle;
    OptionProductRegistry private registry;
    CoveredCallMarginEngine private engine;
    OptionMatchingEngine private matching;
    uint256 private optionId;
    uint64 private expiry;

    function setUp() public {
        buyer = vm.addr(BUYER_KEY);
        seller = vm.addr(SELLER_KEY);
        weth = new V17Token("mWETH", 18);
        usdc = new V17Token("mUSDC", 6);
        oracle = new V17Oracle();
        registry = new OptionProductRegistry(address(this));
        registry.setSettlementAssetAllowed(address(usdc), true);
        registry.setUnderlyingConfig(
            address(weth), OptionProductRegistry.UnderlyingConfig(address(oracle), 3_000, 3_000, 0, 2_000, true)
        );
        expiry = uint64(block.timestamp + 7 days);
        optionId = registry.createSeries(address(weth), address(usdc), expiry, 2_250e8, true, true);
        engine =
            new CoveredCallMarginEngine(address(this), address(registry), optionId, address(oracle), 1_500, 48 hours);
        engine.configureExposureCaps(3, 3);
        matching = new OptionMatchingEngine(address(this), address(engine), address(registry));
        matching.freezeConfiguration();
        engine.bindMatchingEngine(address(matching));
        engine.setPaused(false);
        weth.mint(seller, 3e18);
        usdc.mint(buyer, 10_000e6);
        vm.prank(seller);
        weth.approve(address(engine), type(uint256).max);
        vm.prank(buyer);
        usdc.approve(address(engine), type(uint256).max);
    }

    function _fill(uint256 nonce) private {
        OptionMatchingEngine.OptionTrade memory t = OptionMatchingEngine.OptionTrade({
            intentId: keccak256(abi.encode("covered", nonce)),
            buyer: buyer,
            seller: seller,
            optionId: optionId,
            underlying: address(weth),
            settlementAsset: address(usdc),
            expiry: expiry,
            strike1e8: 2_250e8,
            isCall: true,
            contractSize1e8: 1e8,
            quantity: 1,
            premiumPerContract: 100e6,
            buyerIsMaker: true,
            buyerNonce: nonce,
            sellerNonce: nonce,
            deadline: block.timestamp + 1 hours
        });
        bytes32 digest = matching.hashTrade(t);
        (uint8 bv, bytes32 br, bytes32 bs) = vm.sign(BUYER_KEY, digest);
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(SELLER_KEY, digest);
        matching.executeTrade(t, abi.encodePacked(br, bs, bv), abi.encodePacked(sr, ss, sv));
    }

    function fillExternal(uint256 nonce) external {
        require(msg.sender == address(this));
        _fill(nonce);
    }

    function _replaceEngineWithCaps(uint256 globalCap, uint256 walletCap) private {
        engine =
            new CoveredCallMarginEngine(address(this), address(registry), optionId, address(oracle), 1_500, 48 hours);
        engine.configureExposureCaps(globalCap, walletCap);
        engine.configureFees(address(0), 0, 0);
        matching = new OptionMatchingEngine(address(this), address(engine), address(registry));
        matching.freezeConfiguration();
        engine.bindMatchingEngine(address(matching));
        engine.setPaused(false);
        vm.prank(seller);
        weth.approve(address(engine), type(uint256).max);
        vm.prank(buyer);
        usdc.approve(address(engine), type(uint256).max);
    }

    function testV21GlobalOneContractCapAndRelease() public {
        _replaceEngineWithCaps(1, 1);
        _fill(0);
        assertEq(engine.totalOpenContracts(), 1);
        assertEq(engine.walletOpenContracts(buyer), 1);
        assertEq(engine.walletOpenContracts(seller), 1);
        assertEq(engine.totalLockedUnderlying(), 1e18);
        vm.expectRevert(CoveredCallMarginEngine.ExposureLimit.selector);
        this.fillExternal(1);
        assertEq(engine.totalLockedUnderlying(), 1e18);
        vm.warp(expiry);
        vm.prank(buyer);
        engine.exercise(seller, 1);
        assertEq(engine.totalOpenContracts(), 0);
        assertEq(engine.walletOpenContracts(buyer), 0);
        assertEq(engine.walletOpenContracts(seller), 0);
    }

    function testV21WalletCapBlocksSecondFillEvenWithGlobalCapacity() public {
        _replaceEngineWithCaps(2, 1);
        _fill(0);
        vm.expectRevert(CoveredCallMarginEngine.ExposureLimit.selector);
        this.fillExternal(1);
        assertEq(engine.totalOpenContracts(), 1);
        assertEq(engine.totalLockedUnderlying(), 1e18);
        vm.expectRevert(CoveredCallMarginEngine.NotAuthorized.selector);
        engine.configureExposureCaps(2, 2);
    }

    function testV21UnconfiguredExposureCannotBind() public {
        CoveredCallMarginEngine fresh =
            new CoveredCallMarginEngine(address(this), address(registry), optionId, address(oracle), 1_500, 48 hours);
        OptionMatchingEngine ready = new OptionMatchingEngine(address(this), address(fresh), address(registry));
        ready.freezeConfiguration();
        vm.expectRevert(CoveredCallMarginEngine.InvalidConfiguration.selector);
        fresh.bindMatchingEngine(address(ready));
    }

    function testV23DeployUnboundThenBindApprovedInactiveSeries() public {
        OptionProductRegistry isolated = new OptionProductRegistry(address(this));
        CoveredCallMarginEngine fresh =
            new CoveredCallMarginEngine(address(this), address(isolated), 0, address(oracle), 1_500, 48 hours);
        OptionMatchingEngine ready = new OptionMatchingEngine(address(this), address(fresh), address(isolated));

        assertTrue(fresh.paused());
        assertFalse(fresh.seriesBound());
        assertEq(address(fresh.underlying()), address(0));
        assertEq(address(fresh.quote()), address(0));
        assertEq(fresh.matchingEngine(), address(0));
        assertEq(fresh.maxOpenContracts(), 0);
        assertEq(isolated.totalSeries(), 0);
        vm.expectRevert(CoveredCallMarginEngine.InvalidConfiguration.selector);
        fresh.bindMatchingEngine(address(ready));
        vm.expectRevert(OptionProductRegistry.UnknownSeries.selector);
        fresh.bindSeries(optionId);

        isolated.setSettlementAssetAllowed(address(usdc), true);
        isolated.setUnderlyingConfig(
            address(weth), OptionProductRegistry.UnderlyingConfig(address(oracle), 3_000, 3_000, 0, 2_000, true)
        );
        uint256 isolatedId = isolated.createSeries(address(weth), address(usdc), expiry, 2_250e8, true, true);
        vm.expectRevert(CoveredCallMarginEngine.InvalidConfiguration.selector);
        fresh.bindSeries(isolatedId);
        isolated.setSeriesActive(isolatedId, false);
        fresh.bindSeries(isolatedId);
        assertTrue(fresh.seriesBound());
        assertEq(fresh.optionId(), isolatedId);
        assertEq(address(fresh.underlying()), address(weth));
        assertEq(address(fresh.quote()), address(usdc));
        assertEq(fresh.strikePerContract(), 2_250e6);
        vm.expectRevert(CoveredCallMarginEngine.InvalidConfiguration.selector);
        fresh.bindSeries(isolatedId);
        fresh.configureExposureCaps(1, 1);
        ready.freezeConfiguration();
        fresh.bindMatchingEngine(address(ready));
        assertTrue(fresh.paused());
    }

    function testV20PhysicalPremiumFeesAreTransferredAndFrozen() public {
        address recipient = address(0xFEE);
        engine =
            new CoveredCallMarginEngine(address(this), address(registry), optionId, address(oracle), 1_500, 48 hours);
        engine.configureExposureCaps(3, 3);
        engine.configureFees(recipient, 50, 250);
        matching = new OptionMatchingEngine(address(this), address(engine), address(registry));
        matching.freezeConfiguration();
        engine.bindMatchingEngine(address(matching));
        engine.setPaused(false);
        vm.prank(seller);
        weth.approve(address(engine), type(uint256).max);
        vm.prank(buyer);
        usdc.approve(address(engine), type(uint256).max);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        _fill(0);
        assertEq(usdc.balanceOf(buyer), buyerBefore - 100_005_000);
        assertEq(usdc.balanceOf(seller), 99_975_000);
        assertEq(usdc.balanceOf(recipient), 30_000);
        assertEq(weth.balanceOf(address(engine)), 1e18);
        vm.expectRevert(CoveredCallMarginEngine.NotAuthorized.selector);
        engine.configureFees(recipient, 0, 0);
        vm.prank(buyer);
        usdc.approve(address(engine), 100e6);
        vm.expectRevert();
        this.fillExternal(1); // The buyer needs premium plus the buyer fee, not premium alone.
        assertEq(usdc.balanceOf(recipient), 30_000);
        assertEq(usdc.balanceOf(seller), 99_975_000);
        assertEq(weth.balanceOf(address(engine)), 1e18);
        vm.prank(buyer);
        usdc.approve(address(engine), type(uint256).max);
        vm.warp(expiry);
        vm.prank(buyer);
        engine.exercise(seller, 1);
        assertEq(usdc.balanceOf(recipient), 30_000);
        assertEq(weth.balanceOf(buyer), 1e18);
    }

    function testV17TwoCoveredFillsPhysicalDeliveryAtExtremeSpot() public {
        _fill(0);
        _fill(1);
        assertEq(engine.openLots(buyer, seller), 2);
        assertEq(engine.totalLockedUnderlying(), 2e18);
        assertEq(weth.balanceOf(address(engine)), 2e18);
        assertEq(usdc.balanceOf(seller), 200e6);
        vm.warp(expiry);
        oracle.set(100_000e8, block.timestamp);
        vm.prank(buyer);
        engine.exercise(seller, 2);
        assertEq(weth.balanceOf(buyer), 2e18);
        assertEq(usdc.balanceOf(seller), 4_700e6);
        assertEq(engine.totalLockedUnderlying(), 0);
        assertEq(weth.balanceOf(address(engine)), 0);
        vm.prank(buyer);
        vm.expectRevert(CoveredCallMarginEngine.InsufficientPosition.selector);
        engine.exercise(seller, 1);
    }

    function testV17UndercoveredAndOracleDownCannotOpen() public {
        // Only three units minted; a fourth fill lacks cover.
        _fill(0);
        _fill(1);
        _fill(2);
        oracle.set(0, block.timestamp);
        vm.expectRevert(OptionMatchingEngine.TradeOracleUnavailable.selector);
        this.fillExternal(3);
        oracle.set(2_250e8, block.timestamp);
        vm.expectRevert();
        this.fillExternal(3);
        assertEq(engine.totalLockedUnderlying(), 3e18);
    }

    function testV17WriterCannotWithdrawAndPauseDoesNotBlockExercise() public {
        _fill(0);
        vm.prank(seller);
        vm.expectRevert();
        weth.transferFrom(address(engine), seller, 1e18);
        engine.setPaused(true);
        vm.warp(expiry);
        oracle.set(0, block.timestamp);
        vm.prank(buyer);
        engine.exercise(seller, 1);
        assertEq(weth.balanceOf(buyer), 1e18);
    }

    function testV17BuyerCanWaiveAfterExpiryOnly() public {
        _fill(0);
        vm.prank(buyer);
        vm.expectRevert(CoveredCallMarginEngine.NotExpired.selector);
        engine.waive(seller, 1);
        vm.warp(expiry);
        vm.prank(buyer);
        engine.waive(seller, 1);
        assertEq(weth.balanceOf(seller), 3e18);
        assertEq(engine.totalLockedUnderlying(), 0);
    }

    function testV17MatcherCannotSwitchToCashEngineOrOtherRegistry() public {
        vm.expectRevert(OptionMatchingEngine.ConfigurationAlreadyFrozen.selector);
        matching.setEngine(address(0xCA5));
        vm.expectRevert(OptionMatchingEngine.ConfigurationAlreadyFrozen.selector);
        matching.setRegistry(address(0xCA5));
    }

    function testV17CannotBindUnfrozenMatcher() public {
        CoveredCallMarginEngine fresh =
            new CoveredCallMarginEngine(address(this), address(registry), optionId, address(oracle), 1_500, 48 hours);
        fresh.configureExposureCaps(1, 1);
        OptionMatchingEngine unfrozen = new OptionMatchingEngine(address(this), address(fresh), address(registry));
        vm.expectRevert(CoveredCallMarginEngine.InvalidConfiguration.selector);
        fresh.bindMatchingEngine(address(unfrozen));
    }

    function testV17StaleOracleCannotOpenButCannotBlockExercise() public {
        _fill(0);
        vm.warp(block.timestamp + 1_501);
        vm.expectRevert(OptionMatchingEngine.TradeOracleStale.selector);
        this.fillExternal(1);
        vm.warp(expiry);
        vm.prank(buyer);
        engine.exercise(seller, 1);
        assertEq(weth.balanceOf(buyer), 1e18);
    }

    function testV17InsufficientStrikePaymentRetainsLockedCover() public {
        _fill(0);
        uint256 buyerBalance = usdc.balanceOf(buyer);
        vm.prank(buyer);
        usdc.transfer(address(0xD00D), buyerBalance);
        vm.warp(expiry);
        vm.prank(buyer);
        vm.expectRevert();
        engine.exercise(seller, 1);
        assertEq(engine.openLots(buyer, seller), 1);
        assertEq(engine.totalLockedUnderlying(), 1e18);
        assertEq(weth.balanceOf(address(engine)), 1e18);
        usdc.mint(buyer, 2_250e6);
        vm.prank(buyer);
        engine.exercise(seller, 1);
        assertEq(engine.totalLockedUnderlying(), 0);
    }

    function testV18UnexercisedLotReleasedAtDeadline() public {
        _fill(0);
        vm.warp(uint256(expiry) + 48 hours - 1);
        vm.expectRevert(CoveredCallMarginEngine.ExerciseWindowOpen.selector);
        engine.releaseExpired(buyer, seller, 1);
        vm.warp(uint256(expiry) + 48 hours);
        vm.prank(seller);
        engine.releaseExpired(buyer, seller, 1);
        assertEq(weth.balanceOf(seller), 3e18);
        assertEq(engine.totalLockedUnderlying(), 0);
        vm.prank(buyer);
        vm.expectRevert(CoveredCallMarginEngine.ExerciseWindowClosed.selector);
        engine.exercise(seller, 1);
    }

    function testV18OneExercisedOneLapsedConservesCover() public {
        _fill(0);
        _fill(1);
        vm.warp(expiry);
        vm.prank(buyer);
        engine.exercise(seller, 1);
        assertEq(engine.openLots(buyer, seller), 1);
        assertEq(weth.balanceOf(address(engine)), 1e18);
        vm.warp(uint256(expiry) + 48 hours);
        engine.releaseExpired(buyer, seller, 1);
        assertEq(weth.balanceOf(buyer), 1e18);
        assertEq(weth.balanceOf(seller), 2e18);
        assertEq(weth.balanceOf(address(engine)), 0);
    }

    function testV18OtherWalletCannotExerciseOrReleaseBeforeDeadline() public {
        _fill(0);
        vm.warp(expiry);
        vm.prank(address(0xA11CE));
        vm.expectRevert(CoveredCallMarginEngine.InsufficientPosition.selector);
        engine.exercise(seller, 1);
        vm.prank(address(0xA11CE));
        vm.expectRevert(CoveredCallMarginEngine.ExerciseWindowOpen.selector);
        engine.releaseExpired(buyer, seller, 1);
        assertEq(engine.openLots(buyer, seller), 1);
        assertEq(weth.balanceOf(address(engine)), 1e18);
    }

    function testV18FeeOnTransferCoverRevertsWithoutLockingAnyLot() public {
        V18TaxedToken taxed = new V18TaxedToken();
        OptionProductRegistry isolated = new OptionProductRegistry(address(this));
        isolated.setSettlementAssetAllowed(address(usdc), true);
        isolated.setUnderlyingConfig(
            address(taxed), OptionProductRegistry.UnderlyingConfig(address(oracle), 3_000, 3_000, 0, 2_000, true)
        );
        uint256 id = isolated.createSeries(address(taxed), address(usdc), expiry, 2_250e8, true, true);
        CoveredCallMarginEngine covered =
            new CoveredCallMarginEngine(address(this), address(isolated), id, address(oracle), 1_500, 48 hours);
        covered.configureExposureCaps(1, 1);
        OptionMatchingEngine matcher = new OptionMatchingEngine(address(this), address(covered), address(isolated));
        matcher.freezeConfiguration();
        covered.bindMatchingEngine(address(matcher));
        covered.setPaused(false);
        taxed.mint(seller, 1e18);
        vm.prank(seller);
        taxed.approve(address(covered), 1e18);
        OptionMatchingEngine.OptionTrade memory trade = OptionMatchingEngine.OptionTrade({
            intentId: keccak256("taxed-cover"),
            buyer: buyer,
            seller: seller,
            optionId: id,
            underlying: address(taxed),
            settlementAsset: address(usdc),
            expiry: expiry,
            strike1e8: 2_250e8,
            isCall: true,
            contractSize1e8: 1e8,
            quantity: 1,
            premiumPerContract: 100e6,
            buyerIsMaker: true,
            buyerNonce: 0,
            sellerNonce: 0,
            deadline: block.timestamp + 1 hours
        });
        bytes32 digest = matcher.hashTrade(trade);
        (uint8 bv, bytes32 br, bytes32 bs) = vm.sign(BUYER_KEY, digest);
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(SELLER_KEY, digest);
        vm.expectRevert(CoveredCallMarginEngine.Insolvent.selector);
        matcher.executeTrade(trade, abi.encodePacked(br, bs, bv), abi.encodePacked(sr, ss, sv));
        assertEq(covered.totalLockedUnderlying(), 0);
        assertEq(covered.openLots(buyer, seller), 0);
        assertEq(taxed.balanceOf(seller), 1e18);
    }
}
