// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {IOracle} from "../../src/oracle/IOracle.sol";
import {IPerpEngineTrade} from "../../src/matching/IPerpEngineTrade.sol";
import {PerpEngine} from "../../src/perp/PerpEngine.sol";
import {PerpEngineTypes} from "../../src/perp/PerpEngineTypes.sol";
import {PerpMarketRegistry} from "../../src/perp/PerpMarketRegistry.sol";
import {IPerpRiskModule} from "../../src/perp/PerpEngineStorage.sol";
import {PerpMatchingEngine} from "../../src/matching/PerpMatchingEngine.sol";

/*//////////////////////////////////////////////////////////////
                          LOCAL MOCKS
//////////////////////////////////////////////////////////////*/

contract DBIMockERC20 is ERC20 {
    uint8 private immutable _decimalsValue;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimalsValue = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimalsValue;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DBIMockOracle is IOracle {
    struct PriceData {
        uint256 price;
        uint256 updatedAt;
        bool ok;
    }

    mapping(bytes32 => PriceData) internal prices;

    function setPrice(address baseAsset, address quoteAsset, uint256 price, uint256 updatedAt, bool ok) external {
        prices[keccak256(abi.encode(baseAsset, quoteAsset))] = PriceData({price: price, updatedAt: updatedAt, ok: ok});
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

contract DBIMockPerpRiskModule is IPerpRiskModule {
    address public immutable baseCollateralToken;
    uint8 public immutable baseDecimals;

    mapping(address => AccountRisk) internal risks;

    constructor(address baseCollateralToken_, uint8 baseDecimals_) {
        baseCollateralToken = baseCollateralToken_;
        baseDecimals = baseDecimals_;
    }

    function setAccountRisk(address trader, int256 equityBase, uint256 maintenanceMarginBase, uint256 initialMarginBase)
        external
    {
        risks[trader] = AccountRisk({
            equityBase: equityBase,
            maintenanceMarginBase: maintenanceMarginBase,
            initialMarginBase: initialMarginBase
        });
    }

    function computeAccountRisk(address trader) external view returns (AccountRisk memory risk) {
        risk = risks[trader];
    }

    function computeFreeCollateral(address trader) external view returns (int256 freeCollateralBase) {
        AccountRisk memory risk = risks[trader];
        return risk.equityBase - int256(risk.initialMarginBase);
    }

    function previewWithdrawImpact(address, address, uint256 amount)
        external
        pure
        returns (WithdrawPreview memory preview)
    {
        preview.requestedAmount = amount;
        preview.maxWithdrawable = amount;
    }

    function getWithdrawableAmount(address, address) external pure returns (uint256 amount) {
        return type(uint256).max;
    }
}

/// @title PerpDoubleBoundInteractionTest
/// @notice PERPS-PRICING-AND-EXECUTION-SAFETY-CORE-V1 security matrix — Scenarios 7 & 8.
/// @dev
///  The `PerpMatchingEngine` flow enforces user-signed price bounds FIRST
///  (`BuyerBoundExceeded` / `SellerBoundViolated` in `_executeSingle`) and
///  then delegates to `PerpEngine.applyTrade` which enforces the protocol
///  per-market `maxExecutionDeviationBps` guard against a fresh oracle mark.
///
///  Scenario 7 — Protocol tighter than user: user allows 10% deviation on the
///                buy side; protocol allows 5%. Matcher tries 7% deviation.
///                The user check PASSES (7% < 10% user cap) and the trade
///                enters `applyTrade`, which reverts on the protocol cap
///                (`ExecutionPriceOutOfBand`). The tighter side wins because
///                BOTH checks must pass; protocol runs SECOND but is the
///                gating check here.
///
///  Scenario 8 — User tighter than protocol: user allows 3% deviation on the
///                buy side; protocol allows 5%. Matcher tries 4% deviation.
///                The USER check FIRES FIRST (`BuyerBoundExceeded`); the
///                trade never reaches `applyTrade`, so the protocol cap is
///                irrelevant. Again the tighter side wins.
///
///  Combined, both scenarios validate the double-bound architecture:
///   - user check is EOA-consented (both parties sign inclusive bounds)
///   - protocol check is governance-configured, per-market, oracle-referenced
///   - the tighter of the two ALWAYS wins because both must pass to trade
contract PerpDoubleBoundInteractionTest is Test {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BASE_UNIT = 1e6;
    uint128 internal constant ONE = 1e8;

    // Oracle mark: 2_000 USDC per WETH (in 1e8).
    uint256 internal constant ORACLE_MARK_1E8 = 2_000 * PRICE_SCALE;

    // Deviation offsets (relative to oracle mark, in bps).
    uint256 internal constant DEV_BPS_3PCT = 300;
    uint256 internal constant DEV_BPS_4PCT = 400;
    uint256 internal constant DEV_BPS_5PCT = 500;
    uint256 internal constant DEV_BPS_7PCT = 700;
    uint256 internal constant DEV_BPS_10PCT = 1_000;

    // Signer PKs (both counterparties for the signed V2 flow).
    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant BUYER_PK = 0xB0B;
    uint256 internal constant SELLER_PK = 0xCA11;

    bytes32 internal constant INTENT_ID = keccak256("double-bound-interaction");

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    CollateralVault internal vault;
    PerpMarketRegistry internal registry;
    PerpEngine internal engine;
    DBIMockOracle internal oracle;
    DBIMockPerpRiskModule internal riskModule;
    PerpMatchingEngine internal matchingEngine;

    DBIMockERC20 internal usdc;
    DBIMockERC20 internal weth;

    uint256 internal marketId;

    address internal OWNER;
    address internal BUYER;
    address internal SELLER;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        OWNER = vm.addr(OWNER_PK);
        BUYER = vm.addr(BUYER_PK);
        SELLER = vm.addr(SELLER_PK);

        vault = new CollateralVault(OWNER);
        registry = new PerpMarketRegistry(OWNER);
        oracle = new DBIMockOracle();

        usdc = new DBIMockERC20("Mock USDC", "mUSDC", 6);
        weth = new DBIMockERC20("Mock WETH", "mWETH", 18);

        riskModule = new DBIMockPerpRiskModule(address(usdc), 6);
        engine = new PerpEngine(OWNER, address(registry), address(vault), address(oracle));
        matchingEngine = new PerpMatchingEngine(OWNER, address(engine));

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setAuthorizedEngine(address(engine), true);

        registry.setSettlementAssetAllowed(address(usdc), true);
        marketId = registry.createMarket(
            address(weth),
            address(usdc),
            address(0),
            bytes32("ETH-PERP"),
            PerpMarketRegistry.RiskConfig({
                initialMarginBps: 1_000,
                maintenanceMarginBps: 500,
                liquidationPenaltyBps: 500,
                maxPositionSize1e8: uint128(100 * ONE),
                maxOpenInterest1e8: uint128(1_000 * ONE),
                reduceOnlyDuringCloseOnly: true
            }),
            PerpMarketRegistry.LiquidationConfig({
                closeFactorBps: 5_000,
                priceSpreadBps: 100,
                minImprovementBps: 50,
                oracleMaxDelay: 60
            }),
            PerpMarketRegistry.FundingConfig({
                isEnabled: false,
                fundingInterval: 0,
                maxFundingRateBps: 0,
                maxSkewFundingBps: 0,
                oracleClampBps: 0,
                impactMidMaxDelay: 0
            })
        );

        // Protocol bound: 5% (500 bps).
        registry.setMaxExecutionDeviationBps(marketId, uint16(DEV_BPS_5PCT));

        // Wire the real `PerpMatchingEngine` as the authorized matcher so the
        // FULL flow runs: signature check → user bound → `applyTrade` →
        // protocol bound.
        engine.setMatchingEngine(address(matchingEngine));
        engine.setRiskModule(address(riskModule));
        vm.stopPrank();

        oracle.setPrice(address(weth), address(usdc), ORACLE_MARK_1E8, block.timestamp, true);

        _setHealthyRisk(BUYER);
        _setHealthyRisk(SELLER);

        _deposit(BUYER, 1_000_000 * BASE_UNIT);
        _deposit(SELLER, 1_000_000 * BASE_UNIT);
    }

    /*//////////////////////////////////////////////////////////////
              SCENARIO 7 — PROTOCOL TIGHTER THAN USER
    //////////////////////////////////////////////////////////////*/

    /// @notice User bound = 10% deviation, protocol bound = 5%. Matcher tries
    ///         to execute at 7% deviation. The user bound PASSES (7 < 10),
    ///         but the protocol bound in `applyTrade` FIRES with
    ///         `ExecutionPriceOutOfBand`. Protocol wins because it is
    ///         downstream and BOTH must pass to trade.
    function testProtocolBoundTighterThanUserBoundBlocksBuyExecution() external {
        // exec price = mark * (1 + 7%)
        uint128 execPrice = uint128(_priceAtDeviation(DEV_BPS_7PCT, true));
        // user max = mark * (1 + 10%)
        uint128 userMax = uint128(_priceAtDeviation(DEV_BPS_10PCT, true));

        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade({
            executionPrice1e8: execPrice,
            maxExecutionPrice1e8: userMax,
            minExecutionPrice1e8: 0
        });

        vm.prank(OWNER);
        vm.expectRevert(PerpEngineTypes.ExecutionPriceOutOfBand.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        // No state written.
        assertEq(engine.positions(BUYER, marketId).size1e8, 0);
        assertEq(engine.positions(SELLER, marketId).size1e8, 0);
    }

    /// @notice Symmetric verification: a Sell where user gives wide seller
    ///         floor and matcher tries protocol-violating deviation BELOW
    ///         the mark. `ExecutionPriceOutOfBand` fires from the protocol
    ///         guard because the user seller-min PASSES.
    function testProtocolBoundTighterThanUserBoundBlocksSellExecution() external {
        // exec price = mark * (1 - 7%)
        uint128 execPrice = uint128(_priceAtDeviation(DEV_BPS_7PCT, false));
        // user min = mark * (1 - 10%) — very permissive floor
        uint128 userMin = uint128(_priceAtDeviation(DEV_BPS_10PCT, false));

        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade({
            executionPrice1e8: execPrice,
            maxExecutionPrice1e8: 0,
            minExecutionPrice1e8: userMin
        });

        vm.prank(OWNER);
        vm.expectRevert(PerpEngineTypes.ExecutionPriceOutOfBand.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);
    }

    /// @notice Sanity: same protocol/user layout but exec price within BOTH
    ///         bounds (3% deviation, inside 5% protocol AND 10% user) MUST
    ///         succeed. This validates that the reverts above are not
    ///         coming from any unrelated guard.
    function testProtocolBoundTighterThanUserBoundInsideBothPasses() external {
        uint128 execPrice = uint128(_priceAtDeviation(DEV_BPS_3PCT, true));
        uint128 userMax = uint128(_priceAtDeviation(DEV_BPS_10PCT, true));

        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade({
            executionPrice1e8: execPrice,
            maxExecutionPrice1e8: userMax,
            minExecutionPrice1e8: 0
        });

        vm.prank(OWNER);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(engine.positions(BUYER, marketId).size1e8, int256(uint256(ONE)));
        assertEq(engine.positions(SELLER, marketId).size1e8, -int256(uint256(ONE)));
    }

    /*//////////////////////////////////////////////////////////////
              SCENARIO 8 — USER TIGHTER THAN PROTOCOL
    //////////////////////////////////////////////////////////////*/

    /// @notice User bound = 3% deviation, protocol bound = 5%. Matcher tries
    ///         to execute at 4% deviation. The USER bound FIRES FIRST
    ///         (`BuyerBoundExceeded`) — the trade never reaches `applyTrade`,
    ///         so the protocol bound is irrelevant. User wins because it is
    ///         checked upstream in `_executeSingle`.
    function testUserBoundTighterThanProtocolBoundBlocksBuyExecution() external {
        uint128 execPrice = uint128(_priceAtDeviation(DEV_BPS_4PCT, true));
        uint128 userMax = uint128(_priceAtDeviation(DEV_BPS_3PCT, true));

        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade({
            executionPrice1e8: execPrice,
            maxExecutionPrice1e8: userMax,
            minExecutionPrice1e8: 0
        });

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.BuyerBoundExceeded.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        // No state written — nonces stay put because bounds check runs
        // BEFORE `_consumeNonces`.
        assertEq(engine.positions(BUYER, marketId).size1e8, 0);
        assertEq(matchingEngine.nonces(BUYER), 0);
        assertEq(matchingEngine.nonces(SELLER), 0);
    }

    /// @notice Symmetric verification on the seller side: user seller-min at
    ///         a 3% deviation floor, matcher tries 4% below mark. User check
    ///         fires with `SellerBoundViolated` before protocol.
    function testUserBoundTighterThanProtocolBoundBlocksSellExecution() external {
        uint128 execPrice = uint128(_priceAtDeviation(DEV_BPS_4PCT, false));
        uint128 userMin = uint128(_priceAtDeviation(DEV_BPS_3PCT, false));

        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade({
            executionPrice1e8: execPrice,
            maxExecutionPrice1e8: 0,
            minExecutionPrice1e8: userMin
        });

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.SellerBoundViolated.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);
    }

    /// @notice Sanity: user 3% + protocol 5%, exec at 2% — both pass, trade
    ///         succeeds. Ensures the reverts above are attributable to the
    ///         user bound and not some other check.
    function testUserBoundTighterThanProtocolBoundInsideBothPasses() external {
        // 2% deviation — inside both 3% user and 5% protocol.
        uint128 execPrice = uint128(_priceAtDeviation(200, true));
        uint128 userMax = uint128(_priceAtDeviation(DEV_BPS_3PCT, true));

        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade({
            executionPrice1e8: execPrice,
            maxExecutionPrice1e8: userMax,
            minExecutionPrice1e8: 0
        });

        vm.prank(OWNER);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(engine.positions(BUYER, marketId).size1e8, int256(uint256(ONE)));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns `oracleMark * (1 ± devBps/10_000)`.
    function _priceAtDeviation(uint256 devBps, bool above) internal pure returns (uint256) {
        if (above) {
            return (ORACLE_MARK_1E8 * (10_000 + devBps)) / 10_000;
        } else {
            return (ORACLE_MARK_1E8 * (10_000 - devBps)) / 10_000;
        }
    }

    function _signedTrade(uint128 executionPrice1e8, uint128 maxExecutionPrice1e8, uint128 minExecutionPrice1e8)
        internal
        view
        returns (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig)
    {
        t = PerpMatchingEngine.PerpTrade({
            intentId: INTENT_ID,
            buyer: BUYER,
            seller: SELLER,
            marketId: marketId,
            sizeDelta1e8: ONE,
            executionPrice1e8: executionPrice1e8,
            maxExecutionPrice1e8: maxExecutionPrice1e8,
            minExecutionPrice1e8: minExecutionPrice1e8,
            buyerIsMaker: true,
            buyerNonce: 0,
            sellerNonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes32 digest = matchingEngine.hashTrade(t);
        buyerSig = _sign(BUYER_PK, digest);
        sellerSig = _sign(SELLER_PK, digest);
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _deposit(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    function _setHealthyRisk(address trader) internal {
        riskModule.setAccountRisk(trader, int256(1_000_000 * BASE_UNIT), 0, 0);
    }
}
