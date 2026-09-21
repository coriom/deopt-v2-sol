// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IFeesManager} from "../fees/IFeesManager.sol";
import {IFeesManagerV2} from "../fees/IFeesManagerV2.sol";
import {IOracle} from "../oracle/IOracle.sol";
import "../matching/IPerpEngineTrade.sol";
import "../liquidation/ICollateralSeizer.sol";
import "./PerpEngineViews.sol";
import {PerpEngineSeizureLib} from "./PerpEngineSeizureLib.sol";
import {PerpEngineLiquidationLib} from "./PerpEngineLiquidationLib.sol";

/// @title PerpEngineTradingV2
/// @notice V2 perp trading entrypoint. Replaces V1's peer-to-peer realized
///         cashflow subtraction with per-side settlement through a
///         governance-designated clearing account.
/// @dev
///   V1's `_applyRealizedCashflow` computed
///     `netToBuyer = buyerRealized - sellerRealized`
///   which transferred 2x the correct amount whenever the two sides had
///   equal-and-opposite realized PnL (confirmed on Base Sepolia mutual
///   close: 488_548 mUSDC vs 244_274 economically correct).
///
///   V2 settles each side independently:
///     1. Traders with realized < 0 pay `|realized|` into `clearingAccount`.
///     2. Between (1) and (3) the clearing balance is checked against the
///        sum of pending credits; on shortfall the trade reverts atomically
///        with `ClearingLiquidityInsufficient`.
///     3. Traders with realized > 0 receive `realized` from `clearingAccount`
///        (via `_routeIncomingCashflowWithDebtFirst` so the V1 bad-debt
///        intercept still applies).
///
///   Global conservation:
///     Δvault(buyer) + Δvault(seller) + Δvault(clearing) = 0
///   for the pre-fee realized-PnL portion of any trade.
///
///   V1 files are semantically untouched. V2 skips V1's `PerpEngineTrading`
///   and inherits directly from V1's `PerpEngineViews`. Storage is a fresh
///   deployment; the appended `clearingAccount` slot lives beyond V1's
///   layout.
///
///   Domain-level V1/V2 signature-replay separation is enforced by
///   `PerpMatchingEngineV2`'s bumped EIP-712 version + fresh
///   `verifyingContract`.
abstract contract PerpEngineTradingV2 is PerpEngineViews, IPerpEngineTrade {
    /*//////////////////////////////////////////////////////////////
                        V2 CLEARING ACCOUNT STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Governance-designated address that acts as the settlement
    ///         intermediary for realized PnL.
    address public clearingAccount;

    /*//////////////////////////////////////////////////////////////
                    V2 ONE-TIME MIGRATION STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Migration lifecycle for a fresh V2 deployment.
    /// @dev
    ///   `OPEN` (initial, uint8(0)):
    ///     - operator may call `adminSeedPosition`, `adminSeedMarketFunding`,
    ///       and `adminSeedResidualBadDebt` under `onlyOwner`;
    ///     - `applyTrade` and `liquidate` revert with `MigrationNotSealed`
    ///       (V2 is not a partial-live engine during migration).
    ///   `SEALED` (irreversible, uint8(1)):
    ///     - all admin-seed paths revert with `MigrationSealed`;
    ///     - normal trading paths are enabled;
    ///     - `migrationSnapshotHash` is stored as an on-chain
    ///       commitment to the exact off-chain V1 snapshot the seeding
    ///       reproduced.
    ///
    /// See docs/PERPS_V2_MIGRATION_SEED_HOOK_V1.md.
    enum MigrationState {
        OPEN,
        SEALED
    }

    /// @notice Current migration lifecycle. Solidity default = OPEN (uint8(0)).
    MigrationState public migrationState;

    /// @notice keccak256 commitment to the off-chain V1 snapshot manifest
    ///         that this migration reproduces. Set exactly once at `sealMigration`.
    bytes32 public migrationSnapshotHash;

    /// @dev tracks trader/market pairs already seeded to reject duplicate writes.
    mapping(address => mapping(uint256 => bool)) internal _positionSeeded;

    /// @dev tracks markets whose funding state has been seeded to reject duplicate writes.
    mapping(uint256 => bool) internal _marketFundingSeeded;

    /// @dev tracks traders whose residual bad debt has been seeded to reject duplicate writes.
    mapping(address => bool) internal _residualBadDebtSeeded;

    /*//////////////////////////////////////////////////////////////
                          V2-SPECIFIC EVENTS
    //////////////////////////////////////////////////////////////*/

    event ClearingAccountSet(address indexed oldClearing, address indexed newClearing);

    event RealizedPnlSettledV2(
        address indexed settlementAsset,
        address indexed buyer,
        address indexed seller,
        address clearing,
        int256 buyerRealizedNative,
        int256 sellerRealizedNative
    );

    /// @notice Migration seed for a single (trader, market) canonical position.
    /// @dev All fields are the exact V1 snapshot values; V2 does NOT recompute
    ///      or normalize any of them.
    event MigrationPositionSeeded(
        address indexed trader,
        uint256 indexed marketId,
        int256 size1e8,
        int256 openNotional1e8,
        int256 lastCumulativeFundingRate1e18
    );

    /// @notice Migration seed for a per-market cumulative-funding baseline.
    event MigrationMarketFundingSeeded(
        uint256 indexed marketId,
        int256 cumulativeFundingRate1e18,
        uint64 lastFundingTimestamp
    );

    /// @notice Migration seed for a trader's residual bad-debt carryover.
    event MigrationResidualBadDebtSeeded(address indexed trader, uint256 amountBase);

    /// @notice Migration sealed — irreversible transition to normal trading.
    event MigrationSealed(bytes32 snapshotHash, address indexed sealer);

    /*//////////////////////////////////////////////////////////////
                          V2-SPECIFIC ERRORS
    //////////////////////////////////////////////////////////////*/

    error ClearingAccountNotSet();
    error ClearingAccountInvalid();
    error ClearingLiquidityInsufficient(
        address settlementAsset, address clearing, uint256 required, uint256 available
    );

    error MigrationNotSealed();
    error MigrationAlreadySealed();
    error MigrationPositionAlreadySeeded(address trader, uint256 marketId);
    error MigrationMarketFundingAlreadySeeded(uint256 marketId);
    error MigrationResidualBadDebtAlreadySeeded(address trader);
    error MigrationSnapshotHashZero();
    error MigrationInvalidSize();
    error MigrationInvalidBasisSign();
    error MigrationClearingNotConfigured();
    error MigrationMatchingEngineNotConfigured();
    error MigrationRiskModuleNotConfigured();

    /*//////////////////////////////////////////////////////////////
                          V2 ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Designates the settlement-clearing account.
    /// @dev
    ///   PERPS_V2_CLEARING_ACCOUNT_CONTRACT_V1 §6:
    ///   The clearing identity MUST be a contract (code.length > 0). This
    ///   rules out EOA clearing designations that could drain themselves
    ///   via `Vault.withdraw` or `Vault.transferFromInternalAccount`. In
    ///   production, the intended identity is `PerpClearingAccountV2`
    ///   whose surface is deposit-only.
    ///
    ///   The check is enforced at set-time only. Solidity 0.8.30 removes
    ///   SELFDESTRUCT's ability to reduce code.length in normal
    ///   deployments, so a positive check here is durable for the life
    ///   of the engine's clearing binding.
    function setClearingAccount(address newClearing) external onlyOwner {
        if (newClearing == address(0)) revert ZeroAddress();
        if (newClearing.code.length == 0) revert ClearingAccountInvalid();
        if (newClearing == owner) revert ClearingAccountInvalid();
        if (newClearing == address(this)) revert ClearingAccountInvalid();
        if (newClearing == matchingEngine) revert ClearingAccountInvalid();
        if (newClearing == feeRecipient) revert ClearingAccountInvalid();

        address old = clearingAccount;
        clearingAccount = newClearing;
        emit ClearingAccountSet(old, newClearing);
    }

    /*//////////////////////////////////////////////////////////////
                V2 ONE-TIME MIGRATION: MODIFIERS + ADMIN
    //////////////////////////////////////////////////////////////*/

    modifier onlyMigrationOpen() {
        if (migrationState != MigrationState.OPEN) revert MigrationAlreadySealed();
        _;
    }

    modifier onlyMigrationSealed() {
        if (migrationState != MigrationState.SEALED) revert MigrationNotSealed();
        _;
    }

    /// @notice Seeds one (trader, marketId) canonical position from a V1
    ///         snapshot. onlyOwner + onlyMigrationOpen. Duplicates rejected.
    /// @dev
    ///   Writes:
    ///     - `_positions[trader][marketId]` (exact V1 fields)
    ///     - `traderMarkets[trader]` / `traderMarketIndexPlus1[trader][marketId]`
    ///       (via existing `_syncPositionIndexing` helper)
    ///     - `totalAbsLongSize1e8[trader]` / `totalAbsShortSize1e8[trader]`
    ///       (via existing `_updateMarketOpenInterest` — which also writes
    ///        `_marketStates[marketId].longOpenInterest1e8` and
    ///        `.shortOpenInterest1e8`, so per-market OI is reconstructed
    ///        deterministically from the seeded positions themselves)
    ///
    ///   Emits `MigrationPositionSeeded`. Does NOT emit `TradeExecuted`
    ///   (migration is not a trade).
    ///
    ///   Reverts:
    ///     - `MigrationSealed` if called after `sealMigration`;
    ///     - `NotAuthorized` if caller != owner;
    ///     - `ZeroAddress` on trader == address(0);
    ///     - `InvalidMarket` if market registry does not know `marketId`;
    ///     - `MigrationInvalidSize` if `size1e8 == 0` (zero positions are
    ///        never migrated — they are simply absent);
    ///     - `MigrationInvalidBasisSign` if `openNotional1e8` sign is
    ///        inconsistent with `size1e8` sign (long has +basis, short
    ///        has -basis);
    ///     - `MigrationPositionAlreadySeeded` on duplicate.
    function adminSeedPosition(
        address trader,
        uint256 marketId,
        int256 size1e8,
        int256 openNotional1e8,
        int256 lastCumulativeFundingRate1e18
    ) external onlyOwner onlyMigrationOpen {
        if (trader == address(0)) revert ZeroAddress();
        _requireMarketExists(marketId);
        if (size1e8 == 0) revert MigrationInvalidSize();

        // Entry-basis invariant: sign(openNotional) == sign(size).
        if (size1e8 > 0 && openNotional1e8 <= 0) revert MigrationInvalidBasisSign();
        if (size1e8 < 0 && openNotional1e8 >= 0) revert MigrationInvalidBasisSign();

        if (_positionSeeded[trader][marketId]) {
            revert MigrationPositionAlreadySeeded(trader, marketId);
        }
        _positionSeeded[trader][marketId] = true;

        _positions[trader][marketId] = Position({
            size1e8: size1e8,
            openNotional1e8: openNotional1e8,
            lastCumulativeFundingRate1e18: lastCumulativeFundingRate1e18
        });

        _syncPositionIndexing(trader, marketId, 0, size1e8);
        _updateMarketOpenInterest(marketId, 0, size1e8);

        emit MigrationPositionSeeded(
            trader, marketId, size1e8, openNotional1e8, lastCumulativeFundingRate1e18
        );
    }

    /// @notice Seeds a market's cumulative-funding baseline and last-update
    ///         timestamp. onlyOwner + onlyMigrationOpen. Duplicates rejected.
    /// @dev Preserves Strategy A (exact snapshot). Any accrued-but-unrealized
    ///      funding on migrated positions is exactly `Σ position_size *
    ///      (market.cumulative - position.checkpoint)` — identical to V1.
    ///      Not required if the market's funding was disabled in V1 and
    ///      cumulative/timestamp are both zero.
    function adminSeedMarketFunding(
        uint256 marketId,
        int256 cumulativeFundingRate1e18,
        uint64 lastFundingTimestamp
    ) external onlyOwner onlyMigrationOpen {
        _requireMarketExists(marketId);
        if (_marketFundingSeeded[marketId]) revert MigrationMarketFundingAlreadySeeded(marketId);
        _marketFundingSeeded[marketId] = true;

        MarketState storage s = _marketStates[marketId];
        s.cumulativeFundingRate1e18 = cumulativeFundingRate1e18;
        s.lastFundingTimestamp = lastFundingTimestamp;

        emit MigrationMarketFundingSeeded(marketId, cumulativeFundingRate1e18, lastFundingTimestamp);
    }

    /// @notice Seeds a trader's residual bad-debt carryover. onlyOwner +
    ///         onlyMigrationOpen. Duplicates rejected. Not used for the
    ///         current A/B closed-test state (bad debt is zero).
    function adminSeedResidualBadDebt(address trader, uint256 amountBase)
        external
        onlyOwner
        onlyMigrationOpen
    {
        if (trader == address(0)) revert ZeroAddress();
        if (_residualBadDebtSeeded[trader]) revert MigrationResidualBadDebtAlreadySeeded(trader);
        _residualBadDebtSeeded[trader] = true;

        // Reuse existing V1 helper — updates per-trader bookkeeping AND
        // aggregate `totalResidualBadDebtBase` deterministically.
        if (amountBase != 0) {
            _recordResidualBadDebt(trader, amountBase);
        }

        emit MigrationResidualBadDebtSeeded(trader, amountBase);
    }

    /// @notice Irreversibly seals the migration lifecycle. Enables normal
    ///         trading. Emits the on-chain commitment `snapshotHash` to
    ///         the off-chain V1 manifest that seeding reproduced.
    /// @dev
    ///   Consistency preconditions checked at seal time (§10):
    ///     - clearing account is set (mutual-close settlement requires it);
    ///     - matching engine is set (applyTrade caller gate);
    ///     - risk module is set (post-trade risk enforcement);
    ///     - snapshotHash is non-zero (accidental empty-hash guard).
    ///
    ///   NOT checked here (out of scope of engine state):
    ///     - CollateralVault authorization of this engine (a vault-owner
    ///       operation);
    ///     - clearing floor liquidity (operator's off-chain solvency policy);
    ///     - snapshotHash matches any off-chain-computed value (verified
    ///       by auditors via the off-chain manifest, not on-chain).
    ///
    ///   OI consistency is guaranteed by construction: `adminSeedPosition`
    ///   updates `_marketStates.long/shortOpenInterest1e8` via the same
    ///   `_updateMarketOpenInterest` helper that normal trading uses, so
    ///   at seal `market OI == Σ |size| by side` for every seeded market.
    function sealMigration(bytes32 snapshotHash) external onlyOwner onlyMigrationOpen {
        if (snapshotHash == bytes32(0)) revert MigrationSnapshotHashZero();
        if (clearingAccount == address(0)) revert MigrationClearingNotConfigured();
        if (matchingEngine == address(0)) revert MigrationMatchingEngineNotConfigured();
        if (address(_riskModule) == address(0)) revert MigrationRiskModuleNotConfigured();

        migrationSnapshotHash = snapshotHash;
        migrationState = MigrationState.SEALED;

        emit MigrationSealed(snapshotHash, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _requireInsuranceFund() internal view {
        if (insuranceFund == address(0)) revert InsuranceFundNotSet();
    }

    function _hasResidualBadDebt(address trader) internal view returns (bool) {
        return _residualBadDebtOf(trader) != 0;
    }

    function _enforceBadDebtTradingPolicy(address trader, int256 oldSize1e8, int256 newSize1e8) internal view {
        if (!_hasResidualBadDebt(trader)) return;

        if (!_isReduceOnlyTransition(oldSize1e8, newSize1e8)) {
            revert BadDebtOutstanding(trader, _residualBadDebtOf(trader));
        }
    }

    function _tryResolveCollateralSeizer() internal view returns (ICollateralSeizer seizer, bool ok) {
        seizer = _collateralSeizer;
        if (address(seizer) == address(0)) return (ICollateralSeizer(address(0)), false);
        return (seizer, true);
    }

    function _trySeizeViaPlan(address trader, address liquidator, uint256 targetBase)
        internal
        returns (uint256 paidBase)
    {
        return PerpEngineSeizureLib.trySeizeViaPlan(_collateralSeizer, _collateralVault, trader, liquidator, targetBase);
    }

    function _routeIncomingCashflowWithDebtFirst(
        address settlementAsset,
        address payer,
        address receiver,
        uint256 incomingNative
    ) internal {
        if (incomingNative == 0) return;

        (uint256 repayNative, uint256 actualRepaidBase, uint256 requestedRepayBase, address recipient) =
            _computeBadDebtIntercept(settlementAsset, payer, receiver, incomingNative);

        if (repayNative == 0) {
            _collateralVault.transferBetweenAccounts(settlementAsset, payer, receiver, incomingNative);
            return;
        }

        _collateralVault.transferBetweenAccounts(settlementAsset, payer, recipient, repayNative);
        _reduceResidualBadDebt(receiver, actualRepaidBase);

        uint256 remainingNative = incomingNative - repayNative;
        if (remainingNative != 0) {
            _collateralVault.transferBetweenAccounts(settlementAsset, payer, receiver, remainingNative);
        }

        emit ResidualBadDebtRepaid(
            payer, receiver, recipient, requestedRepayBase, actualRepaidBase, _residualBadDebtOf(receiver)
        );
    }

    function _computeBadDebtIntercept(address settlementAsset, address payer, address receiver, uint256 incomingNative)
        internal
        view
        returns (uint256 repayNative, uint256 actualRepaidBase, uint256 requestedRepayBase, address recipient)
    {
        if (!_hasResidualBadDebt(receiver) || payer == receiver) return (0, 0, 0, address(0));

        recipient = _resolvedBadDebtRepaymentRecipient();
        uint256 outstandingBase = _residualBadDebtOf(receiver);
        if (outstandingBase == 0 || recipient == address(0) || recipient == receiver) {
            return (0, 0, 0, address(0));
        }

        uint256 incomingBase = _settlementNativeToBase(settlementAsset, incomingNative);
        if (incomingBase == 0) return (0, 0, 0, address(0));

        requestedRepayBase = outstandingBase < incomingBase ? outstandingBase : incomingBase;
        if (requestedRepayBase == 0) return (0, 0, 0, address(0));

        if (settlementAsset == _baseToken()) {
            repayNative = requestedRepayBase <= incomingNative ? requestedRepayBase : incomingNative;
        } else {
            repayNative = _penaltySettlementNative(settlementAsset, requestedRepayBase);
            if (repayNative > incomingNative) repayNative = incomingNative;
        }
        if (repayNative == 0) return (0, 0, 0, address(0));

        actualRepaidBase = _settlementNativeToBase(settlementAsset, repayNative);
        if (actualRepaidBase > outstandingBase) actualRepaidBase = outstandingBase;
        if (actualRepaidBase == 0) return (0, 0, 0, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                            FUNDING: CORE LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice PERPS-FUNDING-V2 keeper writer for the impact-mid TWAP sample.
    /// @dev
    ///  Access control: only `impactMidSource` (governance-configured) may call.
    ///  Fail-closed pre-conditions:
    ///   - reverts if funding is globally paused (mirrors `updateFunding`)
    ///   - reverts if `marketId` does not exist
    ///   - reverts if `mid1e8 == 0` (never accept a zeroed sample; a real keeper
    ///     that cannot compute a mid MUST simply not call this function so the
    ///     freshness gate lapses and funding accrues 0 for this interval)
    ///
    ///  Note: this writer does NOT itself compute funding — it only persists
    ///  the latest sample + timestamp. `_fundingRatePerInterval1e18` reads it
    ///  through `_tryGetImpactMid1e8(marketId, impactMidMaxDelay)` and applies
    ///  the freshness gate at read time.
    function updateImpactMid(uint256 marketId, uint128 mid1e8)
        external
        onlyImpactMidSource
        whenFundingNotPaused
    {
        _requireMarketExists(marketId);
        if (mid1e8 == 0) revert OraclePriceUnavailable();
        uint64 nowTs = uint64(block.timestamp);
        _impactMidSamples[marketId] = ImpactMidSample({mid1e8: mid1e8, updatedAt: nowTs});
        emit ImpactMidUpdated(marketId, mid1e8, nowTs);
    }

    /// @notice Computes the per-interval funding rate for `marketId`, in 1e18.
    /// @dev
    ///  V2 formula:
    ///    premium = (impactMid - index) / index
    ///    rate    = clamp(deadband(premium), -cap, +cap)
    ///
    ///  Direction convention:
    ///   - impactMid > index  =>  positive rate  =>  longs pay shorts
    ///   - impactMid < index  =>  negative rate  =>  shorts pay longs
    ///
    ///  Fail-closed policy:
    ///   - `isEnabled == false`      => 0, no oracle call
    ///   - keeper never seeded       => 0 (no revert; keeper outage MUST NOT
    ///                                    brick trading — `applyTrade` invokes
    ///                                    `updateFunding` which calls this)
    ///   - keeper sample stale       => 0 (same rationale)
    ///   - index oracle unavailable  => REVERT (`OraclePriceUnavailable`);
    ///                                    the index feed is required
    ///                                    infrastructure, not a keeper channel
    ///
    ///  The dual read (`_tryGetIndexPrice1e8` + `_tryGetImpactMid1e8`) is the
    ///  fix for the pre-V2 bug where both sides of the premium came from the
    ///  same oracle call, forcing the premium to 0. Do NOT merge them.
    function _fundingRatePerInterval1e18(uint256 marketId) internal view returns (int256 rate1e18) {
        PerpMarketRegistry.FundingConfig memory fcfg = _getFundingConfig(marketId);
        if (!fcfg.isEnabled) return 0;

        // Index: oracle spot (V1 policy: index == risk mark).
        (uint256 index1e8, bool okIndex) = _tryGetIndexPrice1e8(marketId);
        if (!okIndex || index1e8 == 0) revert OraclePriceUnavailable();

        // Market reference: keeper-published impact-mid TWAP with freshness gate.
        // If no fresh sample, funding is 0 for this interval — fail-CLOSED to a
        // no-op (NOT a revert), so a keeper outage does not brick trading;
        // longs and shorts simply accrue no funding until the keeper resumes.
        (uint256 marketRef1e8, bool okMarket) = _tryGetImpactMid1e8(marketId, fcfg.impactMidMaxDelay);
        if (!okMarket || marketRef1e8 == 0) return 0;

        if (marketRef1e8 == index1e8) return 0;

        // Premium = (marketRef - index) / index, signed by direction.
        bool positive = marketRef1e8 > index1e8;
        uint256 diff = positive ? marketRef1e8 - index1e8 : index1e8 - marketRef1e8;
        rate1e18 = _toInt256(_mulDivFloor(diff, uint256(FUNDING_SCALE_1E18), index1e8));

        // Deadband — preserve existing semantics: strictly-positive premiums
        // below the deadband threshold are treated as 0. Threshold applies to
        // the absolute premium; sign is re-applied after the cap.
        if (fcfg.oracleClampBps != 0) {
            int256 deadband1e18 =
                _toInt256(_mulDivFloor(uint256(fcfg.oracleClampBps), uint256(FUNDING_SCALE_1E18), BPS));
            if (rate1e18 <= deadband1e18) return 0;
            rate1e18 -= deadband1e18;
        }

        // Cap.
        uint256 capAbs = _mulDivFloor(uint256(fcfg.maxFundingRateBps), uint256(FUNDING_SCALE_1E18), BPS);
        if (uint256(rate1e18) > capAbs) rate1e18 = _toInt256(capAbs);
        if (!positive) rate1e18 = -rate1e18;
    }

    function _fundingRateDelta1e18(uint256 marketId)
        internal
        view
        returns (int256 delta1e18, uint64 effectiveTimestamp)
    {
        PerpMarketRegistry.FundingConfig memory fcfg = _getFundingConfig(marketId);

        effectiveTimestamp = uint64(block.timestamp);

        if (!fcfg.isEnabled) return (0, effectiveTimestamp);
        if (fcfg.fundingInterval == 0) revert InvalidMarket();

        uint256 elapsed = _fundingElapsed(marketId);
        if (elapsed == 0) return (0, effectiveTimestamp);

        int256 ratePerInterval1e18 = _fundingRatePerInterval1e18(marketId);
        if (ratePerInterval1e18 == 0) return (0, effectiveTimestamp);

        delta1e18 = (ratePerInterval1e18 * _toInt256(elapsed)) / _toInt256(uint256(fcfg.fundingInterval));
    }

    function updateFunding(uint256 marketId)
        public
        onlyMigrationSealed
        whenFundingNotPaused
        returns (int256 fundingRateDelta1e18, int256 nextCumulativeFundingRate1e18)
    {
        _requireMarketExists(marketId);

        MarketState storage s = _marketStates[marketId];

        if (s.lastFundingTimestamp == 0) {
            s.lastFundingTimestamp = uint64(block.timestamp);
            emit FundingUpdated(marketId, 0, s.cumulativeFundingRate1e18, s.lastFundingTimestamp);
            return (0, s.cumulativeFundingRate1e18);
        }

        uint64 ts;
        (fundingRateDelta1e18, ts) = _fundingRateDelta1e18(marketId);

        nextCumulativeFundingRate1e18 = s.cumulativeFundingRate1e18 + fundingRateDelta1e18;
        _recordFundingUpdate(marketId, fundingRateDelta1e18, nextCumulativeFundingRate1e18, ts);
    }

    /*//////////////////////////////////////////////////////////////
                        FEES / RISK / CASHFLOW HELPERS
    //////////////////////////////////////////////////////////////*/

    function _chargeTradingFeeV2(
        address trader,
        address counterparty,
        bool isMaker,
        address settlementAsset,
        uint256 notionalNative
    ) internal {
        IFeesManagerV2 fm = feesManagerV2;
        if (address(fm) == address(0)) revert ZeroAddress();

        IFeesManagerV2.FeeQuote memory q = fm.consumeFees(
            trader,
            IFeesManagerV2.ProductKind.PERP,
            IFeesManagerV2.FlowKind.ORDERBOOK,
            isMaker,
            settlementAsset,
            notionalNative
        );

        uint256 feeAmount = q.feeAmount;
        if (feeAmount == 0) return;

        if (q.isRebate) {
            if (q.recipient != trader) revert FeesManagerV2QuoteInvalid();

            address fundingAccount = fm.rebateFundingAccount();
            if (fundingAccount == address(0)) revert FeesManagerV2RebateFundingNotSet();

            _collateralVault.transferBetweenAccounts(settlementAsset, fundingAccount, trader, feeAmount);
            return;
        }

        address recipient = q.recipient;
        if (recipient == address(0)) revert FeesManagerNotSet();
        if (recipient == trader || recipient == counterparty) revert InvalidTrade();

        _collateralVault.transferBetweenAccounts(settlementAsset, trader, recipient, feeAmount);

        emit CollateralWithdrawn(trader, settlementAsset, feeAmount, 0);
    }

    function _enforcePostTradeRisk(address trader) internal view {
        if (address(_riskModule) == address(0)) return;

        IPerpRiskModule.AccountRisk memory r = _riskModule.computeAccountRisk(trader);
        if (r.initialMarginBase > uint256(type(int256).max)) revert MathOverflow();
        if (r.equityBase < int256(r.initialMarginBase)) revert MarginRequirementBreached(trader);
    }

    /// @notice V2 realized-PnL settlement primitive. Each trader is
    ///         settled independently against the clearing account.
    /// @dev
    ///  Correctness (vs V1's buggy peer-to-peer subtraction):
    ///   - each trader receives / pays EXACTLY their own realized PnL
    ///     (per §3 of the design doc), converted to native settlement
    ///     units via `_value1e8ToSettlementNative` (floor(|x|·10^dec / 1e8)
    ///     with sign restored).
    ///
    ///  Atomic ordering (per §4):
    ///   1. Debit any negative-realized side into `clearingAccount`.
    ///   2. Assert `balances[clearingAccount] >= sumPositiveCredits` — this
    ///      revert unwinds step (1) atomically (`revert` inside the same
    ///      external call unwinds all vault mutations from step (1)).
    ///   3. Credit any positive-realized side from `clearingAccount`,
    ///      routed through `_routeIncomingCashflowWithDebtFirst` so the
    ///      V1 bad-debt intercept still fires on the receiving trader.
    ///
    ///  Conservation:
    ///     Δvault(buyer) + Δvault(seller) + Δvault(clearing) = 0
    ///  bounded by deterministic per-side rounding (max 2 native units of
    ///  drift per trade for mUSDC — see design §5).
    ///
    ///  Signature is identical to V1 so `applyTrade` / `liquidate` call
    ///  sites remain source-compatible.
    function _applyRealizedCashflow(
        address settlementAsset,
        address buyer,
        address seller,
        int256 buyerRealizedPnl1e8,
        int256 sellerRealizedPnl1e8
    ) internal {
        // Fast path: both sides have zero realized PnL. No vault mutation,
        // no clearing account check.
        if (buyerRealizedPnl1e8 == 0 && sellerRealizedPnl1e8 == 0) return;

        address clearing = clearingAccount;
        if (clearing == address(0)) revert ClearingAccountNotSet();
        if (clearing == buyer || clearing == seller) revert ClearingAccountInvalid();

        // Convert each side independently to signed native units.
        int256 buyerNative = _realizedToSignedNative(settlementAsset, buyerRealizedPnl1e8);
        int256 sellerNative = _realizedToSignedNative(settlementAsset, sellerRealizedPnl1e8);

        // Step 1: debit negatives into clearing (loss-first, so losses
        // realized in this same trade fund gains realized in this same
        // trade before pre-existing clearing liquidity is drawn).
        if (buyerNative < 0) {
            uint256 owedNative = uint256(-buyerNative);
            _collateralVault.transferBetweenAccounts(settlementAsset, buyer, clearing, owedNative);
        }
        if (sellerNative < 0) {
            uint256 owedNative = uint256(-sellerNative);
            _collateralVault.transferBetweenAccounts(settlementAsset, seller, clearing, owedNative);
        }

        // Step 2: check total credits ≤ clearing balance (after step 1's
        // deposits). This single check gates atomic revert on shortfall.
        uint256 totalCreditsNative;
        if (buyerNative > 0) totalCreditsNative += uint256(buyerNative);
        if (sellerNative > 0) totalCreditsNative += uint256(sellerNative);

        if (totalCreditsNative != 0) {
            uint256 clearingBal = _collateralVault.balances(clearing, settlementAsset);
            if (clearingBal < totalCreditsNative) {
                revert ClearingLiquidityInsufficient(
                    settlementAsset, clearing, totalCreditsNative, clearingBal
                );
            }
        }

        // Step 3: pay positives from clearing (routed through the V1
        // bad-debt intercept so receivers with residual bad debt still
        // repay first before receiving free cash).
        if (buyerNative > 0) {
            _routeIncomingCashflowWithDebtFirst(settlementAsset, clearing, buyer, uint256(buyerNative));
        }
        if (sellerNative > 0) {
            _routeIncomingCashflowWithDebtFirst(settlementAsset, clearing, seller, uint256(sellerNative));
        }

        emit RealizedPnlSettledV2(
            settlementAsset, buyer, seller, clearing, buyerNative, sellerNative
        );
    }

    /// @notice Sign-preserving 1e8 -> settlement-native conversion.
    /// @dev
    ///  Uses V1's `_value1e8ToSettlementNative` (floor of absolute value,
    ///  then sign restored). Deterministic; residual dust is absorbed by
    ///  the clearing account via the sum invariant.
    function _realizedToSignedNative(address settlementAsset, int256 realized1e8)
        internal
        view
        returns (int256 signedNative)
    {
        if (realized1e8 == 0) return 0;
        uint256 absNative = _value1e8ToSettlementNative(settlementAsset, _absInt256(realized1e8));
        if (absNative == 0) return 0;
        // absNative fits in int256: 1e8 -> 1e6 conversion always reduces magnitude
        // (settlement decimals <= 8 for mUSDC-class assets in production; guarded
        // upstream by `_requireSettlementAssetConfigured`). Guard with _toInt256.
        int256 asInt = _toInt256(absNative);
        signedNative = realized1e8 > 0 ? asInt : -asInt;
    }

    function _marginState(address trader) internal view returns (IPerpRiskModule.AccountRisk memory r) {
        if (address(_riskModule) == address(0)) revert RiskModuleNotSet();
        r = _riskModule.computeAccountRisk(trader);
    }

    /*//////////////////////////////////////////////////////////////
                    EXECUTION PRICE DEVIATION GUARD
    //////////////////////////////////////////////////////////////*/

    /// @notice Fail-closed execution-price deviation guard.
    /// @dev
    ///  Enforces:
    ///     abs(executionPrice1e8 - oracleMark1e8) * BPS <= oracleMark1e8 * boundBps
    ///
    ///  The reference price is the oracle mark/index (NEVER a last-trade or book-derived value).
    ///  Behavior:
    ///   - No configured bound (bound == 0)         => revert `ExecutionDeviationGuardNotConfigured`
    ///   - Oracle unusable (!ok OR price == 0)       => revert `OracleUnavailableForExecutionGuard`
    ///   - Execution price outside band              => revert `ExecutionPriceOutOfBand`
    ///
    ///  V1 note: `_tryGetMarkPrice1e8` == index price (see PerpEngineViews.getRiskMarkPrice1e8 doc).
    ///  When PERPS-FUNDING-V2 introduces a distinct mark = index + bounded premium, the reference
    ///  used by this guard MUST remain the index price (or a bounded oracle mark). Do NOT switch
    ///  to book-derived data.
    function _enforceExecutionPriceGuard(uint256 marketId, uint256 executionPrice1e8) internal view {
        uint16 boundBps = _marketRegistry.getMaxExecutionDeviationBps(marketId);
        if (boundBps == 0) revert ExecutionDeviationGuardNotConfigured();

        (uint256 reference1e8, bool ok) = _tryGetMarkPrice1e8(marketId);
        if (!ok || reference1e8 == 0) revert OracleUnavailableForExecutionGuard();

        uint256 diff =
            executionPrice1e8 > reference1e8 ? executionPrice1e8 - reference1e8 : reference1e8 - executionPrice1e8;

        // abs(execution - reference) * BPS <= reference * boundBps
        uint256 lhs = _mulChecked(diff, BPS);
        uint256 rhs = _mulChecked(reference1e8, uint256(boundBps));
        if (lhs > rhs) revert ExecutionPriceOutOfBand();
    }

    /*//////////////////////////////////////////////////////////////
                                TRADING
    //////////////////////////////////////////////////////////////*/

    function applyTrade(Trade calldata t)
        external
        override
        onlyMigrationSealed
        onlyMatchingEngine
        whenTradingNotPaused
        nonReentrant
    {
        if (t.buyer == address(0) || t.seller == address(0) || t.buyer == t.seller) revert InvalidTrade();
        if (t.sizeDelta1e8 == 0) revert SizeZero();
        if (t.executionPrice1e8 == 0) revert PriceZero();
        _requireRiskModuleSet();

        PerpMarketRegistry.Market memory m = _requireMarketExists(t.marketId);
        if (!m.isActive) revert MarketInactive();

        PerpMarketRegistry.RiskConfig memory rcfg = _getRiskConfig(t.marketId);
        _requireSettlementAssetConfigured(m.settlementAsset);

        // Execution-price deviation guard.
        // Bounds the matching-engine-provided execution price against a fresh oracle mark/index
        // for the market. Fail-closed: reverts if the oracle is unavailable/zero, if the market
        // has no governance-configured bound, or if the execution price sits outside the band.
        // MUST run before any position mutation or cashflow.
        _enforceExecutionPriceGuard(t.marketId, uint256(t.executionPrice1e8));

        updateFunding(t.marketId);
        int256 currentFunding = _marketStates[t.marketId].cumulativeFundingRate1e18;

        Position memory oldBuyer = _positions[t.buyer][t.marketId];
        Position memory oldSeller = _positions[t.seller][t.marketId];
        uint256 previousOpenInterest1e8 = _effectiveMarketOpenInterest1e8(t.marketId);

        int256 buyerDelta = _toInt256(uint256(t.sizeDelta1e8));
        int256 sellerDelta = -buyerDelta;

        Position memory newBuyer;
        Position memory newSeller;
        int256 buyerRealized;
        int256 sellerRealized;

        (newBuyer, buyerRealized) =
            _computeNextPosition(oldBuyer, buyerDelta, uint256(t.executionPrice1e8), currentFunding);

        (newSeller, sellerRealized) =
            _computeNextPosition(oldSeller, sellerDelta, uint256(t.executionPrice1e8), currentFunding);

        uint8 activationState = marketActivationState[t.marketId];
        if (activationState == MARKET_ACTIVATION_INACTIVE) {
            bool okBuyer = _isCloseToZeroTransition(oldBuyer.size1e8, newBuyer.size1e8);
            bool okSeller = _isCloseToZeroTransition(oldSeller.size1e8, newSeller.size1e8);
            if (!okBuyer || !okSeller) revert ReduceOnlyViolation();
        } else if (
            m.isCloseOnly || marketEmergencyCloseOnly[t.marketId] || activationState == MARKET_ACTIVATION_RESTRICTED
        ) {
            bool okBuyer = _isReduceOnlyTransition(oldBuyer.size1e8, newBuyer.size1e8);
            bool okSeller = _isReduceOnlyTransition(oldSeller.size1e8, newSeller.size1e8);
            if (!okBuyer || !okSeller) revert ReduceOnlyViolation();
        }

        _enforceBadDebtTradingPolicy(t.buyer, oldBuyer.size1e8, newBuyer.size1e8);
        _enforceBadDebtTradingPolicy(t.seller, oldSeller.size1e8, newSeller.size1e8);

        if (_absInt256(newBuyer.size1e8) > uint256(rcfg.maxPositionSize1e8)) revert SizeTooLarge();
        if (_absInt256(newSeller.size1e8) > uint256(rcfg.maxPositionSize1e8)) revert SizeTooLarge();

        _applyRealizedCashflow(m.settlementAsset, t.buyer, t.seller, buyerRealized, sellerRealized);

        _positions[t.buyer][t.marketId] = newBuyer;
        _positions[t.seller][t.marketId] = newSeller;

        _syncPositionIndexing(t.buyer, t.marketId, oldBuyer.size1e8, newBuyer.size1e8);
        _syncPositionIndexing(t.seller, t.marketId, oldSeller.size1e8, newSeller.size1e8);

        _updateMarketOpenInterest(t.marketId, oldBuyer.size1e8, newBuyer.size1e8);
        _updateMarketOpenInterest(t.marketId, oldSeller.size1e8, newSeller.size1e8);
        _enforceLaunchOpenInterestCapIfIncreasing(t.marketId, previousOpenInterest1e8);

        _enforceMaxOpenInterest(t.marketId, uint256(rcfg.maxOpenInterest1e8));

        // PERPS_V2_ENGINE_SIZE_REDUCTION_A_SAFE_TRIM_V1 §1 — V2 charges
        // trading fees exclusively through FeesManagerV2. V1 continues on
        // its dedicated V1 PerpEngine deployment; V2 never falls back to
        // the legacy `IFeesManager` path. Legacy `feesManager` storage
        // and its `setFeesManager(...)` admin surface are retained
        // (inherited from `PerpEngineStorage`/`PerpEngineAdmin`) for
        // storage-layout + ABI stability, but the trade path no longer
        // reads them — removes ~760 bytes of runtime bytecode.
        if (useFeesManagerV2) {
            uint256 notionalNative = _value1e8ToSettlementNative(
                m.settlementAsset, _mulDivFloor(uint256(t.sizeDelta1e8), uint256(t.executionPrice1e8), PRICE_1E8)
            );
            _chargeTradingFeeV2(t.buyer, t.seller, t.buyerIsMaker, m.settlementAsset, notionalNative);
            _chargeTradingFeeV2(t.seller, t.buyer, !t.buyerIsMaker, m.settlementAsset, notionalNative);
        }

        emit TradeExecuted(t.buyer, t.seller, t.marketId, t.sizeDelta1e8, t.executionPrice1e8, t.buyerIsMaker);

        _enforcePostTradeRisk(t.buyer);
        _enforcePostTradeRisk(t.seller);
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDATION V2-CLOSED
    //////////////////////////////////////////////////////////////*/

    /// @notice Permissionless partial liquidation.
    /// @param trader Account being liquidated
    /// @param marketId Market to reduce
    /// @param requestedCloseSize1e8 Requested clip. If 0, engine uses max clip under close factor.
    function liquidate(address trader, uint256 marketId, uint128 requestedCloseSize1e8)
        external
        onlyMigrationSealed
        whenLiquidationNotPaused
        nonReentrant
    {
        // PERPS_V2_ENGINE_SIZE_REDUCTION_C_FINAL_IMPLEMENTATION_V1 §5-§10 —
        // full cold-path liquidation orchestration delegated to
        // `PerpEngineLiquidationLib` (existing external library, DELEGATECALL).
        // The engine wrapper below still performs:
        //   - modifier gating (sealed, pause, reentrancy);
        //   - basic caller / market / config validation;
        //   - hot-path helpers `updateFunding`, `_applyRealizedCashflow`,
        //     `_syncPositionIndexing`, `_updateMarketOpenInterest`,
        //     `_recordResidualBadDebt`, `_enforcePostTradeRisk` — these stay
        //     single-source per §8.
        // The library performs the pure clip+leg math, the vault-facing seize
        // + shortfall + insurance calls, and emits the 3 terminal events.
        if (trader == address(0)) revert ZeroAddress();
        if (trader == msg.sender) revert LiquidationSelfNotAllowed();

        PerpMarketRegistry.Market memory m = _requireMarketExists(marketId);
        if (!m.isActive && !m.isCloseOnly) revert MarketInactive();

        PerpMarketRegistry.RiskConfig memory rcfg = _getRiskConfig(marketId);
        _requireSettlementAssetConfigured(m.settlementAsset);
        _requireInsuranceFund();

        (
            uint256 closeFactorBps,
            uint256 penaltyBps,
            uint256 priceSpreadBps,
            uint256 minImprovementBps,
            uint32 oracleMaxDelay
        ) = _loadEffectiveLiquidationParams(marketId);

        IPerpRiskModule.AccountRisk memory traderBefore = _marginState(trader);
        if (!PerpEngineLiquidationLib.isTraderLiquidatable(traderBefore)) revert NotLiquidatable();

        updateFunding(marketId);
        int256 currentFunding = _marketStates[marketId].cumulativeFundingRate1e18;

        Position memory oldTraderPos = _positions[trader][marketId];
        if (oldTraderPos.size1e8 == 0) revert LiquidationNothingToDo();

        uint256 markPrice1e8 = _liquidationMarkPrice1e8(marketId, oracleMaxDelay);

        address liquidator = msg.sender;
        Position memory oldLiqPos = _positions[liquidator][marketId];

        // Compute clip + liquidator leg + realized PnL via library (pure).
        PerpEngineLiquidationLib.ClipAndLegResult memory clip = PerpEngineLiquidationLib
            .computeClipAndLeg(
                oldTraderPos,
                oldLiqPos,
                requestedCloseSize1e8,
                markPrice1e8,
                currentFunding,
                closeFactorBps,
                priceSpreadBps
            );

        if (_absInt256(clip.newLiqPos.size1e8) > uint256(rcfg.maxPositionSize1e8)) {
            revert LiquidatorWouldBreachMargin(liquidator);
        }

        // Cashflow settlement via canonical clearing-account primitive (engine).
        _applyRealizedCashflow(
            m.settlementAsset, liquidator, trader, 0 - clip.traderRealizedPnl1e8, clip.traderRealizedPnl1e8
        );

        // Canonical storage writes (engine).
        _positions[trader][marketId] = clip.newTraderPos;
        _positions[liquidator][marketId] = clip.newLiqPos;

        _syncPositionIndexing(trader, marketId, oldTraderPos.size1e8, clip.newTraderPos.size1e8);
        _syncPositionIndexing(liquidator, marketId, oldLiqPos.size1e8, clip.newLiqPos.size1e8);

        _updateMarketOpenInterest(marketId, oldTraderPos.size1e8, clip.newTraderPos.size1e8);
        _updateMarketOpenInterest(marketId, oldLiqPos.size1e8, clip.newLiqPos.size1e8);

        _enforceMaxOpenInterest(marketId, uint256(rcfg.maxOpenInterest1e8));

        uint256 closedNotional1e8 = _mulDivFloor(uint256(clip.sizeClosed1e8), clip.liqPrice1e8, PRICE_1E8);
        uint256 closedNotionalBase = _settlementAmount1e8ToBase(m.settlementAsset, closedNotional1e8);
        uint256 penaltyBase = _liquidationPenaltyBaseValue(closedNotionalBase, penaltyBps);

        // Consolidated cold-path finalization: seize + shortfall + improvement +
        // 3 terminal events, all in ONE delegatecall boundary (§10 consolidation).
        (LiquidationResolution memory resolution, bool improved) = PerpEngineLiquidationLib.finalizeLiquidation(
            PerpEngineLiquidationLib.SeizeCtx({
                vault: _collateralVault,
                seizer: _collateralSeizer,
                oracle: _oracle,
                baseToken: _baseToken(),
                settlementAsset: m.settlementAsset
            }),
            insuranceFund,
            liquidator,
            trader,
            marketId,
            clip.sizeClosed1e8,
            clip.liqPrice1e8,
            closedNotionalBase,
            penaltyBase,
            traderBefore,
            _marginState(trader),
            minImprovementBps
        );

        if (resolution.residualShortfallBase != 0) {
            _recordResidualBadDebt(trader, resolution.residualShortfallBase);
        }

        if (!improved) revert LiquidationNotImproving();

        _enforcePostTradeRisk(liquidator);
    }
}
