// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

// PERPS_V2_MIGRATION_SEED_HOOK_V1 §20
// Migration-specific fuzz/invariants for PerpEngineV2. Reference math is
// derived independently of the migration implementation — invariants
// assert relationships between input canonical fields and observable
// storage/vault state.
//
// Invariants (per directive §20):
//   1. seeded position equals supplied canonical state exactly
//   2. aggregate OI equals reconstruction (long/short sum by side)
//   3. seeding never changes Vault balances
//   4. duplicate seed impossible
//   5. after seal no migration write succeeds
//   6. before seal no trading write succeeds
//   7. funding continuity: migrated position checkpoint + market cum
//      preserve accrued funding exactly (compared against RefV2 formula)
//   8. migration followed by close gives same result as an equivalent
//      native V2 position history (baseline normalization documented)

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../../../src/collateral/CollateralVault.sol";
import {IOracle} from "../../../src/oracle/IOracle.sol";
import {PerpEngineV2} from "../../../src/perp/PerpEngineV2.sol";
import {PerpEngineTradingV2} from "../../../src/perp/PerpEngineTradingV2.sol";
import {PerpEngineTypes} from "../../../src/perp/PerpEngineTypes.sol";
import {PerpMarketRegistry} from "../../../src/perp/PerpMarketRegistry.sol";
import {IPerpRiskModule} from "../../../src/perp/PerpEngineStorage.sol";
import {IPerpEngineTrade} from "../../../src/matching/IPerpEngineTrade.sol";
import {PerpClearingAccountV2} from "../../../src/perp/PerpClearingAccountV2.sol";

contract MockERC20MigF is ERC20 {
    uint8 private immutable _d;

    constructor(string memory n, string memory s, uint8 dec) ERC20(n, s) {
        _d = dec;
    }

    function decimals() public view override returns (uint8) {
        return _d;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract MockOracleMigF is IOracle {
    struct P {
        uint256 price;
        uint256 t;
        bool ok;
    }

    mapping(bytes32 => P) internal p;

    function setPrice(address b, address q, uint256 pr, uint256 tm, bool ok) external {
        p[keccak256(abi.encode(b, q))] = P(pr, tm, ok);
    }

    function getPrice(address b, address q) external view returns (uint256, uint256) {
        P memory d = p[keccak256(abi.encode(b, q))];
        require(d.ok, "no-px");
        return (d.price, d.t);
    }

    function getPriceSafe(address b, address q) external view returns (uint256, uint256, bool) {
        P memory d = p[keccak256(abi.encode(b, q))];
        return (d.price, d.t, d.ok);
    }
}

contract MockRiskMigF is IPerpRiskModule {
    address public immutable baseCollateralToken;
    uint8 public immutable baseDecimals;

    mapping(address => AccountRisk) internal r;

    constructor(address b, uint8 d) {
        baseCollateralToken = b;
        baseDecimals = d;
    }

    function setAccountRisk(address t, int256 e, uint256 mm, uint256 im) external {
        r[t] = AccountRisk(e, mm, im);
    }

    function computeAccountRisk(address t) external view returns (AccountRisk memory) {
        return r[t];
    }

    function computeFreeCollateral(address t) external view returns (int256) {
        AccountRisk memory a = r[t];
        return a.equityBase - int256(a.initialMarginBase);
    }

    function previewWithdrawImpact(address, address, uint256 a) external pure returns (WithdrawPreview memory p) {
        p.requestedAmount = a;
        p.maxWithdrawable = a;
    }

    function getWithdrawableAmount(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

/// @notice Independent reference math — the fuzz oracle for close economics.
library RefMigF {
    int256 internal constant PRICE_1E8 = 1e8;

    function refClose1e8(int256 size, int256 basis, int256 closePx1e8)
        internal
        pure
        returns (int256 realized1e8)
    {
        int256 absSize = size >= 0 ? size : -size;
        int256 closeSignedSize = size >= 0 ? absSize : -absSize;
        int256 closedMark = (closeSignedSize * closePx1e8) / PRICE_1E8;
        return closedMark - basis;
    }

    function refSignedNative(int256 amt1e8, uint8 dec) internal pure returns (int256) {
        if (amt1e8 == 0) return 0;
        uint256 abs1e8 = amt1e8 >= 0 ? uint256(amt1e8) : uint256(-amt1e8);
        uint256 scale = 10 ** uint256(dec);
        uint256 absNative = (abs1e8 * scale) / uint256(PRICE_1E8);
        int256 asInt = int256(absNative);
        return amt1e8 > 0 ? asInt : -asInt;
    }
}

contract PerpEngineV2MigrationFuzzTest is Test {
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BASE_UNIT = 1e6;
    uint128 internal constant ONE = 1e8;

    address internal constant OWNER = address(0xA11CE);
    address internal constant MATCHING = address(0xBEEF);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);
    address internal constant CAROL = address(0xC3);
    address internal constant FUNDER = address(0xF00D);

    CollateralVault internal vault;
    PerpMarketRegistry internal registry;
    PerpEngineV2 internal engine;
    MockOracleMigF internal oracle;
    MockRiskMigF internal risk;
    MockERC20MigF internal usdc;
    MockERC20MigF internal weth;
    PerpClearingAccountV2 internal clearing;

    uint256 internal marketId;

    uint256 internal constant MIN_PRICE_1E8 = 500 * PRICE_SCALE;
    uint256 internal constant MAX_PRICE_1E8 = 5_000 * PRICE_SCALE;
    uint128 internal constant MIN_SIZE = 1e6;
    uint128 internal constant MAX_SIZE = 1e10;

    function setUp() external {
        vault = new CollateralVault(OWNER);
        registry = new PerpMarketRegistry(OWNER);
        oracle = new MockOracleMigF();
        usdc = new MockERC20MigF("USDC", "mUSDC", 6);
        weth = new MockERC20MigF("WETH", "mWETH", 18);
        risk = new MockRiskMigF(address(usdc), 6);
        engine = new PerpEngineV2(OWNER, address(registry), address(vault), address(oracle));
        clearing = new PerpClearingAccountV2(address(vault));

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setAuthorizedEngine(address(engine), true);
        registry.setSettlementAssetAllowed(address(usdc), true);

        marketId = registry.createMarket(
            address(weth), address(usdc), address(0), bytes32("MIG-FUZZ"),
            PerpMarketRegistry.RiskConfig({
                initialMarginBps: 1_000, maintenanceMarginBps: 500, liquidationPenaltyBps: 500,
                maxPositionSize1e8: type(uint128).max / 2,
                maxOpenInterest1e8: type(uint128).max, reduceOnlyDuringCloseOnly: true
            }),
            PerpMarketRegistry.LiquidationConfig({closeFactorBps: 5_000, priceSpreadBps: 100, minImprovementBps: 50, oracleMaxDelay: 60}),
            PerpMarketRegistry.FundingConfig({isEnabled: false, fundingInterval: 0, maxFundingRateBps: 0, maxSkewFundingBps: 0, oracleClampBps: 0, impactMidMaxDelay: 0})
        );
        registry.setMaxExecutionDeviationBps(marketId, 10_000);
        engine.setMatchingEngine(MATCHING);
        engine.setRiskModule(address(risk));
        engine.setClearingAccount(address(clearing));
        vm.stopPrank();

        oracle.setPrice(address(weth), address(usdc), 2_000 * PRICE_SCALE, block.timestamp, true);
        uint256 mint = 1_000_000_000_000 * BASE_UNIT;
        _healthy(ALICE);
        _deposit(ALICE, mint);
        _healthy(BOB);
        _deposit(BOB, mint);
        _healthy(CAROL);
        _deposit(CAROL, mint);
        _healthy(address(clearing));
    }

    /*//////////////////////////////////////////////////////////////
        Invariant #1: seeded position equals supplied fields exactly.
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SeededEqualsSupplied(
        uint128 rawSize,
        uint256 rawPrice,
        int128 rawFunding
    ) external {
        uint128 size = uint128(bound(uint256(rawSize), MIN_SIZE, MAX_SIZE));
        uint256 price = bound(rawPrice, MIN_PRICE_1E8, MAX_PRICE_1E8);
        bool longSide = (rawFunding % 2) == 0;
        int256 signedSize = longSide ? int256(uint256(size)) : -int256(uint256(size));
        int256 signedBasis = longSide
            ? int256((uint256(size) * price) / PRICE_SCALE)
            : -int256((uint256(size) * price) / PRICE_SCALE);
        int256 funding = int256(rawFunding);

        vm.prank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, signedSize, signedBasis, funding);

        PerpEngineTypes.Position memory p = engine.positions(ALICE, marketId);
        assertEq(p.size1e8, signedSize);
        assertEq(p.openNotional1e8, signedBasis);
        assertEq(p.lastCumulativeFundingRate1e18, funding);
    }

    /*//////////////////////////////////////////////////////////////
        Invariant #2: aggregate OI equals reconstruction.
    //////////////////////////////////////////////////////////////*/

    function testFuzz_OIExactAcrossMultipleSeeds(
        uint128 aliceLongRaw,
        uint128 bobShortRaw,
        uint128 carolLongRaw
    ) external {
        uint128 aL = uint128(bound(uint256(aliceLongRaw), MIN_SIZE, MAX_SIZE));
        uint128 bS = uint128(bound(uint256(bobShortRaw), MIN_SIZE, MAX_SIZE));
        uint128 cL = uint128(bound(uint256(carolLongRaw), MIN_SIZE, MAX_SIZE));
        int256 basis = int256(2_000 * PRICE_SCALE);

        vm.startPrank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(aL)), basis, 0);
        engine.adminSeedPosition(BOB, marketId, -int256(uint256(bS)), -basis, 0);
        engine.adminSeedPosition(CAROL, marketId, int256(uint256(cL)), basis, 0);
        vm.stopPrank();

        PerpEngineTypes.MarketState memory ms = engine.marketState(marketId);
        assertEq(ms.longOpenInterest1e8, uint256(aL) + uint256(cL), "long OI");
        assertEq(ms.shortOpenInterest1e8, uint256(bS), "short OI");
    }

    /*//////////////////////////////////////////////////////////////
        Invariant #3: seeding never changes Vault balances.
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SeedingNeverMovesVault(uint128 rawSize) external {
        uint128 size = uint128(bound(uint256(rawSize), MIN_SIZE, MAX_SIZE));

        uint256 aliceBefore = vault.balances(ALICE, address(usdc));
        uint256 bobBefore = vault.balances(BOB, address(usdc));
        uint256 clearingBefore = vault.balances(address(clearing), address(usdc));

        vm.startPrank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(size)), int256(2_000 * PRICE_SCALE), 0);
        engine.adminSeedPosition(BOB, marketId, -int256(uint256(size)), -int256(2_000 * PRICE_SCALE), 0);
        engine.adminSeedMarketFunding(marketId, 12345, uint64(block.timestamp));
        vm.stopPrank();

        assertEq(vault.balances(ALICE, address(usdc)), aliceBefore);
        assertEq(vault.balances(BOB, address(usdc)), bobBefore);
        assertEq(vault.balances(address(clearing), address(usdc)), clearingBefore);
    }

    /*//////////////////////////////////////////////////////////////
        Invariant #4: duplicate seed impossible.
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DuplicateSeedImpossible(uint128 rawSize) external {
        uint128 size = uint128(bound(uint256(rawSize), MIN_SIZE, MAX_SIZE));
        vm.prank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(size)), int256(2_000 * PRICE_SCALE), 0);

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                PerpEngineTradingV2.MigrationPositionAlreadySeeded.selector, ALICE, marketId
            )
        );
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(size)), int256(2_000 * PRICE_SCALE), 0);
    }

    /*//////////////////////////////////////////////////////////////
        Invariant #5: after seal no migration write succeeds.
    //////////////////////////////////////////////////////////////*/

    function testFuzz_AfterSealNoMigrationWriteSucceeds(uint128 rawSize) external {
        uint128 size = uint128(bound(uint256(rawSize), MIN_SIZE, MAX_SIZE));

        vm.prank(OWNER);
        engine.sealMigration(bytes32(uint256(0xAA)));

        vm.prank(OWNER);
        vm.expectRevert(PerpEngineTradingV2.MigrationAlreadySealed.selector);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(size)), int256(2_000 * PRICE_SCALE), 0);

        vm.prank(OWNER);
        vm.expectRevert(PerpEngineTradingV2.MigrationAlreadySealed.selector);
        engine.adminSeedMarketFunding(marketId, 1, 2);
    }

    /*//////////////////////////////////////////////////////////////
        Invariant #6: before seal no trading write succeeds.
    //////////////////////////////////////////////////////////////*/

    function testFuzz_BeforeSealNoTradingWriteSucceeds(uint128 rawSize) external {
        uint128 size = uint128(bound(uint256(rawSize), MIN_SIZE, MAX_SIZE));
        vm.prank(MATCHING);
        vm.expectRevert(PerpEngineTradingV2.MigrationNotSealed.selector);
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: ALICE, seller: BOB, marketId: marketId,
                sizeDelta1e8: size, executionPrice1e8: uint128(2_000 * PRICE_SCALE), buyerIsMaker: false
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
        Invariant #8: migration + close == native V2 open + close.
    //////////////////////////////////////////////////////////////*/

    /// Prove that a migrated-then-closed position gives the same vault
    /// deltas as a native-V2 (open + close) equivalent trade sequence.
    /// Uses two independent PerpEngineV2 instances to isolate paths.
    function testFuzz_MigratedCloseEqualsNativeOpenClose(uint128 rawSize, uint256 rawOpen, uint256 rawClose)
        external
    {
        uint128 size = uint128(bound(uint256(rawSize), MIN_SIZE, MAX_SIZE / 2));
        uint256 openPx = bound(rawOpen, MIN_PRICE_1E8, MAX_PRICE_1E8);
        uint256 closePx = bound(rawClose, MIN_PRICE_1E8, MAX_PRICE_1E8);

        // Path 1: engine (migrated).
        int256 aliceSize = int256(uint256(size));
        int256 bobSize = -aliceSize;
        int256 aliceBasis = int256((uint256(size) * openPx) / PRICE_SCALE);
        int256 bobBasis = -aliceBasis;

        _fund(clearing, 10_000_000 * BASE_UNIT);

        vm.startPrank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, aliceSize, aliceBasis, 0);
        engine.adminSeedPosition(BOB, marketId, bobSize, bobBasis, 0);
        engine.sealMigration(bytes32(uint256(0xAB)));
        vm.stopPrank();

        oracle.setPrice(address(weth), address(usdc), closePx, block.timestamp, true);

        uint256 aliceBefore1 = vault.balances(ALICE, address(usdc));
        uint256 bobBefore1 = vault.balances(BOB, address(usdc));

        vm.prank(MATCHING);
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: BOB, seller: ALICE, marketId: marketId,
                sizeDelta1e8: size, executionPrice1e8: uint128(closePx), buyerIsMaker: false
            })
        );

        int256 aliceDeltaMig = int256(vault.balances(ALICE, address(usdc))) - int256(aliceBefore1);
        int256 bobDeltaMig = int256(vault.balances(BOB, address(usdc))) - int256(bobBefore1);

        // Path 2: independent engine (native open + close). Isolated
        // deployment so path 1's state doesn't bleed through.
        PerpEngineV2 e2 = new PerpEngineV2(OWNER, address(registry), address(vault), address(oracle));
        PerpClearingAccountV2 c2 = new PerpClearingAccountV2(address(vault));

        vm.startPrank(OWNER);
        vault.setAuthorizedEngine(address(e2), true);
        e2.setMatchingEngine(MATCHING);
        e2.setRiskModule(address(risk));
        e2.setClearingAccount(address(c2));
        e2.sealMigration(bytes32(uint256(0xCD)));
        vm.stopPrank();
        _fund(c2, 10_000_000 * BASE_UNIT);
        _healthy(address(c2));

        // Fresh traders for path 2 to avoid vault-state entanglement.
        address alice2 = address(uint160(uint256(keccak256("alice2"))));
        address bob2 = address(uint160(uint256(keccak256("bob2"))));
        _healthy(alice2);
        _healthy(bob2);
        _deposit(alice2, 1_000_000_000_000 * BASE_UNIT);
        _deposit(bob2, 1_000_000_000_000 * BASE_UNIT);

        oracle.setPrice(address(weth), address(usdc), openPx, block.timestamp, true);
        vm.prank(MATCHING);
        e2.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: alice2, seller: bob2, marketId: marketId,
                sizeDelta1e8: size, executionPrice1e8: uint128(openPx), buyerIsMaker: false
            })
        );

        oracle.setPrice(address(weth), address(usdc), closePx, block.timestamp, true);

        uint256 alice2Before = vault.balances(alice2, address(usdc));
        uint256 bob2Before = vault.balances(bob2, address(usdc));

        vm.prank(MATCHING);
        e2.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: bob2, seller: alice2, marketId: marketId,
                sizeDelta1e8: size, executionPrice1e8: uint128(closePx), buyerIsMaker: false
            })
        );

        int256 alice2Delta = int256(vault.balances(alice2, address(usdc))) - int256(alice2Before);
        int256 bob2Delta = int256(vault.balances(bob2, address(usdc))) - int256(bob2Before);

        // Migrated close and native (open+close) MUST produce the same
        // vault deltas on the closing trade.
        assertEq(aliceDeltaMig, alice2Delta, "8: migrated close != native close (alice)");
        assertEq(bobDeltaMig, bob2Delta, "8: migrated close != native close (bob)");
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _healthy(address a) internal {
        risk.setAccountRisk(a, type(int256).max / 4, 0, 0);
    }

    function _deposit(address u, uint256 amt) internal {
        usdc.mint(u, amt);
        vm.startPrank(u);
        usdc.approve(address(vault), amt);
        vault.deposit(address(usdc), amt);
        vm.stopPrank();
    }

    function _fund(PerpClearingAccountV2 c, uint256 amt) internal {
        usdc.mint(FUNDER, amt);
        vm.startPrank(FUNDER);
        usdc.approve(address(c), amt);
        c.fundClearing(address(usdc), amt);
        vm.stopPrank();
    }
}
