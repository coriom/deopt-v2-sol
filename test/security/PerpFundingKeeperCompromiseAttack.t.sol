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

/*//////////////////////////////////////////////////////////////
                          LOCAL MOCKS
//////////////////////////////////////////////////////////////*/

contract FKMockERC20 is ERC20 {
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

contract FKMockOracle is IOracle {
    function getPrice(address, address) external pure returns (uint256, uint256) {
        revert("unmocked");
    }

    function getPriceSafe(address, address) external pure returns (uint256, uint256, bool) {
        revert("unmocked");
    }
}

contract FKMockPerpRiskModule is IPerpRiskModule {
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

/// @title PerpFundingKeeperCompromiseAttackTest
/// @notice PERPS-PRICING-AND-EXECUTION-SAFETY-CORE-V1 security matrix — Scenario 13.
/// @dev
///  Security narrative: a compromised / rogue impact-mid keeper publishes
///  an ABSURD spike (e.g. `impactMid = 2x` the index) one sample before the
///  next funding interval fires. The `_fundingRatePerInterval1e18` output
///  MUST be clamped to `maxFundingRateBps` regardless of the sample
///  magnitude, so the attacker cannot bleed traders faster than governance
///  has authorized.
///
///  Complementary existing coverage:
///    - `test/perp/PerpEngineFundingV2.t.sol::testCapClampsFundingRate` —
///      unit test for the clamp math at a fixed 10% premium.
///    - `test/perp/PerpEngineFundingV2.t.sol::testFuzz_manipulationBoundedByCap`
///      — fuzz sweep of ABOVE-cap premiums.
///
///  This suite ADDS a narratively-explicit attack walkthrough
///  (`testCompromisedKeeperCannotBleedFasterThanCap`) plus a couple of
///  boundary-focused assertions, so the security matrix has a direct
///  "compromised keeper" entry rather than only the math-focused entries.
contract PerpFundingKeeperCompromiseAttackTest is Test {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 internal constant ETH_PERP_SYMBOL = 0x4554482d50455250000000000000000000000000000000000000000000000000;
    uint256 internal constant BASE_UNIT = 1e6;
    int256 internal constant HUGE_EQUITY_BASE = 1_000_000 * 1e6;
    uint128 internal constant ONE = 1e8;

    uint32 internal constant FUNDING_INTERVAL = 1 hours;
    uint32 internal constant DEFAULT_IMPACT_MID_MAX_DELAY = 3600;

    // Configured funding cap: 0.5% per interval.
    uint32 internal constant ATTACK_CAP_BPS = 50;
    int256 internal constant ATTACK_CAP_RATE_1E18 = 5e15; // 50 bps == 0.005 == 5e15 in 1e18

    // Index oracle mark used across the attack narrative.
    uint128 internal constant INDEX_PRICE_1E8 = 2_000 * 1e8;

    // Attacker-published values.
    uint128 internal constant SPIKE_2X_1E8 = 4_000 * 1e8; // 100% above index
    uint128 internal constant SPIKE_1P5X_1E8 = 3_000 * 1e8; // 50% above index
    uint128 internal constant SPIKE_HALF_1E8 = 1_000 * 1e8; // 50% below index

    address internal constant OWNER = address(0xA11CE);
    address internal constant MATCHING_ENGINE = address(0xBEEF);
    address internal constant COMPROMISED_KEEPER = address(0xBAD1);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    CollateralVault internal vault;
    PerpMarketRegistry internal registry;
    PerpEngine internal engine;
    FKMockOracle internal oracle;
    FKMockPerpRiskModule internal riskModule;

    FKMockERC20 internal usdc;
    FKMockERC20 internal weth;

    uint256 internal marketId;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        vault = new CollateralVault(OWNER);
        registry = new PerpMarketRegistry(OWNER);
        oracle = new FKMockOracle();
        usdc = new FKMockERC20("Mock USDC", "mUSDC", 6);
        weth = new FKMockERC20("Mock WETH", "mWETH", 18);

        riskModule = new FKMockPerpRiskModule(address(usdc), 6);
        engine = new PerpEngine(OWNER, address(registry), address(vault), address(oracle));

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setAuthorizedEngine(address(engine), true);

        registry.setSettlementAssetAllowed(address(usdc), true);
        marketId = registry.createMarket(
            address(weth),
            address(usdc),
            address(0),
            ETH_PERP_SYMBOL,
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
                isEnabled: true,
                fundingInterval: FUNDING_INTERVAL,
                maxFundingRateBps: ATTACK_CAP_BPS, // 0.5% funding cap
                maxSkewFundingBps: 0,
                oracleClampBps: 0,
                impactMidMaxDelay: DEFAULT_IMPACT_MID_MAX_DELAY
            })
        );
        registry.setMaxExecutionDeviationBps(marketId, 10_000);

        engine.setMatchingEngine(MATCHING_ENGINE);
        engine.setRiskModule(address(riskModule));

        // Explicitly install the "compromised" keeper as the trusted source.
        // In production this is a hardware-secured EOA; the attack narrative
        // assumes it has been compromised.
        engine.setImpactMidSource(COMPROMISED_KEEPER);
        vm.stopPrank();

        _setHealthyRisk(ALICE);
        _setHealthyRisk(BOB);
        _deposit(ALICE, 100_000 * BASE_UNIT);
        _deposit(BOB, 100_000 * BASE_UNIT);
    }

    /*//////////////////////////////////////////////////////////////
              SCENARIO 13 — COMPROMISED KEEPER SPIKE
    //////////////////////////////////////////////////////////////*/

    /// @notice Narrative attack:
    ///           1. Governance deploys the market with `maxFundingRateBps=50`
    ///              (0.5% per interval).
    ///           2. Governance authorizes a trusted keeper EOA to publish
    ///              impact-mid samples.
    ///           3. The keeper is compromised.
    ///           4. Just before the next funding interval, the attacker
    ///              publishes `impactMid = 2x index` (100% premium).
    ///           5. `updateFunding` is called at interval boundary.
    ///           6. Invariant: |funding rate| MUST equal exactly the cap
    ///              (`5e15` == 50 bps == 0.5%) regardless of the sample.
    ///
    ///         This proves the attacker cannot bleed traders faster than the
    ///         governance-configured cap allows, per the security matrix
    ///         Scenario 13 requirement.
    function testCompromisedKeeperCannotBleedFasterThanCap() external {
        // Step 1: seed the funding update timestamp so `warp` produces a
        // fresh interval boundary at step 5.
        engine.updateFunding(marketId);

        // Step 2: advance to just before the next interval boundary.
        vm.warp(block.timestamp + FUNDING_INTERVAL);

        // Step 3: mock the index oracle at a normal mark.
        _mockIndex(INDEX_PRICE_1E8);

        // Step 4: compromised keeper publishes the 2x spike.
        vm.prank(COMPROMISED_KEEPER);
        engine.updateImpactMid(marketId, SPIKE_2X_1E8);

        // Step 5: fire the funding update.
        (int256 delta, int256 nextCum) = engine.updateFunding(marketId);

        // Step 6: |rate| MUST equal exactly the cap.
        int256 absDelta = delta >= 0 ? delta : -delta;
        assertEq(absDelta, ATTACK_CAP_RATE_1E18, "compromised-keeper spike must saturate the cap exactly");
        assertGt(delta, 0, "positive-premium spike must produce positive rate");

        // Cumulative rate must reflect exactly one capped step.
        assertEq(nextCum, ATTACK_CAP_RATE_1E18, "cumulative rate must be exactly one capped step");
    }

    /// @notice Attack variant: compromised keeper publishes a NEGATIVE spike
    ///         (impact-mid at HALF the index) to shove funding hard-negative
    ///         and drain shorts.
    function testCompromisedKeeperCannotBleedFasterThanCapOnNegativeSpike() external {
        engine.updateFunding(marketId);
        vm.warp(block.timestamp + FUNDING_INTERVAL);

        _mockIndex(INDEX_PRICE_1E8);

        vm.prank(COMPROMISED_KEEPER);
        engine.updateImpactMid(marketId, SPIKE_HALF_1E8);

        (int256 delta,) = engine.updateFunding(marketId);
        int256 absDelta = delta >= 0 ? delta : -delta;

        assertEq(absDelta, ATTACK_CAP_RATE_1E18, "negative spike must saturate the cap in absolute terms");
        assertLt(delta, 0, "negative-premium spike must produce negative rate");
    }

    /// @notice Attack variant: keeper publishes a moderate (but still
    ///         above-cap) 1.5x spike. Same clamp behaviour — the cap does
    ///         not scale with sample magnitude.
    function testCompromisedKeeperModerateSpikeStillClampedToCap() external {
        engine.updateFunding(marketId);
        vm.warp(block.timestamp + FUNDING_INTERVAL);

        _mockIndex(INDEX_PRICE_1E8);

        vm.prank(COMPROMISED_KEEPER);
        engine.updateImpactMid(marketId, SPIKE_1P5X_1E8);

        (int256 delta,) = engine.updateFunding(marketId);
        assertEq(delta, ATTACK_CAP_RATE_1E18, "moderate above-cap spike still clamps exactly at cap");
    }

    /// @notice Attack variant: keeper attempts to publish repeatedly across
    ///         MULTIPLE consecutive intervals (5 back-to-back spikes). Total
    ///         cumulative funding MUST be exactly `N * cap`, not `N *
    ///         attackerMagnitude`. This proves the cap composes correctly
    ///         under sustained attacker pressure.
    function testCompromisedKeeperSustainedAttackBoundedByNCap() external {
        engine.updateFunding(marketId);

        int256 expectedCum = 0;
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + FUNDING_INTERVAL);
            _mockIndex(INDEX_PRICE_1E8);

            vm.prank(COMPROMISED_KEEPER);
            engine.updateImpactMid(marketId, SPIKE_2X_1E8);

            (int256 delta,) = engine.updateFunding(marketId);
            assertEq(delta, ATTACK_CAP_RATE_1E18, "each intervening step must saturate exactly at cap");

            expectedCum += ATTACK_CAP_RATE_1E18;
        }

        // Final cumulative rate reflects N * cap, not N * attackerMagnitude.
        int256 actualCum = engine.marketState(marketId).cumulativeFundingRate1e18;
        assertEq(actualCum, expectedCum, "cumulative rate over N intervals must be N * cap");
    }

    /*//////////////////////////////////////////////////////////////
                    FUZZ: ARBITRARY ATTACK MAGNITUDES
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz over the attacker-controlled impact-mid value across a
    ///         wide above-cap band. `|rate|` MUST never exceed the cap.
    function testFuzz_compromisedKeeperAnyAboveCapSpikeBoundedByCap(uint128 spike1e8) external {
        // Bound the spike ABOVE the cap+safety margin so we deterministically
        // hit the clamp regardless of any deadband. The `ATTACK_CAP_BPS=50`
        // gives 0.5% cap; anything above ~1% premium always clamps.
        uint256 minSpike = uint256(INDEX_PRICE_1E8) + (uint256(INDEX_PRICE_1E8) * 200) / 10_000; // +2%
        uint256 maxSpike = uint256(INDEX_PRICE_1E8) * 100; // 100x index
        spike1e8 = uint128(bound(uint256(spike1e8), minSpike, maxSpike));

        engine.updateFunding(marketId);
        vm.warp(block.timestamp + FUNDING_INTERVAL);
        _mockIndex(INDEX_PRICE_1E8);

        vm.prank(COMPROMISED_KEEPER);
        engine.updateImpactMid(marketId, spike1e8);

        (int256 delta,) = engine.updateFunding(marketId);
        int256 absDelta = delta >= 0 ? delta : -delta;
        assertLe(absDelta, ATTACK_CAP_RATE_1E18, "|rate| must not exceed the configured cap under any spike");
        assertEq(delta, ATTACK_CAP_RATE_1E18, "above-cap spike must clamp exactly at cap");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _mockIndex(uint128 indexPrice1e8) internal {
        bytes memory callData =
            abi.encodeWithSignature("getPriceSafe(address,address)", address(weth), address(usdc));
        vm.mockCall(address(oracle), callData, abi.encode(uint256(indexPrice1e8), block.timestamp, true));
    }

    function _deposit(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    function _setHealthyRisk(address trader) internal {
        riskModule.setAccountRisk(trader, HUGE_EQUITY_BASE, 0, 0);
    }
}
