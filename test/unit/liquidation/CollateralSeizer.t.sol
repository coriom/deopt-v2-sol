// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProtocolConstants} from "../../../src/ProtocolConstants.sol";
import {CollateralVault} from "../../../src/collateral/CollateralVault.sol";
import {CollateralSeizer} from "../../../src/liquidation/CollateralSeizer.sol";
import {IOracle} from "../../../src/oracle/IOracle.sol";

contract MockERC20Decimals is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockOracle is IOracle {
    struct PriceData {
        uint256 price;
        uint256 updatedAt;
        bool ok;
    }

    mapping(bytes32 => PriceData) internal prices;

    function setPrice(address baseAsset, address quoteAsset, uint256 price, uint256 updatedAt, bool ok) external {
        prices[keccak256(abi.encode(baseAsset, quoteAsset))] = PriceData({
            price: price,
            updatedAt: updatedAt,
            ok: ok
        });
    }

    function getPrice(address baseAsset, address quoteAsset) external view returns (uint256 price, uint256 updatedAt) {
        PriceData memory data = prices[keccak256(abi.encode(baseAsset, quoteAsset))];
        require(data.ok, "price-not-set");
        return (data.price, data.updatedAt);
    }

    function getPriceSafe(address baseAsset, address quoteAsset)
        external
        view
        returns (uint256 price, uint256 updatedAt, bool ok)
    {
        PriceData memory data = prices[keccak256(abi.encode(baseAsset, quoteAsset))];
        return (data.price, data.updatedAt, data.ok);
    }
}

contract MockRiskModuleConfigView {
    struct CollateralConfig {
        uint64 weightBps;
        bool isEnabled;
    }

    address public baseCollateralToken;
    mapping(address => CollateralConfig) internal configs;

    function setBaseCollateralToken(address token) external {
        baseCollateralToken = token;
    }

    function setCollateralConfig(address token, uint64 weightBps, bool isEnabled) external {
        configs[token] = CollateralConfig({weightBps: weightBps, isEnabled: isEnabled});
    }

    function collateralConfigs(address token) external view returns (uint64 weightBps, bool isEnabled) {
        CollateralConfig memory cfg = configs[token];
        return (cfg.weightBps, cfg.isEnabled);
    }
}

contract CollateralSeizerTest is Test {
    uint256 internal constant BPS = ProtocolConstants.BPS;
    uint256 internal constant PRICE_SCALE = ProtocolConstants.PRICE_SCALE;

    address internal constant OWNER = address(0xA11CE);
    address internal constant ALICE = address(0xB0B);
    address internal constant BOB = address(0xCAFE);
    address internal constant CAROL = address(0xD00D);
    address internal constant DAVE = address(0xE0E0);

    uint256 internal constant USDC_UNIT = 1e6;
    uint256 internal constant WETH_UNIT = 1e18;
    uint256 internal constant WBTC_UNIT = 1e8;

    uint256 internal constant WETH_USDC_PRICE = 2_000 * PRICE_SCALE;
    uint256 internal constant WBTC_USDC_PRICE = 30_000 * PRICE_SCALE;

    CollateralVault internal vault;
    MockOracle internal oracle;
    MockRiskModuleConfigView internal riskConfig;
    CollateralSeizer internal seizer;

    MockERC20Decimals internal usdc;
    MockERC20Decimals internal weth;
    MockERC20Decimals internal wbtc;

    function setUp() external {
        vault = new CollateralVault(OWNER);
        oracle = new MockOracle();
        riskConfig = new MockRiskModuleConfigView();
        seizer = new CollateralSeizer(OWNER, address(vault), address(oracle), address(riskConfig));

        usdc = new MockERC20Decimals("Mock USDC", "mUSDC", 6);
        weth = new MockERC20Decimals("Mock WETH", "mWETH", 18);
        wbtc = new MockERC20Decimals("Mock WBTC", "mWBTC", 8);

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setCollateralToken(address(weth), true, 18, 10_000);
        vault.setCollateralToken(address(wbtc), true, 8, 10_000);
        vm.stopPrank();

        riskConfig.setBaseCollateralToken(address(usdc));
        riskConfig.setCollateralConfig(address(usdc), 10_000, true);
        riskConfig.setCollateralConfig(address(weth), 8_000, true);
        riskConfig.setCollateralConfig(address(wbtc), 8_500, true);

        oracle.setPrice(address(weth), address(usdc), WETH_USDC_PRICE, block.timestamp, true);
        oracle.setPrice(address(wbtc), address(usdc), WBTC_USDC_PRICE, block.timestamp, true);
    }

    function testTokenDiscountBpsReturnsCorrectDiscountForEnabledToken() external {
        vm.prank(OWNER);
        seizer.setTokenSeizeConfig(address(weth), 100, true);

        uint256 discountBps = seizer.tokenDiscountBps(address(weth));

        assertEq(discountBps, 7_920);
    }

    function testTokenDiscountBpsReturnsZeroForDisabledToken() external {
        riskConfig.setCollateralConfig(address(wbtc), 8_500, false);

        uint256 discountBps = seizer.tokenDiscountBps(address(wbtc));

        assertEq(discountBps, 0);
    }

    function testPreviewEffectiveBaseValueCorrectlyConvertsBaseTokenAmount() external view {
        (uint256 valueBaseFloor, uint256 effectiveBaseFloor, bool ok) =
            seizer.previewEffectiveBaseValue(address(usdc), 123 * USDC_UNIT);

        assertTrue(ok);
        assertEq(valueBaseFloor, 123 * USDC_UNIT);
        assertEq(effectiveBaseFloor, 123 * USDC_UNIT);
    }

    function testPreviewEffectiveBaseValueCorrectlyConvertsNonBaseTokenAmountUsingOraclePrice() external view {
        (uint256 valueBaseFloor, uint256 effectiveBaseFloor, bool ok) =
            seizer.previewEffectiveBaseValue(address(weth), WETH_UNIT / 2);

        assertTrue(ok);
        assertEq(valueBaseFloor, 1_000 * USDC_UNIT);
        assertEq(effectiveBaseFloor, 800 * USDC_UNIT);
    }

    function testComputeSeizurePlanPrioritizesBaseCollateralFirst() external {
        _deposit(address(usdc), ALICE, 200 * USDC_UNIT);
        _deposit(address(weth), ALICE, WETH_UNIT);

        (address[] memory tokensOut, uint256[] memory amountsOut, uint256 baseCovered) =
            seizer.computeSeizurePlan(ALICE, 150 * USDC_UNIT);

        assertEq(tokensOut.length, 1);
        assertEq(amountsOut.length, 1);
        assertEq(tokensOut[0], address(usdc));
        assertEq(amountsOut[0], 150 * USDC_UNIT);
        assertEq(baseCovered, 150 * USDC_UNIT);
    }

    function testComputeSeizurePlanUsesSecondaryCollateralWhenBaseCollateralIsInsufficient() external {
        _deposit(address(usdc), BOB, 100 * USDC_UNIT);
        _deposit(address(weth), BOB, WETH_UNIT);

        (address[] memory tokensOut, uint256[] memory amountsOut, uint256 baseCovered) =
            seizer.computeSeizurePlan(BOB, 150 * USDC_UNIT);

        assertEq(tokensOut.length, 2);
        assertEq(amountsOut.length, 2);
        assertEq(tokensOut[0], address(usdc));
        assertEq(amountsOut[0], 100 * USDC_UNIT);
        assertEq(tokensOut[1], address(weth));
        assertEq(amountsOut[1], 31_250_000_000_000_000);
        assertEq(baseCovered, 150 * USDC_UNIT);
    }

    function testComputeSeizurePlanReturnsPartialCoverageWhenTotalCollateralIsInsufficient() external {
        _deposit(address(usdc), CAROL, 50 * USDC_UNIT);
        _deposit(address(wbtc), CAROL, WBTC_UNIT / 100);

        (address[] memory tokensOut, uint256[] memory amountsOut, uint256 baseCovered) =
            seizer.computeSeizurePlan(CAROL, 400 * USDC_UNIT);

        assertEq(tokensOut.length, 2);
        assertEq(amountsOut.length, 2);
        assertEq(tokensOut[0], address(usdc));
        assertEq(amountsOut[0], 50 * USDC_UNIT);
        assertEq(tokensOut[1], address(wbtc));
        assertEq(amountsOut[1], WBTC_UNIT / 100);
        assertEq(baseCovered, 305 * USDC_UNIT);
        assertLt(baseCovered, 400 * USDC_UNIT);
    }

    function testComputeSeizurePlanReturnsEmptyArraysAndZeroCoverageWhenTargetBaseAmountIsZero() external {
        _deposit(address(usdc), DAVE, 100 * USDC_UNIT);

        (address[] memory tokensOut, uint256[] memory amountsOut, uint256 baseCovered) =
            seizer.computeSeizurePlan(DAVE, 0);

        assertEq(tokensOut.length, 0);
        assertEq(amountsOut.length, 0);
        assertEq(baseCovered, 0);
    }

    function _deposit(address token, address user, uint256 amount) internal {
        MockERC20Decimals(token).mint(user, amount);

        vm.startPrank(user);
        ERC20(token).approve(address(vault), amount);
        vault.deposit(token, amount);
        vm.stopPrank();
    }
}
