// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {OptionMatchingEngine} from "../src/matching/OptionMatchingEngine.sol";
import {MockPriceSource} from "../src/oracle/MockPriceSource.sol";
import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";
import {IFeesManagerV2} from "../src/fees/IFeesManagerV2.sol";

interface ICollateralVaultBalances {
    function balances(address account, address token) external view returns (uint256);
}

interface IMarginEngineV2View {
    function useFeesManagerV2() external view returns (bool);
    function feesManagerV2() external view returns (address);
}

/// @title SmokeOptionV2RebateExecute
/// @notice V2G-E OPTION rebate smoke that **requires** the rebate state to be
///         live (Merkle root + budget + maker/taker tier claims), executes a
///         single tiny OPTION trade through `OptionMatchingEngine`, and
///         verifies `FeeChargedV2` (taker leg) and `FeeRebatedV2` (maker leg)
///         emerge from FeesManagerV2 via on-chain vault deltas.
/// @dev
///  Confirm flags:
///    - `REFRESH_MOCK_FEEDS_CONFIRM=true` → refresh ETH/USDC mock feeds in-band.
///    - `SMOKE_OPTION_V2_REBATE_EXECUTE_CONFIRM=true` → sign + broadcast trade.
///
///  Required env when smoke confirmed:
///    - `DEPLOYER_PRIVATE_KEY` (must be `OptionMatchingEngine.isExecutor` = true).
///    - `OPTION_MATCHING_ENGINE`, `MARGIN_ENGINE` (V2).
///    - `FEES_MANAGER_V2_ADDRESS`, `COLLATERAL_VAULT`, `BASE_COLLATERAL_TOKEN`.
///    - `OPTION_SMOKE_BUYER_PRIVATE_KEY`, `OPTION_SMOKE_SELLER_PRIVATE_KEY`.
///    - `OPTION_ID`, `UNDERLYING`, `OPTION_EXPIRY`, `OPTION_STRIKE_1E8`,
///      `OPTION_IS_CALL`, `OPTION_CONTRACT_SIZE_1E8` (== 1e8).
///
///  Optional env (defaults reproduce V2E-G's ETH-call shape with larger premium):
///    - `OPTION_QUANTITY` (default 1).
///    - `OPTION_PREMIUM_PER_CONTRACT` (default 200_000 native; with -50 ppm
///      maker rebate yields a 10-native rebate; with +125 ppm taker fee yields
///      a 25-native fee — well above the 1-native floor).
///    - `OPTION_BUYER_IS_MAKER` (default false → buyer is the taker fee leg,
///      seller is the maker rebate leg, matching V2E-G).
///    - `OPTION_DEADLINE_SECONDS` (default 600).
///    - `ETH_USDC_PRIMARY_SOURCE` / `ETH_USDC_SECONDARY_SOURCE` /
///      `ETH_USDC_MOCK_PRICE_1E8` (only if refreshing feeds).
///    - `MIN_REBATE_BUDGET` (default 1).
///
///  Hard-refuses:
///    - chain id 8453 (Base mainnet).
///    - V2 not enabled / not wired on MarginEngine.
///    - Merkle root unset / rebate budget below minimum.
///    - Maker tier's OPTION makerPpm ≥ 0 (no rebate path) or taker tier's
///      OPTION takerPpm ≤ 0.
///    - Matching engine paused or caller not an executor when confirmed.
///    - Buyer == seller, missing keys.
///
///  Forbidden surface: no `setMerkleRoot`, no `setFeesManagerV2`, no
///  `setUseFeesManagerV2`, no `setFeeConsumer`, no `setFeeRecipient`, no
///  `setRebateFundingAccount`, no `fundRebateBudget`, no `claimTier`.
contract SmokeOptionV2RebateExecute is Script {
    struct Inputs {
        address caller;
        address optionMatchingEngine;
        address marginEngine;
        address feesManagerV2;
        address collateralVault;
        address settlementAsset;
        uint256 optionId;
        address underlying;
        uint64 expiry;
        uint64 strike1e8;
        bool isCall;
        uint128 contractSize1e8;
        uint128 quantity;
        uint128 premiumPerContract;
        bool buyerIsMaker;
        uint256 deadlineSeconds;
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
        address matchingMarginEngine;
        bool matchingPaused;
        bool deployerIsExecutor;
        address marginFeesManagerV2;
        bool marginUseFeesManagerV2;
        bool fmv2IsFeeConsumerMargin;
        bytes32 fmv2MerkleRoot;
        uint256 fmv2RebateBudgetSettlement;
        address fmv2FeeRecipient;
        address fmv2RebateFundingAccount;
        uint256 feeRecipientVaultBalance;
        uint256 fundingAccountVaultBalance;
        uint256 buyerVaultBalance;
        uint256 sellerVaultBalance;
        uint8 buyerTier;
        uint8 sellerTier;
        IFeesManagerV2.ProductFeeProfilePpm buyerOptionProfile;
        IFeesManagerV2.ProductFeeProfilePpm sellerOptionProfile;
        uint256 ethPrimaryUpdatedAt;
    }

    error MainnetForbidden();
    error OptionMatchingEngineUnset();
    error MarginEngineUnset();
    error FeesManagerV2Unset();
    error CollateralVaultUnset();
    error SettlementAssetUnset();
    error UnderlyingUnset();
    error OptionIdUnset();
    error ExpiryUnset();
    error NoCodeAt(string name, address target);
    error MatchingEngineDoesNotPointToMargin(address expected, address actual);
    error V2NotEnabledOnMarginEngine(address fmv2, bool useFmv2);
    error V2ConsumerMismatch(address consumer);
    error MerkleRootUnset();
    error RebateBudgetBelowMinimum(uint256 budget, uint256 minBudget);
    error MakerHasNoNegativeRebateTier(uint8 tier, int32 ppm);
    error TakerHasNoNonZeroFeePpm(uint8 tier, int32 ppm);
    error MatchingPaused();
    error CallerIsNotExecutor(address caller);
    error SmokeRequiresBuyerAndSellerKeys();
    error BuyerSellerSameAddress();
    error V2WiringChangedDuringRun();
    error MerkleRootChangedDuringRun();
    error NoRebateObserved();
    error NoFeeObserved();

    uint64 internal constant DEFAULT_STRIKE_1E8 = 300_000_000_000;
    uint64 internal constant DEFAULT_EXPIRY = 1_893_456_000; // 2030-01-01
    bool internal constant DEFAULT_IS_CALL = true;
    uint128 internal constant DEFAULT_CONTRACT_SIZE_1E8 = 1e8;
    uint128 internal constant DEFAULT_QUANTITY = 1;
    // Premium 200_000 native (0.2 mUSDC). With -50 ppm maker rebate at Tier 4
    // → rebate = floor(200_000 × 50 / 1e6) = 10 native. With +125 ppm taker
    // fee at Tier 2 → fee = ceil(200_000 × 125 / 1e6) = 25 native. Both well
    // above 1 native, leaving observable accounting deltas.
    uint128 internal constant DEFAULT_PREMIUM = 200_000;
    uint256 internal constant DEFAULT_DEADLINE_SECONDS = 600;
    uint256 internal constant DEFAULT_MIN_REBATE_BUDGET = 1;
    uint256 internal constant DEFAULT_OPTION_ID =
        24145907678156652148089862289363692212069910767044828147380657249455352740183;
    address internal constant DEFAULT_UNDERLYING = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02;
    uint128 internal constant DEFAULT_REFRESH_PRICE_1E8 = 300_000_000_000;

    function run() external {
        if (block.chainid == 8453) revert MainnetForbidden();

        Inputs memory inputs = _readInputs();
        _validateInputs(inputs);

        Snapshot memory before_ = _snapshot(inputs);
        _logInputs(inputs);
        _logSnapshot("before", before_);

        _validatePreconditions(inputs, before_);

        if (!inputs.refreshFeedsConfirmed && !inputs.smokeConfirmed) {
            console2.log("V2G-E OPTION rebate smoke preflight PASSED. No confirm flag set; no transactions sent.");
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

        if (inputs.smokeConfirmed) {
            _logFeeAccounting(inputs, before_, after_);
        }
    }

    function _readInputs() internal view returns (Inputs memory inputs) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        inputs.caller = vm.addr(deployerPk);

        inputs.optionMatchingEngine = _envAddressOrZero("OPTION_MATCHING_ENGINE");
        inputs.marginEngine = _envAddressOrZero("MARGIN_ENGINE");
        inputs.feesManagerV2 = _envAddressOrZero("FEES_MANAGER_V2_ADDRESS");
        inputs.collateralVault = _envAddressOrZero("COLLATERAL_VAULT");
        inputs.settlementAsset = _envAddressOrZero("BASE_COLLATERAL_TOKEN");

        inputs.optionId = vm.envOr("OPTION_ID", DEFAULT_OPTION_ID);
        inputs.underlying = vm.envExists("UNDERLYING") ? vm.envAddress("UNDERLYING") : DEFAULT_UNDERLYING;
        inputs.expiry = uint64(vm.envOr("OPTION_EXPIRY", uint256(DEFAULT_EXPIRY)));
        inputs.strike1e8 = uint64(vm.envOr("OPTION_STRIKE_1E8", uint256(DEFAULT_STRIKE_1E8)));
        inputs.isCall = vm.envOr("OPTION_IS_CALL", DEFAULT_IS_CALL);
        inputs.contractSize1e8 = uint128(vm.envOr("OPTION_CONTRACT_SIZE_1E8", uint256(DEFAULT_CONTRACT_SIZE_1E8)));
        inputs.quantity = uint128(vm.envOr("OPTION_QUANTITY", uint256(DEFAULT_QUANTITY)));
        inputs.premiumPerContract = uint128(vm.envOr("OPTION_PREMIUM_PER_CONTRACT", uint256(DEFAULT_PREMIUM)));
        inputs.buyerIsMaker = vm.envOr("OPTION_BUYER_IS_MAKER", false);
        inputs.deadlineSeconds = vm.envOr("OPTION_DEADLINE_SECONDS", DEFAULT_DEADLINE_SECONDS);

        inputs.ethPrimarySource = _envAddressOrZero("ETH_USDC_PRIMARY_SOURCE");
        inputs.ethSecondarySource = _envAddressOrZero("ETH_USDC_SECONDARY_SOURCE");
        inputs.ethRefreshPrice1e8 = vm.envOr("ETH_USDC_MOCK_PRICE_1E8", uint256(DEFAULT_REFRESH_PRICE_1E8));

        inputs.refreshFeedsConfirmed = vm.envOr("REFRESH_MOCK_FEEDS_CONFIRM", false);
        inputs.smokeConfirmed = vm.envOr("SMOKE_OPTION_V2_REBATE_EXECUTE_CONFIRM", false);

        inputs.buyerPk = vm.envOr("OPTION_SMOKE_BUYER_PRIVATE_KEY", uint256(0));
        inputs.sellerPk = vm.envOr("OPTION_SMOKE_SELLER_PRIVATE_KEY", uint256(0));

        inputs.minRebateBudget = vm.envOr("MIN_REBATE_BUDGET", DEFAULT_MIN_REBATE_BUDGET);
    }

    function _validateInputs(Inputs memory inputs) internal view {
        if (inputs.optionMatchingEngine == address(0)) revert OptionMatchingEngineUnset();
        if (inputs.optionMatchingEngine.code.length == 0) {
            revert NoCodeAt("OPTION_MATCHING_ENGINE", inputs.optionMatchingEngine);
        }
        if (inputs.marginEngine == address(0)) revert MarginEngineUnset();
        if (inputs.marginEngine.code.length == 0) revert NoCodeAt("MARGIN_ENGINE", inputs.marginEngine);
        if (inputs.feesManagerV2 == address(0)) revert FeesManagerV2Unset();
        if (inputs.feesManagerV2.code.length == 0) revert NoCodeAt("FEES_MANAGER_V2_ADDRESS", inputs.feesManagerV2);
        if (inputs.collateralVault == address(0)) revert CollateralVaultUnset();
        if (inputs.collateralVault.code.length == 0) revert NoCodeAt("COLLATERAL_VAULT", inputs.collateralVault);
        if (inputs.settlementAsset == address(0)) revert SettlementAssetUnset();
        if (inputs.underlying == address(0)) revert UnderlyingUnset();
        if (inputs.optionId == 0) revert OptionIdUnset();
        if (inputs.expiry == 0) revert ExpiryUnset();
    }

    function _snapshot(Inputs memory inputs) internal view returns (Snapshot memory snap) {
        OptionMatchingEngine matching = OptionMatchingEngine(inputs.optionMatchingEngine);
        IMarginEngineV2View margin = IMarginEngineV2View(inputs.marginEngine);
        FeesManagerV2 fmv2 = FeesManagerV2(inputs.feesManagerV2);

        snap.matchingMarginEngine = address(matching.marginEngine());
        snap.matchingPaused = matching.paused();
        snap.deployerIsExecutor = matching.isExecutor(inputs.caller);

        try margin.feesManagerV2() returns (address addr) {
            snap.marginFeesManagerV2 = addr;
        } catch {}
        try margin.useFeesManagerV2() returns (bool ok) {
            snap.marginUseFeesManagerV2 = ok;
        } catch {}

        snap.fmv2IsFeeConsumerMargin = fmv2.isFeeConsumer(inputs.marginEngine);
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

        if (inputs.buyerPk != 0) {
            address buyer = vm.addr(inputs.buyerPk);
            snap.buyerVaultBalance =
                ICollateralVaultBalances(inputs.collateralVault).balances(buyer, inputs.settlementAsset);
            snap.buyerTier = fmv2.currentTier(buyer);
            snap.buyerOptionProfile = fmv2.getFeeProfile(snap.buyerTier, IFeesManagerV2.ProductKind.OPTION);
        }
        if (inputs.sellerPk != 0) {
            address seller = vm.addr(inputs.sellerPk);
            snap.sellerVaultBalance =
                ICollateralVaultBalances(inputs.collateralVault).balances(seller, inputs.settlementAsset);
            snap.sellerTier = fmv2.currentTier(seller);
            snap.sellerOptionProfile = fmv2.getFeeProfile(snap.sellerTier, IFeesManagerV2.ProductKind.OPTION);
        }

        if (inputs.ethPrimarySource != address(0) && inputs.ethPrimarySource.code.length != 0) {
            try MockPriceSource(inputs.ethPrimarySource).getLatestPrice() returns (uint256, uint256 t) {
                snap.ethPrimaryUpdatedAt = t;
            } catch {}
        }
    }

    function _validatePreconditions(Inputs memory inputs, Snapshot memory snap) internal view {
        if (snap.matchingMarginEngine != inputs.marginEngine) {
            revert MatchingEngineDoesNotPointToMargin(inputs.marginEngine, snap.matchingMarginEngine);
        }

        if (snap.marginFeesManagerV2 != inputs.feesManagerV2 || !snap.marginUseFeesManagerV2) {
            revert V2NotEnabledOnMarginEngine(snap.marginFeesManagerV2, snap.marginUseFeesManagerV2);
        }
        if (!snap.fmv2IsFeeConsumerMargin) revert V2ConsumerMismatch(inputs.marginEngine);

        if (snap.fmv2MerkleRoot == bytes32(0)) revert MerkleRootUnset();
        if (snap.fmv2RebateBudgetSettlement < inputs.minRebateBudget) {
            revert RebateBudgetBelowMinimum(snap.fmv2RebateBudgetSettlement, inputs.minRebateBudget);
        }

        if (inputs.smokeConfirmed) {
            if (snap.matchingPaused) revert MatchingPaused();
            if (!snap.deployerIsExecutor) revert CallerIsNotExecutor(inputs.caller);
            if (inputs.buyerPk == 0 || inputs.sellerPk == 0) revert SmokeRequiresBuyerAndSellerKeys();
            if (vm.addr(inputs.buyerPk) == vm.addr(inputs.sellerPk)) revert BuyerSellerSameAddress();

            int32 makerPpm = inputs.buyerIsMaker ? snap.buyerOptionProfile.makerPpm : snap.sellerOptionProfile.makerPpm;
            uint8 makerTier = inputs.buyerIsMaker ? snap.buyerTier : snap.sellerTier;
            if (makerPpm >= 0) revert MakerHasNoNegativeRebateTier(makerTier, makerPpm);

            int32 takerPpm = inputs.buyerIsMaker ? snap.sellerOptionProfile.takerPpm : snap.buyerOptionProfile.takerPpm;
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
        OptionMatchingEngine matching = OptionMatchingEngine(inputs.optionMatchingEngine);

        address buyer = vm.addr(inputs.buyerPk);
        address seller = vm.addr(inputs.sellerPk);

        OptionMatchingEngine.OptionTrade memory trade = OptionMatchingEngine.OptionTrade({
            intentId: keccak256(
                abi.encode("v2g_e-option-rebate-smoke", block.timestamp, buyer, seller, inputs.optionId)
            ),
            buyer: buyer,
            seller: seller,
            optionId: inputs.optionId,
            underlying: inputs.underlying,
            settlementAsset: inputs.settlementAsset,
            expiry: inputs.expiry,
            strike1e8: inputs.strike1e8,
            isCall: inputs.isCall,
            contractSize1e8: inputs.contractSize1e8,
            quantity: inputs.quantity,
            premiumPerContract: inputs.premiumPerContract,
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
            before_.marginFeesManagerV2 != after_.marginFeesManagerV2
                || before_.marginUseFeesManagerV2 != after_.marginUseFeesManagerV2
                || before_.fmv2IsFeeConsumerMargin != after_.fmv2IsFeeConsumerMargin
                || before_.fmv2FeeRecipient != after_.fmv2FeeRecipient
                || before_.fmv2RebateFundingAccount != after_.fmv2RebateFundingAccount
        ) {
            revert V2WiringChangedDuringRun();
        }
        if (before_.fmv2MerkleRoot != after_.fmv2MerkleRoot) revert MerkleRootChangedDuringRun();
    }

    function _logFeeAccounting(Inputs memory inputs, Snapshot memory before_, Snapshot memory after_) internal pure {
        int256 buyerDelta = int256(after_.buyerVaultBalance) - int256(before_.buyerVaultBalance);
        int256 sellerDelta = int256(after_.sellerVaultBalance) - int256(before_.sellerVaultBalance);
        int256 feeRecipientDelta = int256(after_.feeRecipientVaultBalance) - int256(before_.feeRecipientVaultBalance);
        int256 fundingAccountDelta =
            int256(after_.fundingAccountVaultBalance) - int256(before_.fundingAccountVaultBalance);
        int256 budgetDelta = int256(after_.fmv2RebateBudgetSettlement) - int256(before_.fmv2RebateBudgetSettlement);

        if (budgetDelta >= 0) revert NoRebateObserved();
        if (feeRecipientDelta == 0) revert NoFeeObserved();

        console2.log("V2G-E OPTION rebate accounting:");
        console2.log(" buyer vault delta (native, includes premium leg)", buyerDelta);
        console2.log(" seller vault delta (native, includes premium leg)", sellerDelta);
        console2.log(" feeRecipient vault delta (native)", feeRecipientDelta);
        console2.log(" rebateFundingAccount vault delta (native)", fundingAccountDelta);
        console2.log(" FeesManagerV2.rebateBudget delta (native)", budgetDelta);

        console2.log(" buyer tier", uint256(after_.buyerTier));
        console2.log(" buyer OPTION makerPpm", int256(after_.buyerOptionProfile.makerPpm));
        console2.log(" buyer OPTION takerPpm", int256(after_.buyerOptionProfile.takerPpm));
        console2.log(" seller tier", uint256(after_.sellerTier));
        console2.log(" seller OPTION makerPpm", int256(after_.sellerOptionProfile.makerPpm));
        console2.log(" seller OPTION takerPpm", int256(after_.sellerOptionProfile.takerPpm));
        console2.log(" quantity", uint256(inputs.quantity));
        console2.log(" premiumPerContract", uint256(inputs.premiumPerContract));
        console2.log(" buyerIsMaker", inputs.buyerIsMaker);
    }

    function _logInputs(Inputs memory inputs) internal view {
        console2.log("V2G-E OPTION rebate smoke (executable)");
        console2.log("chainId", block.chainid);
        console2.log("caller (sanitized)", inputs.caller);
        console2.log("OPTION_MATCHING_ENGINE", inputs.optionMatchingEngine);
        console2.log("MARGIN_ENGINE", inputs.marginEngine);
        console2.log("FEES_MANAGER_V2_ADDRESS", inputs.feesManagerV2);
        console2.log("COLLATERAL_VAULT", inputs.collateralVault);
        console2.log("BASE_COLLATERAL_TOKEN", inputs.settlementAsset);
        console2.log("OPTION_ID", inputs.optionId);
        console2.log("UNDERLYING", inputs.underlying);
        console2.log("OPTION_EXPIRY", uint256(inputs.expiry));
        console2.log("OPTION_STRIKE_1E8", uint256(inputs.strike1e8));
        console2.log("OPTION_IS_CALL", inputs.isCall);
        console2.log("OPTION_CONTRACT_SIZE_1E8", uint256(inputs.contractSize1e8));
        console2.log("OPTION_QUANTITY", uint256(inputs.quantity));
        console2.log("OPTION_PREMIUM_PER_CONTRACT", uint256(inputs.premiumPerContract));
        console2.log("OPTION_BUYER_IS_MAKER", inputs.buyerIsMaker);
        console2.log("OPTION_DEADLINE_SECONDS", inputs.deadlineSeconds);
        console2.log("REFRESH_MOCK_FEEDS_CONFIRM", inputs.refreshFeedsConfirmed);
        console2.log("SMOKE_OPTION_V2_REBATE_EXECUTE_CONFIRM", inputs.smokeConfirmed);
        console2.log("OPTION_SMOKE_BUYER_PRIVATE_KEY (present)", inputs.buyerPk != 0);
        console2.log("OPTION_SMOKE_SELLER_PRIVATE_KEY (present)", inputs.sellerPk != 0);
        console2.log("MIN_REBATE_BUDGET", inputs.minRebateBudget);
    }

    function _logSnapshot(string memory label, Snapshot memory snap) internal pure {
        console2.log("State snapshot:", label);
        console2.log(" Matching.marginEngine()", snap.matchingMarginEngine);
        console2.log(" Matching.paused()", snap.matchingPaused);
        console2.log(" Matching.isExecutor(deployer)", snap.deployerIsExecutor);
        console2.log(" Margin.feesManagerV2()", snap.marginFeesManagerV2);
        console2.log(" Margin.useFeesManagerV2()", snap.marginUseFeesManagerV2);
        console2.log(" FeesManagerV2.isFeeConsumer(MARGIN)", snap.fmv2IsFeeConsumerMargin);
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
        console2.log(" OPTION makerPpm at buyer tier", int256(snap.buyerOptionProfile.makerPpm));
        console2.log(" OPTION takerPpm at buyer tier", int256(snap.buyerOptionProfile.takerPpm));
        console2.log(" OPTION makerPpm at seller tier", int256(snap.sellerOptionProfile.makerPpm));
        console2.log(" OPTION takerPpm at seller tier", int256(snap.sellerOptionProfile.takerPpm));
        console2.log(" ETH primary mock updatedAt", snap.ethPrimaryUpdatedAt);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
