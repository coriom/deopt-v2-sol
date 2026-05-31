// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {PerpEngine} from "../src/perp/PerpEngine.sol";
import {PerpEngineTypes} from "../src/perp/PerpEngineTypes.sol";
import {PerpMatchingEngine} from "../src/matching/PerpMatchingEngine.sol";
import {MockPriceSource} from "../src/oracle/MockPriceSource.sol";
import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";
import {IFeesManagerV2} from "../src/fees/IFeesManagerV2.sol";

interface ICollateralVaultBalances {
    function balances(address account, address token) external view returns (uint256);
}

/// @title SmokePerpV2RebateExecute
/// @notice V2G-E PERP rebate smoke that **requires** the rebate state to be
///         live (Merkle root + budget + maker/taker tier claims), executes a
///         single tiny PERP trade through PerpMatchingEngine, and verifies
///         `FeeChargedV2` (taker leg) and `FeeRebatedV2` (maker leg) emerge
///         from FeesManagerV2 via on-chain vault deltas.
/// @dev
///  This is the broadcast sibling of V2G-B's read-only `SmokePerpV2Rebate.s.sol`
///  and the V2F-LM `SmokeV2PerpFeesOnNew.s.sol` (which intentionally REFUSES
///  when rebate state is present). The V2G-E script flips that defense: it
///  refuses when rebate state is MISSING.
///
///  Confirm flags:
///    - `REFRESH_MOCK_FEEDS_CONFIRM=true` → refresh ETH/USDC mock feeds in-band.
///    - `SMOKE_PERP_V2_REBATE_EXECUTE_CONFIRM=true` → sign and broadcast the trade.
///
///  Required env when smoke confirmed:
///    - `DEPLOYER_PRIVATE_KEY` (must be `PerpMatchingEngine.isExecutor` = true).
///    - `PERP_ENGINE` (NEW PerpEngine, != `OLD_PERP_ENGINE`).
///    - `OLD_PERP_ENGINE` (stranded address, invariance only).
///    - `PERP_MATCHING_ENGINE` (must point at NEW).
///    - `FEES_MANAGER_V2_ADDRESS`.
///    - `COLLATERAL_VAULT`, `BASE_COLLATERAL_TOKEN`.
///    - `PERP_SMOKE_BUYER_PRIVATE_KEY`, `PERP_SMOKE_SELLER_PRIVATE_KEY`.
///
///  Optional env:
///    - `PERP_MARKET_ID` (default 1).
///    - `PERP_SMOKE_SIZE_1E8` (default 1000; with price 3e11 this yields a
///      30_000 native-mUSDC notional, large enough that a 100-ppm rebate is
///      ≥ 1 native unit after Floor rounding).
///    - `PERP_SMOKE_PRICE_1E8` (default 3e11 = $3000 at 1e8 scale).
///    - `PERP_SMOKE_BUYER_IS_MAKER` (default true → buyer is the maker rebate
///      leg, seller is the taker fee leg). Operator should pick the side that
///      matches the tiered EOAs at broadcast time.
///    - `PERP_SMOKE_DEADLINE_SECONDS` (default 600).
///    - `ETH_USDC_PRIMARY_SOURCE` / `ETH_USDC_SECONDARY_SOURCE` /
///      `ETH_USDC_MOCK_PRICE_1E8` (only if refreshing feeds).
///    - `MIN_REBATE_BUDGET` (default 1, just a defense-in-depth gate).
///
///  Hard-refuses:
///    - chain id 8453 (Base mainnet).
///    - V2 not enabled / not wired on NEW PerpEngine.
///    - `PERP_ENGINE == OLD_PERP_ENGINE` or the matching engine still points OLD.
///    - Merkle root unset / rebate budget below `MIN_REBATE_BUDGET`.
///    - Buyer tier or seller tier carries a NON-negative makerPpm (no rebate path).
///    - Matching engine paused or caller not an executor when confirmed.
///    - Buyer == seller.
///
///  Forbidden surface: no `setMerkleRoot`, no `setFeesManagerV2`, no
///  `setUseFeesManagerV2`, no `setFeeConsumer`, no `setFeeRecipient`, no
///  `setRebateFundingAccount`, no `fundRebateBudget`, no `claimTier`. The
///  invariance assertion at the end reverts if any of these mutated.
contract SmokePerpV2RebateExecute is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Inputs {
        address caller;
        address perpEngine;
        address oldPerpEngine;
        address perpMatchingEngine;
        address feesManagerV2;
        address collateralVault;
        address settlementAsset;
        uint256 marketId;
        uint128 size1e8;
        uint128 price1e8;
        uint256 deadlineSeconds;
        bool buyerIsMaker;
        address ethPrimarySource;
        address ethSecondarySource;
        uint256 ethRefreshPrice1e8;
        bool refreshFeedsConfirmed;
        bool smokeConfirmed;
        uint256 buyerPk;
        uint256 sellerPk;
        uint256 minRebateBudget;
    }

    struct Snapshot {
        address matchingPerpEngine;
        bool matchingPaused;
        bool deployerIsExecutor;
        address newEngineFeesManagerV2;
        bool newEngineUseFeesManagerV2;
        bool oldEngineUseFeesManagerV2;
        bool fmv2IsFeeConsumerNew;
        bool fmv2IsFeeConsumerOld;
        bytes32 fmv2MerkleRoot;
        uint256 fmv2RebateBudgetSettlement;
        address fmv2FeeRecipient;
        address fmv2RebateFundingAccount;
        uint256 feeRecipientVaultBalance;
        uint256 fundingAccountVaultBalance;
        uint256 newLongOI;
        uint256 newShortOI;
        uint256 oldLongOI;
        uint256 oldShortOI;
        uint256 buyerVaultBalance;
        uint256 sellerVaultBalance;
        uint8 buyerTier;
        uint8 sellerTier;
        IFeesManagerV2.ProductFeeProfilePpm buyerPerpProfile;
        IFeesManagerV2.ProductFeeProfilePpm sellerPerpProfile;
        uint256 ethPrimaryUpdatedAt;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error MainnetForbidden();
    error PerpEngineUnset();
    error OldPerpEngineUnset();
    error PerpEngineEqualsOld(address engine);
    error PerpMatchingEngineUnset();
    error FeesManagerV2Unset();
    error CollateralVaultUnset();
    error SettlementAssetUnset();
    error NoCodeAt(string name, address target);
    error MatchingEngineRewireDrifted(address expected, address actual);
    error V2NotEnabledRunGate7dFirst(address feesManagerV2, bool useFeesManagerV2);
    error V2ConsumerMismatch(address consumer);
    error OldPerpEngineStillFeeConsumer();
    error MerkleRootUnset();
    error RebateBudgetBelowMinimum(uint256 budget, uint256 minBudget);
    error MakerHasNoNegativeRebateTier(uint8 tier, int32 ppm);
    error TakerHasNoNonZeroFeePpm(uint8 tier, int32 ppm);
    error MatchingPausedRunGate7aFirst();
    error CallerIsNotExecutor(address caller);
    error SmokeRequiresBuyerAndSellerKeys();
    error BuyerSellerSameAddress();
    error V2WiringChangedDuringRun();
    error MerkleRootChangedDuringRun();
    error OldMarketStateChanged();
    error NewMarketStateUnchanged();
    error NoRebateObserved();
    error NoFeeObserved();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint128 internal constant DEFAULT_PRICE_1E8 = 300_000_000_000;
    // Size 1000 × price 3e11 / 1e8 = 3e6 1e8-notional → 30 000 mUSDC native
    // (6 dp). With Tier-4 maker -100 ppm → floor(30 000 × 100 / 1e6) = 3 native
    // rebate (≥ 1). With Tier-2 taker +200 ppm → ceil(30 000 × 200 / 1e6) = 6
    // native fee. Both far below the 2_000_000 vault balance.
    uint128 internal constant DEFAULT_SIZE_1E8 = 1000;
    uint256 internal constant DEFAULT_DEADLINE_SECONDS = 600;
    uint256 internal constant DEFAULT_MIN_REBATE_BUDGET = 1;
    address internal constant DEFAULT_OLD_PERP_ENGINE = 0xB36395b67D0798ADA981731c9Fa5239F4362b53B;

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        if (block.chainid == 8453) revert MainnetForbidden();

        Inputs memory inputs = _readInputs();
        _validateInputs(inputs);

        Snapshot memory before_ = _snapshot(inputs);
        _logInputs(inputs);
        _logSnapshot("before", before_);

        _validatePreconditions(inputs, before_);

        if (!inputs.refreshFeedsConfirmed && !inputs.smokeConfirmed) {
            console2.log("V2G-E PERP rebate smoke preflight PASSED. No confirm flag set; no transactions sent.");
            return;
        }

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        if (inputs.refreshFeedsConfirmed) {
            vm.startBroadcast(deployerPk);
            _refreshFeeds(inputs);
            vm.stopBroadcast();
        }

        if (inputs.smokeConfirmed) {
            _executeRebateTrade(inputs, deployerPk);
        }

        Snapshot memory after_ = _snapshot(inputs);
        _logSnapshot("after", after_);
        _assertInvariance(before_, after_);
        _verifyOldUntouched(before_, after_);

        if (inputs.smokeConfirmed) {
            _verifyTradeMaterialized(before_, after_);
            _logFeeAccounting(inputs, before_, after_);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _readInputs() internal view returns (Inputs memory inputs) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        inputs.caller = vm.addr(deployerPk);

        inputs.perpEngine = _envAddressOrZero("PERP_ENGINE");
        inputs.oldPerpEngine = vm.envOr("OLD_PERP_ENGINE", DEFAULT_OLD_PERP_ENGINE);
        inputs.perpMatchingEngine = _envAddressOrZero("PERP_MATCHING_ENGINE");
        inputs.feesManagerV2 = _envAddressOrZero("FEES_MANAGER_V2_ADDRESS");
        inputs.collateralVault = _envAddressOrZero("COLLATERAL_VAULT");
        inputs.settlementAsset = _envAddressOrZero("BASE_COLLATERAL_TOKEN");

        inputs.marketId = vm.envOr("PERP_MARKET_ID", uint256(1));
        inputs.size1e8 = uint128(vm.envOr("PERP_SMOKE_SIZE_1E8", uint256(DEFAULT_SIZE_1E8)));
        inputs.price1e8 = uint128(vm.envOr("PERP_SMOKE_PRICE_1E8", uint256(DEFAULT_PRICE_1E8)));
        inputs.deadlineSeconds = vm.envOr("PERP_SMOKE_DEADLINE_SECONDS", DEFAULT_DEADLINE_SECONDS);
        inputs.buyerIsMaker = vm.envOr("PERP_SMOKE_BUYER_IS_MAKER", true);

        inputs.ethPrimarySource = _envAddressOrZero("ETH_USDC_PRIMARY_SOURCE");
        inputs.ethSecondarySource = _envAddressOrZero("ETH_USDC_SECONDARY_SOURCE");
        inputs.ethRefreshPrice1e8 = vm.envOr("ETH_USDC_MOCK_PRICE_1E8", uint256(DEFAULT_PRICE_1E8));

        inputs.refreshFeedsConfirmed = vm.envOr("REFRESH_MOCK_FEEDS_CONFIRM", false);
        inputs.smokeConfirmed = vm.envOr("SMOKE_PERP_V2_REBATE_EXECUTE_CONFIRM", false);

        inputs.buyerPk = vm.envOr("PERP_SMOKE_BUYER_PRIVATE_KEY", uint256(0));
        inputs.sellerPk = vm.envOr("PERP_SMOKE_SELLER_PRIVATE_KEY", uint256(0));

        inputs.minRebateBudget = vm.envOr("MIN_REBATE_BUDGET", DEFAULT_MIN_REBATE_BUDGET);
    }

    function _validateInputs(Inputs memory inputs) internal view {
        if (inputs.perpEngine == address(0)) revert PerpEngineUnset();
        if (inputs.perpEngine.code.length == 0) revert NoCodeAt("PERP_ENGINE", inputs.perpEngine);

        if (inputs.oldPerpEngine == address(0)) revert OldPerpEngineUnset();
        if (inputs.perpEngine == inputs.oldPerpEngine) revert PerpEngineEqualsOld(inputs.perpEngine);

        if (inputs.perpMatchingEngine == address(0)) revert PerpMatchingEngineUnset();
        if (inputs.perpMatchingEngine.code.length == 0) {
            revert NoCodeAt("PERP_MATCHING_ENGINE", inputs.perpMatchingEngine);
        }

        if (inputs.feesManagerV2 == address(0)) revert FeesManagerV2Unset();
        if (inputs.feesManagerV2.code.length == 0) revert NoCodeAt("FEES_MANAGER_V2_ADDRESS", inputs.feesManagerV2);

        if (inputs.collateralVault == address(0)) revert CollateralVaultUnset();
        if (inputs.collateralVault.code.length == 0) revert NoCodeAt("COLLATERAL_VAULT", inputs.collateralVault);

        if (inputs.settlementAsset == address(0)) revert SettlementAssetUnset();
    }

    function _snapshot(Inputs memory inputs) internal view returns (Snapshot memory snap) {
        PerpEngine engine = PerpEngine(inputs.perpEngine);
        PerpMatchingEngine matching = PerpMatchingEngine(inputs.perpMatchingEngine);
        FeesManagerV2 fmv2 = FeesManagerV2(inputs.feesManagerV2);

        snap.matchingPerpEngine = address(matching.perpEngine());
        snap.matchingPaused = matching.paused();
        snap.deployerIsExecutor = matching.isExecutor(inputs.caller);

        snap.newEngineFeesManagerV2 = address(engine.feesManagerV2());
        snap.newEngineUseFeesManagerV2 = engine.useFeesManagerV2();
        if (inputs.oldPerpEngine.code.length > 0) {
            try PerpEngine(inputs.oldPerpEngine).useFeesManagerV2() returns (bool ok) {
                snap.oldEngineUseFeesManagerV2 = ok;
            } catch {}
        }

        snap.fmv2IsFeeConsumerNew = fmv2.isFeeConsumer(inputs.perpEngine);
        snap.fmv2IsFeeConsumerOld = fmv2.isFeeConsumer(inputs.oldPerpEngine);
        snap.fmv2MerkleRoot = fmv2.merkleRoot();
        snap.fmv2RebateBudgetSettlement = fmv2.rebateBudget(inputs.settlementAsset);
        snap.fmv2FeeRecipient = fmv2.feeRecipient();
        snap.fmv2RebateFundingAccount = fmv2.rebateFundingAccount();

        if (snap.fmv2FeeRecipient != address(0)) {
            snap.feeRecipientVaultBalance = ICollateralVaultBalances(inputs.collateralVault)
                .balances(snap.fmv2FeeRecipient, inputs.settlementAsset);
        }
        if (snap.fmv2RebateFundingAccount != address(0)) {
            snap.fundingAccountVaultBalance = ICollateralVaultBalances(inputs.collateralVault)
                .balances(snap.fmv2RebateFundingAccount, inputs.settlementAsset);
        }

        PerpEngineTypes.MarketState memory newS = engine.marketState(inputs.marketId);
        snap.newLongOI = newS.longOpenInterest1e8;
        snap.newShortOI = newS.shortOpenInterest1e8;

        PerpEngineTypes.MarketState memory oldS = PerpEngine(inputs.oldPerpEngine).marketState(inputs.marketId);
        snap.oldLongOI = oldS.longOpenInterest1e8;
        snap.oldShortOI = oldS.shortOpenInterest1e8;

        if (inputs.buyerPk != 0) {
            address buyer = vm.addr(inputs.buyerPk);
            snap.buyerVaultBalance =
                ICollateralVaultBalances(inputs.collateralVault).balances(buyer, inputs.settlementAsset);
            snap.buyerTier = fmv2.currentTier(buyer);
            snap.buyerPerpProfile = fmv2.getFeeProfile(snap.buyerTier, IFeesManagerV2.ProductKind.PERP);
        }
        if (inputs.sellerPk != 0) {
            address seller = vm.addr(inputs.sellerPk);
            snap.sellerVaultBalance =
                ICollateralVaultBalances(inputs.collateralVault).balances(seller, inputs.settlementAsset);
            snap.sellerTier = fmv2.currentTier(seller);
            snap.sellerPerpProfile = fmv2.getFeeProfile(snap.sellerTier, IFeesManagerV2.ProductKind.PERP);
        }

        if (inputs.ethPrimarySource != address(0) && inputs.ethPrimarySource.code.length != 0) {
            try MockPriceSource(inputs.ethPrimarySource).getLatestPrice() returns (uint256, uint256 t) {
                snap.ethPrimaryUpdatedAt = t;
            } catch {}
        }
    }

    function _validatePreconditions(Inputs memory inputs, Snapshot memory snap) internal view {
        if (snap.matchingPerpEngine != inputs.perpEngine) {
            revert MatchingEngineRewireDrifted(inputs.perpEngine, snap.matchingPerpEngine);
        }

        if (snap.newEngineFeesManagerV2 != inputs.feesManagerV2 || !snap.newEngineUseFeesManagerV2) {
            revert V2NotEnabledRunGate7dFirst(snap.newEngineFeesManagerV2, snap.newEngineUseFeesManagerV2);
        }
        if (!snap.fmv2IsFeeConsumerNew) revert V2ConsumerMismatch(inputs.perpEngine);
        if (snap.fmv2IsFeeConsumerOld) revert OldPerpEngineStillFeeConsumer();

        if (snap.fmv2MerkleRoot == bytes32(0)) revert MerkleRootUnset();
        if (snap.fmv2RebateBudgetSettlement < inputs.minRebateBudget) {
            revert RebateBudgetBelowMinimum(snap.fmv2RebateBudgetSettlement, inputs.minRebateBudget);
        }

        if (inputs.smokeConfirmed) {
            if (snap.matchingPaused) revert MatchingPausedRunGate7aFirst();
            if (!snap.deployerIsExecutor) revert CallerIsNotExecutor(inputs.caller);
            if (inputs.buyerPk == 0 || inputs.sellerPk == 0) revert SmokeRequiresBuyerAndSellerKeys();
            if (vm.addr(inputs.buyerPk) == vm.addr(inputs.sellerPk)) revert BuyerSellerSameAddress();

            int32 makerPpm = inputs.buyerIsMaker ? snap.buyerPerpProfile.makerPpm : snap.sellerPerpProfile.makerPpm;
            uint8 makerTier = inputs.buyerIsMaker ? snap.buyerTier : snap.sellerTier;
            if (makerPpm >= 0) revert MakerHasNoNegativeRebateTier(makerTier, makerPpm);

            int32 takerPpm = inputs.buyerIsMaker ? snap.sellerPerpProfile.takerPpm : snap.buyerPerpProfile.takerPpm;
            uint8 takerTier = inputs.buyerIsMaker ? snap.sellerTier : snap.buyerTier;
            if (takerPpm <= 0) revert TakerHasNoNonZeroFeePpm(takerTier, takerPpm);
        }
    }

    function _refreshFeeds(Inputs memory inputs) internal {
        if (inputs.ethPrimarySource != address(0) && inputs.ethPrimarySource.code.length != 0) {
            MockPriceSource(inputs.ethPrimarySource).setPrice(inputs.ethRefreshPrice1e8);
        }
        if (inputs.ethSecondarySource != address(0) && inputs.ethSecondarySource.code.length != 0) {
            MockPriceSource(inputs.ethSecondarySource).setPrice(inputs.ethRefreshPrice1e8);
        }
    }

    function _executeRebateTrade(Inputs memory inputs, uint256 deployerPk) internal {
        PerpMatchingEngine matching = PerpMatchingEngine(inputs.perpMatchingEngine);

        address buyer = vm.addr(inputs.buyerPk);
        address seller = vm.addr(inputs.sellerPk);

        PerpMatchingEngine.PerpTrade memory trade = PerpMatchingEngine.PerpTrade({
            intentId: keccak256(abi.encode("v2g_e-perp-rebate-smoke", block.timestamp, buyer, seller, inputs.marketId)),
            buyer: buyer,
            seller: seller,
            marketId: inputs.marketId,
            sizeDelta1e8: inputs.size1e8,
            executionPrice1e8: inputs.price1e8,
            buyerIsMaker: inputs.buyerIsMaker,
            buyerNonce: matching.nonces(buyer),
            sellerNonce: matching.nonces(seller),
            deadline: block.timestamp + inputs.deadlineSeconds
        });

        bytes32 digest = matching.hashTrade(trade);
        (uint8 vBuyer, bytes32 rBuyer, bytes32 sBuyer) = vm.sign(inputs.buyerPk, digest);
        (uint8 vSeller, bytes32 rSeller, bytes32 sSeller) = vm.sign(inputs.sellerPk, digest);
        bytes memory buyerSig = abi.encodePacked(rBuyer, sBuyer, vBuyer);
        bytes memory sellerSig = abi.encodePacked(rSeller, sSeller, vSeller);

        vm.startBroadcast(deployerPk);
        matching.executeTrade(trade, buyerSig, sellerSig);
        vm.stopBroadcast();
    }

    function _assertInvariance(Snapshot memory before_, Snapshot memory after_) internal pure {
        if (
            before_.newEngineFeesManagerV2 != after_.newEngineFeesManagerV2
                || before_.newEngineUseFeesManagerV2 != after_.newEngineUseFeesManagerV2
                || before_.fmv2IsFeeConsumerNew != after_.fmv2IsFeeConsumerNew
                || before_.fmv2IsFeeConsumerOld != after_.fmv2IsFeeConsumerOld
                || before_.fmv2FeeRecipient != after_.fmv2FeeRecipient
                || before_.fmv2RebateFundingAccount != after_.fmv2RebateFundingAccount
        ) {
            revert V2WiringChangedDuringRun();
        }
        if (before_.fmv2MerkleRoot != after_.fmv2MerkleRoot) revert MerkleRootChangedDuringRun();
    }

    function _verifyOldUntouched(Snapshot memory before_, Snapshot memory after_) internal pure {
        if (before_.oldLongOI != after_.oldLongOI) revert OldMarketStateChanged();
        if (before_.oldShortOI != after_.oldShortOI) revert OldMarketStateChanged();
    }

    function _verifyTradeMaterialized(Snapshot memory before_, Snapshot memory after_) internal pure {
        if (before_.newLongOI == after_.newLongOI && before_.newShortOI == after_.newShortOI) {
            revert NewMarketStateUnchanged();
        }
    }

    function _logFeeAccounting(Inputs memory inputs, Snapshot memory before_, Snapshot memory after_) internal pure {
        int256 buyerDelta = int256(after_.buyerVaultBalance) - int256(before_.buyerVaultBalance);
        int256 sellerDelta = int256(after_.sellerVaultBalance) - int256(before_.sellerVaultBalance);
        int256 feeRecipientDelta = int256(after_.feeRecipientVaultBalance) - int256(before_.feeRecipientVaultBalance);
        int256 fundingAccountDelta =
            int256(after_.fundingAccountVaultBalance) - int256(before_.fundingAccountVaultBalance);
        int256 budgetDelta = int256(after_.fmv2RebateBudgetSettlement) - int256(before_.fmv2RebateBudgetSettlement);

        // Maker side received the rebate; taker side paid the fee. With
        // PerpEngine.applyTrade calling consumeFees for BOTH legs, the maker
        // leg credit pulls from the funder vault (so funder delta < 0) and the
        // taker leg debit goes to feeRecipient (so feeRecipient delta > 0).
        // The rebate budget on FeesManagerV2 should also drop.
        if (budgetDelta >= 0) revert NoRebateObserved();
        if (feeRecipientDelta <= 0) revert NoFeeObserved();

        console2.log("V2G-E PERP rebate accounting:");
        console2.log(" buyer vault delta (native)", buyerDelta);
        console2.log(" seller vault delta (native)", sellerDelta);
        console2.log(" feeRecipient vault delta (native)", feeRecipientDelta);
        console2.log(" rebateFundingAccount vault delta (native)", fundingAccountDelta);
        console2.log(" FeesManagerV2.rebateBudget delta (native)", budgetDelta);

        console2.log(" buyer tier", uint256(after_.buyerTier));
        console2.log(" buyer PERP makerPpm", int256(after_.buyerPerpProfile.makerPpm));
        console2.log(" buyer PERP takerPpm", int256(after_.buyerPerpProfile.takerPpm));
        console2.log(" seller tier", uint256(after_.sellerTier));
        console2.log(" seller PERP makerPpm", int256(after_.sellerPerpProfile.makerPpm));
        console2.log(" seller PERP takerPpm", int256(after_.sellerPerpProfile.takerPpm));
        console2.log(" trade size1e8", uint256(inputs.size1e8));
        console2.log(" trade price1e8", uint256(inputs.price1e8));
        console2.log(" buyerIsMaker", inputs.buyerIsMaker);
    }

    function _logInputs(Inputs memory inputs) internal view {
        console2.log("V2G-E PERP rebate smoke (executable)");
        console2.log("chainId", block.chainid);
        console2.log("caller (sanitized, no key)", inputs.caller);
        console2.log("PERP_ENGINE (NEW)", inputs.perpEngine);
        console2.log("OLD_PERP_ENGINE (must stay stranded)", inputs.oldPerpEngine);
        console2.log("PERP_MATCHING_ENGINE", inputs.perpMatchingEngine);
        console2.log("FEES_MANAGER_V2_ADDRESS", inputs.feesManagerV2);
        console2.log("COLLATERAL_VAULT", inputs.collateralVault);
        console2.log("BASE_COLLATERAL_TOKEN (settlement)", inputs.settlementAsset);
        console2.log("PERP_MARKET_ID", inputs.marketId);
        console2.log("PERP_SMOKE_SIZE_1E8", uint256(inputs.size1e8));
        console2.log("PERP_SMOKE_PRICE_1E8", uint256(inputs.price1e8));
        console2.log("PERP_SMOKE_BUYER_IS_MAKER", inputs.buyerIsMaker);
        console2.log("PERP_SMOKE_DEADLINE_SECONDS", inputs.deadlineSeconds);
        console2.log("REFRESH_MOCK_FEEDS_CONFIRM", inputs.refreshFeedsConfirmed);
        console2.log("SMOKE_PERP_V2_REBATE_EXECUTE_CONFIRM", inputs.smokeConfirmed);
        console2.log("PERP_SMOKE_BUYER_PRIVATE_KEY (present)", inputs.buyerPk != 0);
        console2.log("PERP_SMOKE_SELLER_PRIVATE_KEY (present)", inputs.sellerPk != 0);
        console2.log("MIN_REBATE_BUDGET", inputs.minRebateBudget);
    }

    function _logSnapshot(string memory label, Snapshot memory snap) internal pure {
        console2.log("State snapshot:", label);
        console2.log(" Matching.perpEngine()", snap.matchingPerpEngine);
        console2.log(" Matching.paused()", snap.matchingPaused);
        console2.log(" Matching.isExecutor(deployer)", snap.deployerIsExecutor);
        console2.log(" NEW.feesManagerV2()", snap.newEngineFeesManagerV2);
        console2.log(" NEW.useFeesManagerV2()", snap.newEngineUseFeesManagerV2);
        console2.log(" OLD.useFeesManagerV2()", snap.oldEngineUseFeesManagerV2);
        console2.log(" FeesManagerV2.isFeeConsumer(NEW)", snap.fmv2IsFeeConsumerNew);
        console2.log(" FeesManagerV2.isFeeConsumer(OLD)", snap.fmv2IsFeeConsumerOld);
        console2.log(" FeesManagerV2.merkleRoot() (uint)", uint256(snap.fmv2MerkleRoot));
        console2.log(" FeesManagerV2.rebateBudget(settlement)", snap.fmv2RebateBudgetSettlement);
        console2.log(" FeesManagerV2.feeRecipient()", snap.fmv2FeeRecipient);
        console2.log(" FeesManagerV2.rebateFundingAccount()", snap.fmv2RebateFundingAccount);
        console2.log(" Vault.balances(feeRecipient, settlement)", snap.feeRecipientVaultBalance);
        console2.log(" Vault.balances(rebateFundingAccount, settlement)", snap.fundingAccountVaultBalance);
        console2.log(" Vault.balances(buyer, settlement)", snap.buyerVaultBalance);
        console2.log(" Vault.balances(seller, settlement)", snap.sellerVaultBalance);
        console2.log(" FeesManagerV2.currentTier(buyer)", uint256(snap.buyerTier));
        console2.log(" FeesManagerV2.currentTier(seller)", uint256(snap.sellerTier));
        console2.log(" PERP makerPpm at buyer tier", int256(snap.buyerPerpProfile.makerPpm));
        console2.log(" PERP takerPpm at buyer tier", int256(snap.buyerPerpProfile.takerPpm));
        console2.log(" PERP makerPpm at seller tier", int256(snap.sellerPerpProfile.makerPpm));
        console2.log(" PERP takerPpm at seller tier", int256(snap.sellerPerpProfile.takerPpm));
        console2.log(" NEW.marketState(marketId).longOI1e8", snap.newLongOI);
        console2.log(" NEW.marketState(marketId).shortOI1e8", snap.newShortOI);
        console2.log(" OLD.marketState(marketId).longOI1e8", snap.oldLongOI);
        console2.log(" OLD.marketState(marketId).shortOI1e8", snap.oldShortOI);
        console2.log(" ETH primary mock updatedAt", snap.ethPrimaryUpdatedAt);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
