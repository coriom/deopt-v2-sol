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

/// @title SmokeV2PerpFeesOnNew
/// @notice V2F-LM smoke that verifies the V2 fee path on the NEW PerpEngine after V2F-L
///         enabled `useFeesManagerV2 = true`. Asserts V2 invariants ENABLED both
///         before and after, executes one tiny perp trade, and tracks the
///         `FeeChargedV2`/`FeeRebatedV2` accounting via on-chain balance deltas.
/// @dev
///  Mirrors `script/SmokeV1PerpOnNew.s.sol` but with V2-enabled invariants:
///    - asserts `NEW.useFeesManagerV2() == true` (not false) at both snapshots;
///    - asserts `NEW.feesManagerV2() != address(0)` and matches `FEES_MANAGER_V2_ADDRESS`;
///    - asserts `FeesManagerV2.isFeeConsumer(NEW) == true` (consumer wiring intact);
///    - asserts `FeesManagerV2.rebateBudget(settlementAsset) == 0` (no rebates funded
///       — this implies any signed-ppm rebate path is unfunded, so a rebate would
///       either be skipped (rebateFundable = false) or error; the assertion is
///       a defense-in-depth check that we never call this with rebates active);
///    - asserts `FeesManagerV2.merkleRoot() == bytes32(0)` (no tier claims; all
///       traders default to Tier 0).
///
///  Confirm flags:
///    - `REFRESH_MOCK_FEEDS_CONFIRM=true` → mock feed refresh inside the 60-second
///       `ETH_USDC_MAX_DELAY` window.
///    - `SMOKE_V2_PERP_FEES_ON_NEW_CONFIRM=true` → constructs the `PerpTrade`,
///       signs with `PERP_SMOKE_BUYER_PRIVATE_KEY` + `PERP_SMOKE_SELLER_PRIVATE_KEY`,
///       calls `PerpMatchingEngine.executeTrade(...)`.
///
///  Default is preflight-only. Hard-refuses smoke when:
///    - matching is paused (`MatchingPausedRunGate7aFirst`),
///    - V2 not enabled or not wired (`V2NotEnabledRunGate7dFirst`),
///    - buyer or seller key missing (`SmokeRequiresBuyerAndSellerKeys`),
///    - buyer == seller (`BuyerSellerSameAddress`),
///    - rebate budget set or merkle root set
///      (`RebateOrMerkleStateUnexpected`).
///
///  Forbidden surface: no `setFeesManagerV2`, no `setUseFeesManagerV2`, no
///  `setFeeConsumer`, no `setFeeRecipient`, no `setRebateFundingAccount`,
///  no `fundRebateBudget`, no `setMerkleRoot`, no `claimTier`. The post-state
///  asserts that none of those mutated.
contract SmokeV2PerpFeesOnNew is Script {
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
    }

    struct Snapshot {
        address matchingPerpEngine;
        bool matchingPaused;
        bool deployerIsExecutor;
        address newEngineFeesManagerV2;
        bool newEngineUseFeesManagerV2;
        bool fmv2IsFeeConsumerNew;
        bytes32 fmv2MerkleRoot;
        uint256 fmv2RebateBudgetSettlement;
        address fmv2FeeRecipient;
        address fmv2RebateFundingAccount;
        uint256 feeRecipientVaultBalance;
        uint256 newLongOI;
        uint256 newShortOI;
        uint256 oldLongOI;
        uint256 oldShortOI;
        uint256 buyerVaultBalance;
        uint256 sellerVaultBalance;
        uint8 buyerTier;
        uint8 sellerTier;
        IFeesManagerV2.ProductFeeProfilePpm tier0PerpProfile;
        uint8 perpFeeBasis;
        uint256 ethPrimaryUpdatedAt;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error PerpEngineUnset();
    error OldPerpEngineUnset();
    error PerpMatchingEngineUnset();
    error FeesManagerV2Unset();
    error CollateralVaultUnset();
    error NoCodeAt(string name, address target);
    error MatchingEngineRewireDrifted(address expected, address actual);
    error V2NotEnabledRunGate7dFirst(address feesManagerV2, bool useFeesManagerV2);
    error V2ConsumerMismatch(address consumer);
    error MatchingPausedRunGate7aFirst();
    error CallerIsNotExecutor(address caller);
    error SmokeRequiresBuyerAndSellerKeys();
    error BuyerSellerSameAddress();
    error RebateOrMerkleStateUnexpected(bytes32 merkleRoot, uint256 rebateBudget);
    error V2WiringChangedDuringRun();
    error OldMarketStateChanged();
    error NewMarketStateUnchanged();
    error V1FallbackUnexpected();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint128 internal constant DEFAULT_PRICE_1E8 = 300_000_000_000;
    uint128 internal constant DEFAULT_SIZE_1E8 = 1;
    uint256 internal constant DEFAULT_DEADLINE_SECONDS = 600;

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        Inputs memory inputs = _readInputs();
        _validateInputs(inputs);

        Snapshot memory before_ = _snapshot(inputs);
        _logInputs(inputs);
        _logSnapshot("before", before_);

        _validatePreconditions(inputs, before_);

        if (!inputs.refreshFeedsConfirmed && !inputs.smokeConfirmed) {
            console2.log("No confirm flags set; preflight done, no transactions sent.");
            _assertV2EnabledInvariants(inputs, before_, before_);
            return;
        }

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPk);

        if (inputs.refreshFeedsConfirmed) {
            _refreshFeeds(inputs);
        }

        vm.stopBroadcast();

        if (inputs.smokeConfirmed) {
            _executeSmokeTrade(inputs);
        }

        Snapshot memory after_ = _snapshot(inputs);
        _logSnapshot("after", after_);
        _assertV2EnabledInvariants(inputs, before_, after_);
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
        inputs.oldPerpEngine = _envAddressOrZero("OLD_PERP_ENGINE");
        inputs.perpMatchingEngine = _envAddressOrZero("PERP_MATCHING_ENGINE");
        inputs.feesManagerV2 = _envAddressOrZero("FEES_MANAGER_V2_ADDRESS");
        inputs.collateralVault = _envAddressOrZero("COLLATERAL_VAULT");
        inputs.settlementAsset = _envAddressOrZero("BASE_COLLATERAL_TOKEN");

        inputs.marketId = vm.envOr("PERP_MARKET_ID", uint256(1));
        inputs.size1e8 = uint128(vm.envOr("PERP_SMOKE_SIZE_1E8", uint256(DEFAULT_SIZE_1E8)));
        inputs.price1e8 = uint128(vm.envOr("PERP_SMOKE_PRICE_1E8", uint256(DEFAULT_PRICE_1E8)));
        inputs.deadlineSeconds = vm.envOr("PERP_SMOKE_DEADLINE_SECONDS", DEFAULT_DEADLINE_SECONDS);
        inputs.buyerIsMaker = vm.envOr("PERP_SMOKE_BUYER_IS_MAKER", false);

        inputs.ethPrimarySource = _envAddressOrZero("ETH_USDC_PRIMARY_SOURCE");
        inputs.ethSecondarySource = _envAddressOrZero("ETH_USDC_SECONDARY_SOURCE");
        inputs.ethRefreshPrice1e8 = vm.envOr("ETH_USDC_MOCK_PRICE_1E8", uint256(DEFAULT_PRICE_1E8));

        inputs.refreshFeedsConfirmed = vm.envOr("REFRESH_MOCK_FEEDS_CONFIRM", false);
        inputs.smokeConfirmed = vm.envOr("SMOKE_V2_PERP_FEES_ON_NEW_CONFIRM", false);

        inputs.buyerPk = vm.envOr("PERP_SMOKE_BUYER_PRIVATE_KEY", uint256(0));
        inputs.sellerPk = vm.envOr("PERP_SMOKE_SELLER_PRIVATE_KEY", uint256(0));
    }

    function _validateInputs(Inputs memory inputs) internal view {
        if (inputs.perpEngine == address(0)) revert PerpEngineUnset();
        if (inputs.perpEngine.code.length == 0) revert NoCodeAt("PERP_ENGINE", inputs.perpEngine);

        if (inputs.oldPerpEngine == address(0)) revert OldPerpEngineUnset();
        if (inputs.oldPerpEngine.code.length == 0) revert NoCodeAt("OLD_PERP_ENGINE", inputs.oldPerpEngine);

        if (inputs.perpMatchingEngine == address(0)) revert PerpMatchingEngineUnset();
        if (inputs.perpMatchingEngine.code.length == 0) {
            revert NoCodeAt("PERP_MATCHING_ENGINE", inputs.perpMatchingEngine);
        }

        if (inputs.feesManagerV2 == address(0)) revert FeesManagerV2Unset();
        if (inputs.feesManagerV2.code.length == 0) revert NoCodeAt("FEES_MANAGER_V2_ADDRESS", inputs.feesManagerV2);

        if (inputs.collateralVault == address(0)) revert CollateralVaultUnset();
        if (inputs.collateralVault.code.length == 0) revert NoCodeAt("COLLATERAL_VAULT", inputs.collateralVault);
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

        snap.fmv2IsFeeConsumerNew = fmv2.isFeeConsumer(inputs.perpEngine);
        snap.fmv2MerkleRoot = fmv2.merkleRoot();
        snap.fmv2RebateBudgetSettlement = fmv2.rebateBudget(inputs.settlementAsset);
        snap.fmv2FeeRecipient = fmv2.feeRecipient();
        snap.fmv2RebateFundingAccount = fmv2.rebateFundingAccount();

        if (snap.fmv2FeeRecipient != address(0) && inputs.settlementAsset != address(0)) {
            snap.feeRecipientVaultBalance = ICollateralVaultBalances(inputs.collateralVault)
                .balances(snap.fmv2FeeRecipient, inputs.settlementAsset);
        }

        PerpEngineTypes.MarketState memory newS = engine.marketState(inputs.marketId);
        snap.newLongOI = newS.longOpenInterest1e8;
        snap.newShortOI = newS.shortOpenInterest1e8;

        PerpEngineTypes.MarketState memory oldS = PerpEngine(inputs.oldPerpEngine).marketState(inputs.marketId);
        snap.oldLongOI = oldS.longOpenInterest1e8;
        snap.oldShortOI = oldS.shortOpenInterest1e8;

        if (inputs.buyerPk != 0) {
            snap.buyerVaultBalance = ICollateralVaultBalances(inputs.collateralVault)
                .balances(vm.addr(inputs.buyerPk), inputs.settlementAsset);
            snap.buyerTier = fmv2.currentTier(vm.addr(inputs.buyerPk));
        }
        if (inputs.sellerPk != 0) {
            snap.sellerVaultBalance = ICollateralVaultBalances(inputs.collateralVault)
                .balances(vm.addr(inputs.sellerPk), inputs.settlementAsset);
            snap.sellerTier = fmv2.currentTier(vm.addr(inputs.sellerPk));
        }

        snap.tier0PerpProfile = fmv2.getFeeProfile(0, IFeesManagerV2.ProductKind.PERP);
        snap.perpFeeBasis = uint8(fmv2.productFeeBasis(IFeesManagerV2.ProductKind.PERP));

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

        if (snap.fmv2MerkleRoot != bytes32(0) || snap.fmv2RebateBudgetSettlement != 0) {
            revert RebateOrMerkleStateUnexpected(snap.fmv2MerkleRoot, snap.fmv2RebateBudgetSettlement);
        }

        if (inputs.smokeConfirmed) {
            if (snap.matchingPaused) revert MatchingPausedRunGate7aFirst();
            if (!snap.deployerIsExecutor) revert CallerIsNotExecutor(inputs.caller);
            if (inputs.buyerPk == 0 || inputs.sellerPk == 0) revert SmokeRequiresBuyerAndSellerKeys();
            if (vm.addr(inputs.buyerPk) == vm.addr(inputs.sellerPk)) revert BuyerSellerSameAddress();
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

    function _executeSmokeTrade(Inputs memory inputs) internal {
        PerpMatchingEngine matching = PerpMatchingEngine(inputs.perpMatchingEngine);

        address buyer = vm.addr(inputs.buyerPk);
        address seller = vm.addr(inputs.sellerPk);

        PerpMatchingEngine.PerpTrade memory trade = PerpMatchingEngine.PerpTrade({
            intentId: keccak256(abi.encode("v2flm-smoke", block.timestamp, buyer, seller, inputs.marketId)),
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

        // Caller (executor) broadcast for executeTrade. Sigs above were produced via vm.sign
        // and never reveal the buyer/seller private keys to logs.
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPk);
        matching.executeTrade(trade, buyerSig, sellerSig);
        vm.stopBroadcast();
    }

    function _assertV2EnabledInvariants(Inputs memory inputs, Snapshot memory before_, Snapshot memory after_)
        internal
        pure
    {
        // V2 must stay enabled and wired through the entire run.
        if (
            before_.newEngineFeesManagerV2 != inputs.feesManagerV2
                || after_.newEngineFeesManagerV2 != inputs.feesManagerV2 || !before_.newEngineUseFeesManagerV2
                || !after_.newEngineUseFeesManagerV2 || !before_.fmv2IsFeeConsumerNew || !after_.fmv2IsFeeConsumerNew
        ) {
            revert V2WiringChangedDuringRun();
        }

        // Rebate budget and merkle root must remain zero (no rebates funded, no tier claims).
        if (
            before_.fmv2RebateBudgetSettlement != 0 || after_.fmv2RebateBudgetSettlement != 0
                || before_.fmv2MerkleRoot != bytes32(0) || after_.fmv2MerkleRoot != bytes32(0)
        ) {
            revert RebateOrMerkleStateUnexpected(after_.fmv2MerkleRoot, after_.fmv2RebateBudgetSettlement);
        }
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
        console2.log("V2 fee accounting (smoke):");
        int256 feeRecipientDelta = int256(after_.feeRecipientVaultBalance) - int256(before_.feeRecipientVaultBalance);
        int256 buyerDelta = int256(after_.buyerVaultBalance) - int256(before_.buyerVaultBalance);
        int256 sellerDelta = int256(after_.sellerVaultBalance) - int256(before_.sellerVaultBalance);

        console2.log(" feeRecipient vault delta (settlement native)", feeRecipientDelta);
        console2.log(" buyer vault delta", buyerDelta);
        console2.log(" seller vault delta", sellerDelta);
        console2.log(" Tier0 PERP makerPpm", int256(inputs.size1e8 != 0 ? after_.tier0PerpProfile.makerPpm : int32(0)));
        console2.log(" Tier0 PERP takerPpm", int256(inputs.size1e8 != 0 ? after_.tier0PerpProfile.takerPpm : int32(0)));

        // Defense-in-depth: if no positive fee was charged, the smoke may have hit
        // the V1 fallback (which shouldn't happen since useFeesManagerV2=true).
        if (feeRecipientDelta == 0 && buyerDelta == 0 && sellerDelta == 0) {
            revert V1FallbackUnexpected();
        }
    }

    function _logInputs(Inputs memory inputs) internal view {
        console2.log("PerpEngineV2 V2-fees perp smoke preflight V2F-LM");
        console2.log("chainId", block.chainid);
        console2.log("caller (sanitized, no key)", inputs.caller);
        console2.log("PERP_ENGINE (NEW)", inputs.perpEngine);
        console2.log("OLD_PERP_ENGINE (untouched)", inputs.oldPerpEngine);
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
        console2.log("SMOKE_V2_PERP_FEES_ON_NEW_CONFIRM", inputs.smokeConfirmed);
        console2.log("PERP_SMOKE_BUYER_PRIVATE_KEY (present)", inputs.buyerPk != 0);
        console2.log("PERP_SMOKE_SELLER_PRIVATE_KEY (present)", inputs.sellerPk != 0);
    }

    function _logSnapshot(string memory label, Snapshot memory snap) internal pure {
        console2.log("State snapshot:", label);
        console2.log(" Matching.perpEngine()", snap.matchingPerpEngine);
        console2.log(" Matching.paused()", snap.matchingPaused);
        console2.log(" Matching.isExecutor(deployer)", snap.deployerIsExecutor);
        console2.log(" NEW.feesManagerV2()", snap.newEngineFeesManagerV2);
        console2.log(" NEW.useFeesManagerV2() (MUST be true)", snap.newEngineUseFeesManagerV2);
        console2.log(" FeesManagerV2.isFeeConsumer(NEW)", snap.fmv2IsFeeConsumerNew);
        console2.log(" FeesManagerV2.merkleRoot()", uint256(snap.fmv2MerkleRoot));
        console2.log(" FeesManagerV2.rebateBudget(settlement)", snap.fmv2RebateBudgetSettlement);
        console2.log(" FeesManagerV2.feeRecipient()", snap.fmv2FeeRecipient);
        console2.log(" FeesManagerV2.rebateFundingAccount()", snap.fmv2RebateFundingAccount);
        console2.log(" Vault.balances(feeRecipient, settlement)", snap.feeRecipientVaultBalance);
        console2.log(" Vault.balances(buyer, settlement)", snap.buyerVaultBalance);
        console2.log(" Vault.balances(seller, settlement)", snap.sellerVaultBalance);
        console2.log(" FeesManagerV2.currentTier(buyer)", uint256(snap.buyerTier));
        console2.log(" FeesManagerV2.currentTier(seller)", uint256(snap.sellerTier));
        console2.log(" Tier0 PERP makerPpm", int256(snap.tier0PerpProfile.makerPpm));
        console2.log(" Tier0 PERP takerPpm", int256(snap.tier0PerpProfile.takerPpm));
        console2.log(" productFeeBasis(PERP)", uint256(snap.perpFeeBasis));
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
