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

/// @dev Local decimals-configurable ERC20 mock (mirrors
///      `test/perp/PerpEngineExecutionPriceGuard.t.sol` conventions).
contract CollusionMockERC20 is ERC20 {
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

/// @dev Minimal `IOracle` mock (same shape as `EPGMockOracle` used by the
///      execution-price-guard suite).
contract CollusionMockOracle is IOracle {
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

/// @dev Risk module stub that returns healthy risk for every trader.
contract CollusionMockPerpRiskModule is IPerpRiskModule {
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

/// @title PerpCollusionExecutionPriceAttackTest
/// @notice PERPS-PRICING-AND-EXECUTION-SAFETY-CORE-V1 security matrix — Scenarios 1 & 2.
/// @dev
///  Scenario 1: two colluding EOAs sign a valid V2 PerpTrade with both user
///              bounds set to `0` (strict legacy semantics) and the matcher
///              submits with `executionPrice1e8 = 10x oracle mark`. MUST
///              revert with `ExecutionPriceOutOfBand` (Part A protocol guard).
///  Scenario 2: symmetric — `executionPrice1e8 = oracleMark / 10`.
///
///  Both scenarios are validated on TWO paths where the protocol allows:
///   (a) The direct engine call — `PerpEngine.applyTrade` invoked by the
///       authorized matching-engine EOA. This is the fundamental protocol
///       guard: even if the matching engine were compromised (or a rogue
///       operator EOA held the role), the guard blocks wash trades.
///   (b) The full `PerpMatchingEngine.executeTrade` flow using two real
///       EIP-712 signatures over the V2 typehash. Both bounds set to `0`
///       mean the user-bound checks in `_executeSingle` are inert; the
///       downstream `applyTrade` still enforces the protocol band.
///
///  Combined, this proves wash trading at absurd prices cannot fabricate
///  realized PnL — the guard sits INSIDE `applyTrade` and fires before any
///  position mutation or cashflow.
contract PerpCollusionExecutionPriceAttackTest is Test {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BASE_UNIT = 1e6;
    uint128 internal constant ONE = 1e8;

    // 2% guard band. Anything more than 2% off mark reverts.
    uint16 internal constant GUARD_BAND_BPS = 200;

    // Oracle mark: 2_000 USDC per WETH (in 1e8).
    uint256 internal constant ORACLE_MARK_1E8 = 2_000 * PRICE_SCALE;

    // Attack prices: 10x above / 10x below oracle mark.
    uint256 internal constant ATTACK_PRICE_10X_ABOVE_1E8 = ORACLE_MARK_1E8 * 10;
    uint256 internal constant ATTACK_PRICE_10X_BELOW_1E8 = ORACLE_MARK_1E8 / 10;

    // Signer private keys used by the two colluding EOAs (Scenario 1/2 (b)).
    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant BUYER_PK = 0xB0B;
    uint256 internal constant SELLER_PK = 0xCA11;

    bytes32 internal constant INTENT_ID = keccak256("collusion-attack-intent");

    // Engine EOA authorized to call `applyTrade` directly (path (a)).
    address internal constant DIRECT_MATCHER = address(0xBEEF);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    CollateralVault internal vault;
    PerpMarketRegistry internal registry;
    PerpEngine internal engine;
    CollusionMockOracle internal oracle;
    CollusionMockPerpRiskModule internal riskModule;
    PerpMatchingEngine internal matchingEngine;

    CollusionMockERC20 internal usdc;
    CollusionMockERC20 internal weth;

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
        oracle = new CollusionMockOracle();

        usdc = new CollusionMockERC20("Mock USDC", "mUSDC", 6);
        weth = new CollusionMockERC20("Mock WETH", "mWETH", 18);

        riskModule = new CollusionMockPerpRiskModule(address(usdc), 6);
        engine = new PerpEngine(OWNER, address(registry), address(vault), address(oracle));

        // Real matching engine wired to the real perp engine (path (b)).
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

        // Governance-configured protocol deviation guard: 2%.
        registry.setMaxExecutionDeviationBps(marketId, GUARD_BAND_BPS);

        // Path (a): direct-EOA matcher — authorize the `DIRECT_MATCHER` sentinel.
        // Path (b): the real `PerpMatchingEngine` contract. Only one of the two
        // can be the engine's authorized matcher at a time; each test rewires
        // via `_asDirectMatcher()` or `_asContractMatcher()`.
        engine.setMatchingEngine(DIRECT_MATCHER);
        engine.setRiskModule(address(riskModule));
        vm.stopPrank();

        oracle.setPrice(address(weth), address(usdc), ORACLE_MARK_1E8, block.timestamp, true);

        _setHealthyRisk(BUYER);
        _setHealthyRisk(SELLER);

        _deposit(BUYER, 1_000_000 * BASE_UNIT);
        _deposit(SELLER, 1_000_000 * BASE_UNIT);
    }

    /*//////////////////////////////////////////////////////////////
             SCENARIO 1 — WASH TRADE FAR ABOVE INDEX
    //////////////////////////////////////////////////////////////*/

    /// @notice Path (a): even the authorized matching-engine EOA cannot push
    ///         a wash trade at 10x oracle mark through the direct
    ///         `applyTrade` entrypoint. The Part A protocol guard blocks it
    ///         before any state mutation.
    function testCollusionExecutionPriceFarAboveIndexRevertsOnDirectApplyTrade() external {
        _asDirectMatcher();

        vm.prank(DIRECT_MATCHER);
        vm.expectRevert(PerpEngineTypes.ExecutionPriceOutOfBand.selector);
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: BUYER,
                seller: SELLER,
                marketId: marketId,
                sizeDelta1e8: ONE,
                executionPrice1e8: uint128(ATTACK_PRICE_10X_ABOVE_1E8),
                buyerIsMaker: false
            })
        );

        // No position mutation, no realized PnL fabricated.
        assertEq(engine.positions(BUYER, marketId).size1e8, 0);
        assertEq(engine.positions(SELLER, marketId).size1e8, 0);
    }

    /// @notice Path (b): two colluding EOAs sign a valid V2 PerpTrade (both
    ///         user bounds = 0 = strict, so signatures validate) and the
    ///         matcher tries to execute at 10x oracle mark. The user-bound
    ///         checks are inert (bound == 0), but `applyTrade` downstream
    ///         reverts with `ExecutionPriceOutOfBand`.
    function testCollusionExecutionPriceFarAboveIndexRevertsThroughFullMatchingFlow() external {
        _asContractMatcher();

        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade({
            executionPrice1e8: uint128(ATTACK_PRICE_10X_ABOVE_1E8),
            maxExecutionPrice1e8: 0,
            minExecutionPrice1e8: 0
        });

        vm.prank(OWNER);
        vm.expectRevert(PerpEngineTypes.ExecutionPriceOutOfBand.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(engine.positions(BUYER, marketId).size1e8, 0);
        assertEq(engine.positions(SELLER, marketId).size1e8, 0);
        // Nonces should NOT be consumed — matching engine reverts propagate
        // BEFORE `_consumeNonces`? Actually `_consumeNonces` runs before
        // `applyTrade`, so the txn revert unwinds ALL state (nonces included).
        assertEq(matchingEngine.nonces(BUYER), 0);
        assertEq(matchingEngine.nonces(SELLER), 0);
    }

    /*//////////////////////////////////////////////////////////////
             SCENARIO 2 — WASH TRADE FAR BELOW INDEX
    //////////////////////////////////////////////////////////////*/

    /// @notice Symmetric to Scenario 1: colluding parties try 1/10 of the
    ///         oracle mark on the direct-EOA path. Same protocol guard fires.
    function testCollusionExecutionPriceFarBelowIndexRevertsOnDirectApplyTrade() external {
        _asDirectMatcher();

        vm.prank(DIRECT_MATCHER);
        vm.expectRevert(PerpEngineTypes.ExecutionPriceOutOfBand.selector);
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: BUYER,
                seller: SELLER,
                marketId: marketId,
                sizeDelta1e8: ONE,
                executionPrice1e8: uint128(ATTACK_PRICE_10X_BELOW_1E8),
                buyerIsMaker: false
            })
        );

        assertEq(engine.positions(BUYER, marketId).size1e8, 0);
        assertEq(engine.positions(SELLER, marketId).size1e8, 0);
    }

    /// @notice Symmetric to Scenario 1 on the full matching flow.
    function testCollusionExecutionPriceFarBelowIndexRevertsThroughFullMatchingFlow() external {
        _asContractMatcher();

        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade({
            executionPrice1e8: uint128(ATTACK_PRICE_10X_BELOW_1E8),
            maxExecutionPrice1e8: 0,
            minExecutionPrice1e8: 0
        });

        vm.prank(OWNER);
        vm.expectRevert(PerpEngineTypes.ExecutionPriceOutOfBand.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(engine.positions(BUYER, marketId).size1e8, 0);
        assertEq(engine.positions(SELLER, marketId).size1e8, 0);
        assertEq(matchingEngine.nonces(BUYER), 0);
        assertEq(matchingEngine.nonces(SELLER), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ SWEEP OF ATTACK PRICES
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz: any execution price OUTSIDE the 2% band MUST revert on
    ///         the direct-apply path, regardless of magnitude.
    /// @dev Restricted to price ranges well outside the band on both sides.
    function testFuzz_collusionAnyPriceOutsideBandReverts(uint256 execPrice1e8) external {
        _asDirectMatcher();

        // Guard band = 2% of 2_000 * 1e8 = 40 * 1e8. Anything > 2_040 * 1e8
        // or < 1_960 * 1e8 must revert. Bound the fuzz far outside the band
        // on either side.
        execPrice1e8 = bound(execPrice1e8, 1, ORACLE_MARK_1E8 * 100);
        uint256 upperBand = (ORACLE_MARK_1E8 * (10_000 + GUARD_BAND_BPS)) / 10_000; // 2_040 * 1e8
        uint256 lowerBand = (ORACLE_MARK_1E8 * (10_000 - GUARD_BAND_BPS)) / 10_000; // 1_960 * 1e8

        // Restrict to strictly outside the band.
        if (execPrice1e8 >= lowerBand && execPrice1e8 <= upperBand) return;
        if (execPrice1e8 == 0) return;

        vm.prank(DIRECT_MATCHER);
        vm.expectRevert(PerpEngineTypes.ExecutionPriceOutOfBand.selector);
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: BUYER,
                seller: SELLER,
                marketId: marketId,
                sizeDelta1e8: ONE,
                executionPrice1e8: uint128(execPrice1e8),
                buyerIsMaker: false
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Rewires the perp engine so the direct-EOA matcher can call
    ///      `applyTrade`. Used by path (a) tests.
    function _asDirectMatcher() internal {
        vm.prank(OWNER);
        engine.setMatchingEngine(DIRECT_MATCHER);
    }

    /// @dev Rewires the perp engine so the real `PerpMatchingEngine`
    ///      contract is the authorized matcher. Used by path (b) tests.
    function _asContractMatcher() internal {
        vm.prank(OWNER);
        engine.setMatchingEngine(address(matchingEngine));
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
