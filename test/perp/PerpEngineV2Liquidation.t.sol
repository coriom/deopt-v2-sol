// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

// PERPS_V2_ENGINE_SIZE_REDUCTION_B_COLD_PATH_EXTRACT_V1 §3-§4 —
// pre-refactor liquidation golden tests for PerpEngineV2.
//
// Purpose: lock in observable V2 liquidation behavior BEFORE the
// PerpEngineLiquidationLib extraction so the extraction can be
// proven bit-for-bit equivalent.
//
// Scope: minimal deterministic coverage of the §3 invariants that
// matter for the extraction — healthy-not-liquidatable, partial
// liquidation with size + OI + position accounting, close-factor
// clamp, migration-OPEN block, self-liquidation refusal, and V2
// clearing-account flow.
//
// NOTE: rich seize / insurance-fund / residual-bad-debt paths are
// covered by V1's `test/unit/perp/PerpEngineLiquidation.t.sol` at
// the engine level. Those helpers are shared internal helpers that
// V2 inherits verbatim; the V2-side extraction preserves the same
// helpers via the same call graph. We do NOT duplicate that full
// matrix here — the goal is to lock the V2-specific orchestration
// (clearing-account cashflow + migration gate + V2 event surface).

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {IOracle} from "../../src/oracle/IOracle.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";
import {PerpEngineTypes} from "../../src/perp/PerpEngineTypes.sol";
import {PerpMarketRegistry} from "../../src/perp/PerpMarketRegistry.sol";
import {IPerpRiskModule} from "../../src/perp/PerpEngineStorage.sol";
import {IPerpEngineTrade} from "../../src/matching/IPerpEngineTrade.sol";
import {PerpClearingAccountV2} from "../../src/perp/PerpClearingAccountV2.sol";

contract _MockERC20 is ERC20 {
    uint8 private immutable _DEC;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _DEC = d;
    }

    function decimals() public view override returns (uint8) {
        return _DEC;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract _MockOracle is IOracle {
    struct P {
        uint256 price;
        uint256 updatedAt;
        bool ok;
    }

    mapping(bytes32 => P) internal p;

    function setPrice(address base, address quote, uint256 price, uint256 updatedAt, bool ok) external {
        p[keccak256(abi.encode(base, quote))] = P(price, updatedAt, ok);
    }

    function getPrice(address base, address quote) external view returns (uint256, uint256) {
        P memory d = p[keccak256(abi.encode(base, quote))];
        require(d.ok, "no-price");
        return (d.price, d.updatedAt);
    }

    function getPriceSafe(address base, address quote) external view returns (uint256, uint256, bool) {
        P memory d = p[keccak256(abi.encode(base, quote))];
        return (d.price, d.updatedAt, d.ok);
    }
}

contract _MockRisk is IPerpRiskModule {
    address public immutable baseCollateralToken;
    uint8 public immutable baseDecimals;

    mapping(address => AccountRisk) internal risks;

    constructor(address b, uint8 d) {
        baseCollateralToken = b;
        baseDecimals = d;
    }

    function setAccountRisk(address t, int256 e, uint256 mm, uint256 im) external {
        risks[t] = AccountRisk(e, mm, im);
    }

    function computeAccountRisk(address t) external view returns (AccountRisk memory r) {
        r = risks[t];
    }

    function computeFreeCollateral(address t) external view returns (int256) {
        AccountRisk memory r = risks[t];
        return r.equityBase - int256(r.initialMarginBase);
    }

    function previewWithdrawImpact(address, address, uint256 amount)
        external
        pure
        returns (WithdrawPreview memory p)
    {
        p.requestedAmount = amount;
        p.maxWithdrawable = amount;
    }

    function getWithdrawableAmount(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

contract _MockInsuranceFund {
    CollateralVault public immutable VAULT;

    constructor(address v) {
        VAULT = CollateralVault(v);
    }

    function depositToVault(address token, uint256 amount) external {
        ERC20(token).approve(address(VAULT), amount);
        VAULT.deposit(token, amount);
    }

    function coverVaultShortfall(address token, address to, uint256 requested) external returns (uint256 paid) {
        uint256 avail = VAULT.balances(address(this), token);
        paid = requested <= avail ? requested : avail;
        if (paid != 0) VAULT.transferBetweenAccounts(token, address(this), to, paid);
    }
}

contract PerpEngineV2LiquidationTest is Test {
    // Actors
    address internal constant OWNER = address(0xA11CE);
    address internal constant MATCHING = address(0xBEEF);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);
    address internal constant CAROL = address(0xC3);

    // Constants
    uint128 internal constant ONE = 1e8;
    uint128 internal constant TWO = 2e8;
    uint128 internal constant FOUR = 4e8;
    uint256 internal constant BASE_UNIT = 1e6;
    uint128 internal constant ENTRY_PRICE = 2_000 * 1e8;
    uint256 internal constant MARK_PRICE = 2_000 * 1e8;

    // Risk states
    int256 internal constant HEALTHY_EQUITY = 1_000_000 * 1e6;
    int256 internal constant LIQUIDATABLE_EQUITY = 90 * 1e6;
    uint256 internal constant LIQUIDATABLE_MM = 100 * 1e6;
    int256 internal constant IMPROVED_EQUITY = 100 * 1e6;
    uint256 internal constant IMPROVED_MM = 90 * 1e6;

    // Contracts
    CollateralVault internal vault;
    PerpMarketRegistry internal registry;
    PerpEngineV2 internal engine;
    _MockOracle internal oracle;
    _MockRisk internal risk;
    _MockInsuranceFund internal insurance;
    PerpClearingAccountV2 internal clearing;
    _MockERC20 internal usdc;
    _MockERC20 internal weth;

    uint256 internal marketId;

    function setUp() public {
        vault = new CollateralVault(OWNER);
        registry = new PerpMarketRegistry(OWNER);
        oracle = new _MockOracle();
        usdc = new _MockERC20("Mock USDC", "mUSDC", 6);
        weth = new _MockERC20("Mock WETH", "mWETH", 18);
        risk = new _MockRisk(address(usdc), 6);
        insurance = new _MockInsuranceFund(address(vault));

        engine = new PerpEngineV2(OWNER, address(registry), address(vault), address(oracle));

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setCollateralToken(address(weth), true, 18, 10_000);
        vault.setAuthorizedEngine(address(engine), true);
        vault.setAuthorizedEngine(address(insurance), true);

        registry.setSettlementAssetAllowed(address(usdc), true);
        marketId = registry.createMarket(
            address(weth),
            address(usdc),
            address(0),
            bytes32("ETH-PERP-V2-LIQ"),
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
        registry.setMaxExecutionDeviationBps(marketId, 10_000);

        engine.setMatchingEngine(MATCHING);
        engine.setRiskModule(address(risk));
        engine.setInsuranceFund(address(insurance));
        vm.stopPrank();

        clearing = new PerpClearingAccountV2(address(vault));
        vm.prank(OWNER);
        engine.setClearingAccount(address(clearing));

        oracle.setPrice(address(weth), address(usdc), MARK_PRICE, block.timestamp, true);

        risk.setAccountRisk(ALICE, HEALTHY_EQUITY, 0, 0);
        risk.setAccountRisk(BOB, HEALTHY_EQUITY, 0, 0);
        risk.setAccountRisk(CAROL, HEALTHY_EQUITY, 0, 0);
        risk.setAccountRisk(address(clearing), HEALTHY_EQUITY, 0, 0);

        // Fund the clearing account via the canonical funding path
        // (funder mints raw tokens, approves clearing, calls fundClearing —
        // clearing pulls tokens and deposits them into its own Vault sub-ledger).
        usdc.mint(address(0xF00D), 1_000_000 * BASE_UNIT);
        vm.startPrank(address(0xF00D));
        usdc.approve(address(clearing), 1_000_000 * BASE_UNIT);
        clearing.fundClearing(address(usdc), 1_000_000 * BASE_UNIT);
        vm.stopPrank();
    }

    // §3.14 — liquidation blocked while migration is OPEN.
    function test_MigrationOpen_BlocksLiquidation() external {
        // Note: setUp() has not yet sealed. Simulate that gate.
        // We call liquidate before seal → must revert with MigrationNotSealed.
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSignature("MigrationNotSealed()"));
        engine.liquidate(ALICE, marketId, ONE);
    }

    // §3.1 — healthy trader cannot be liquidated (after seal).
    function test_Healthy_NotLiquidatable() external {
        _seal();
        _depositUsdc(ALICE, 1_000 * BASE_UNIT);
        _openLong(ALICE, BOB, TWO);

        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSignature("NotLiquidatable()"));
        engine.liquidate(ALICE, marketId, ONE);
    }

    // §3.2/§3.4/§3.5/§3.11 — liquidatable trader can be partially liquidated;
    // positions/OI shift correctly; clearing conservation holds.
    function test_Liquidatable_PartialClose_ClearingFlow() external {
        _seal();
        _depositUsdc(ALICE, 1_000 * BASE_UNIT);
        _openLong(ALICE, BOB, TWO);
        _mockImprovingRisk(ALICE);

        int256 aliceBefore = int256(vault.balances(ALICE, address(usdc)));
        int256 carolBefore = int256(vault.balances(CAROL, address(usdc)));
        int256 clearingBefore = int256(vault.balances(address(clearing), address(usdc)));

        vm.prank(CAROL);
        engine.liquidate(ALICE, marketId, ONE);

        // Positions post-liquidation
        PerpEngineTypes.Position memory aliceP = engine.positions(ALICE, marketId);
        PerpEngineTypes.Position memory carolP = engine.positions(CAROL, marketId);
        assertEq(aliceP.size1e8, int256(uint256(ONE)), "alice size not clipped");
        assertEq(carolP.size1e8, int256(uint256(ONE)), "carol size not credited");

        // OI reconstructs: aggregate exposure moved from Alice-only to (Alice + Carol)
        assertEq(engine.totalAbsLongSize1e8(ALICE), uint256(ONE), "alice long agg");
        assertEq(engine.totalAbsLongSize1e8(CAROL), uint256(ONE), "carol long agg");

        // No residual bad debt (seizer + insurance not needed at this scenario).
        assertEq(engine.getResidualBadDebt(ALICE), 0, "no residual bad debt");

        // Clearing conservation: sum of deltas across all touched accounts = 0.
        int256 aliceDelta = int256(vault.balances(ALICE, address(usdc))) - aliceBefore;
        int256 carolDelta = int256(vault.balances(CAROL, address(usdc))) - carolBefore;
        int256 clearingDelta = int256(vault.balances(address(clearing), address(usdc))) - clearingBefore;
        assertEq(aliceDelta + carolDelta + clearingDelta, int256(0), "conservation broken");
    }

    // §3.6 — liquidation respects the close-factor clamp.
    function test_CloseFactor_ClampedTo5000Bps() external {
        _seal();
        _depositUsdc(ALICE, 2_000 * BASE_UNIT);
        _openLong(ALICE, BOB, FOUR);
        _mockImprovingRisk(ALICE);

        vm.prank(CAROL);
        engine.liquidate(ALICE, marketId, FOUR); // Requests 4; close-factor 50% caps at 2.

        assertEq(engine.positions(ALICE, marketId).size1e8, int256(uint256(TWO)), "alice size after clamp");
        assertEq(engine.positions(CAROL, marketId).size1e8, int256(uint256(TWO)), "carol size after clamp");
    }

    // §3.14 — self-liquidation refused.
    function test_SelfLiquidation_Refused() external {
        _seal();
        _depositUsdc(ALICE, 1_000 * BASE_UNIT);
        _openLong(ALICE, BOB, TWO);
        _mockImprovingRisk(ALICE);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSignature("LiquidationSelfNotAllowed()"));
        engine.liquidate(ALICE, marketId, ONE);
    }

    // ---------------- helpers ----------------

    function _seal() internal {
        vm.prank(OWNER);
        engine.sealMigration(bytes32(uint256(0xC01D5EA1)));
    }

    function _openLong(address t, address cp, uint128 size1e8) internal {
        vm.prank(MATCHING);
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: t,
                seller: cp,
                marketId: marketId,
                sizeDelta1e8: size1e8,
                executionPrice1e8: ENTRY_PRICE,
                buyerIsMaker: false
            })
        );
    }

    function _depositUsdc(address u, uint256 amt) internal {
        usdc.mint(u, amt);
        vm.startPrank(u);
        usdc.approve(address(vault), amt);
        vault.deposit(address(usdc), amt);
        vm.stopPrank();
    }

    function _mockImprovingRisk(address t) internal {
        // PERPS_V2_ENGINE_SIZE_REDUCTION_C_FINAL_IMPLEMENTATION_V1 §10 —
        // the refactored `liquidate()` wrapper reads the trader's risk state
        // exactly twice (once for `traderBefore`, once for `traderAfter`
        // after cashflow settlement), deduplicating the pre-refactor redundant
        // read done by the now-inlined `_isTraderLiquidatable` predicate.
        bytes memory sel = abi.encodeWithSelector(IPerpRiskModule.computeAccountRisk.selector, t);
        bytes[] memory rets = new bytes[](2);
        rets[0] = abi.encode(IPerpRiskModule.AccountRisk(LIQUIDATABLE_EQUITY, LIQUIDATABLE_MM, 0));
        rets[1] = abi.encode(IPerpRiskModule.AccountRisk(IMPROVED_EQUITY, IMPROVED_MM, 0));
        vm.mockCalls(address(risk), sel, rets);
    }
}
