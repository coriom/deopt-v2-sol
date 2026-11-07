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
        engine = new CoveredCallMarginEngine(address(this), address(registry), optionId, address(oracle), 1_500);
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
            new CoveredCallMarginEngine(address(this), address(registry), optionId, address(oracle), 1_500);
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
}
