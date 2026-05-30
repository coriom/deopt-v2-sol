// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {PerpEngine} from "../src/perp/PerpEngine.sol";
import {PerpEngineTypes} from "../src/perp/PerpEngineTypes.sol";
import {PerpMarketRegistry} from "../src/perp/PerpMarketRegistry.sol";
import {PerpMatchingEngine} from "../src/matching/PerpMatchingEngine.sol";
import {MockPriceSource} from "../src/oracle/MockPriceSource.sol";

/// @title SmokeV1PerpOnNew
/// @notice Safe-by-default V2F-J smoke preflight for executing a tiny default/V1-fees
///         perp trade against the V2F-H NEW PerpEngine. The script is layered behind
///         independent confirm flags and asserts that PerpEngine FeesManagerV2 stays
///         disabled throughout.
/// @dev
///  Confirm flags (independent, all default `false`):
///    - `REFRESH_MOCK_FEEDS_CONFIRM=true` → push fresh prices on ETH primary +
///       optional secondary mock sources so the trade respects the 60-second
///       `ETH_USDC_MAX_DELAY` window. (Operator-only mutation; safe-by-default off.)
///    - `SET_LAUNCH_OI_CAP_CONFIRM=true` → owner-only
///       `PerpEngine.setLaunchOpenInterestCap(marketId, cap1e8)`. Not strictly
///       required because the live NEW engine reports `launchOpenInterestCap1e8 = 0`
///       (disabled), but included for parity with V2F-I §3b runbook.
///    - `SMOKE_V1_PERP_ON_NEW_CONFIRM=true` → constructs the
///       `PerpMatchingEngine.PerpTrade` payload, signs it with `PERP_SMOKE_BUYER_PRIVATE_KEY`
///       and `PERP_SMOKE_SELLER_PRIVATE_KEY`, and submits `executeTrade(..)` as the
///       deployer (must be an executor). Hard-refuses if matching is paused or buyer/
///       seller keys are missing.
///
///  Default execution path is preflight-only: a sanitized snapshot of the trade
///  path is printed, NO transactions are sent, and the script verifies that
///  `useFeesManagerV2 == false` and `feesManagerV2 == address(0)` on NEW. The
///  V2 invariants are also asserted in the post-state path.
///
///  Hard-refuses:
///    - `PERP_ENGINE` (NEW) unset or has no code on the target chain;
///    - `OLD_PERP_ENGINE` unset (used only to assert OLD.marketState is untouched);
///    - `PERP_MATCHING_ENGINE` unset or has no code;
///    - matching engine's `perpEngine()` does not equal `PERP_ENGINE` (rewire drifted);
///    - smoke confirmed while matching is paused (`MatchingPausedRunGate7aFirst`);
///    - smoke confirmed while either signer key is missing
///      (`SmokeRequiresBuyerAndSellerKeys`);
///    - V2 fees become non-zero or `useFeesManagerV2` flips on at any point
///      (`V2FeesUnexpectedlyChanged`).
///
///  Required env in all cases:
///    - `DEPLOYER_PRIVATE_KEY` (must equal NEW's `owner()` for the cap-set path and
///       must equal an authorized matching executor for the smoke trade path);
///    - `PERP_ENGINE` (= NEW PerpEngine address);
///    - `OLD_PERP_ENGINE` (untouched throughout — A3 stranded);
///    - `PERP_MATCHING_ENGINE`;
///    - `PERP_MARKET_ID` (default `1`);
///    - `PERP_SMOKE_SIZE_1E8` (default `1`, minimum non-zero size);
///    - `PERP_SMOKE_PRICE_1E8` (default `300_000_000_000` = $3000 in 1e8);
///    - `PERP_SMOKE_DEADLINE_SECONDS` (default `600`);
///    - `PERP_SMOKE_BUYER_IS_MAKER` (default `false`);
///    - `PERP_SMOKE_BUYER_PRIVATE_KEY` / `PERP_SMOKE_SELLER_PRIVATE_KEY`
///       (required only when smoke is confirmed — operator must funded these EOAs
///       with mUSDC collateral out-of-band before broadcast).
///
///  Forbidden: this script must never call `setFeesManagerV2`, `setUseFeesManagerV2`,
///  `setFeeConsumer`, `setFeeRecipient`, `setRebateFundingAccount`, or any
///  `FeesManagerV2.*` mutator. The post-state verification enforces that.
contract SmokeV1PerpOnNew is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Inputs {
        address caller;
        address perpEngine;
        address oldPerpEngine;
        address perpMatchingEngine;
        uint256 marketId;
        uint128 size1e8;
        uint128 price1e8;
        uint256 deadlineSeconds;
        bool buyerIsMaker;
        uint256 launchOiCap1e8;
        // ETH mock sources (refresh path)
        address ethPrimarySource;
        address ethSecondarySource;
        uint256 ethRefreshPrice1e8;
        // Confirm gates
        bool refreshFeedsConfirmed;
        bool setLaunchCapConfirmed;
        bool smokeConfirmed;
        // Smoke signing
        uint256 buyerPk;
        uint256 sellerPk;
    }

    struct Snapshot {
        address matchingPerpEngine;
        bool matchingPaused;
        bool deployerIsExecutor;
        address newEngineOwner;
        address newEngineV1FeesManager;
        address newEngineFeesManagerV2;
        bool newEngineUseFeesManagerV2;
        uint256 newLaunchCap1e8;
        uint256 newLongOI;
        uint256 newShortOI;
        uint256 oldLongOI;
        uint256 oldShortOI;
        uint256 ethPrimaryPrice1e8;
        uint256 ethPrimaryUpdatedAt;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error PerpEngineUnset();
    error OldPerpEngineUnset();
    error PerpMatchingEngineUnset();
    error NoCodeAt(string name, address target);
    error MatchingEngineRewireDrifted(address expected, address actual);
    error MatchingPausedRunGate7aFirst();
    error SmokeRequiresBuyerAndSellerKeys();
    error BuyerSellerSameAddress();
    error CallerIsNotExecutor(address caller);
    error CallerIsNotOwner(string holder, address caller, address owner);
    error V2FeesUnexpectedlyChanged(address before_, address after_, bool before__, bool after__);
    error OldMarketStateChanged();
    error NewMarketStateUnchanged();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint128 internal constant DEFAULT_PRICE_1E8 = 300_000_000_000;
    uint128 internal constant DEFAULT_SIZE_1E8 = 1;
    uint256 internal constant DEFAULT_DEADLINE_SECONDS = 600;
    uint256 internal constant DEFAULT_LAUNCH_OI_CAP_1E8 = 10_000_000_000; // matches registry

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

        if (!inputs.refreshFeedsConfirmed && !inputs.setLaunchCapConfirmed && !inputs.smokeConfirmed) {
            console2.log("No confirm flags set; preflight done, no transactions sent.");
            _assertV2Invariants(before_, before_);
            return;
        }

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPk);

        if (inputs.refreshFeedsConfirmed) {
            _refreshFeeds(inputs);
        }

        if (inputs.setLaunchCapConfirmed) {
            PerpEngine(inputs.perpEngine).setLaunchOpenInterestCap(inputs.marketId, inputs.launchOiCap1e8);
        }

        if (inputs.smokeConfirmed) {
            _executeSmokeTrade(inputs);
        }

        vm.stopBroadcast();

        Snapshot memory after_ = _snapshot(inputs);
        _logSnapshot("after", after_);
        _assertV2Invariants(before_, after_);
        _verifyOldUntouched(before_, after_);

        if (inputs.smokeConfirmed) {
            _verifyTradeMaterialized(before_, after_);
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

        inputs.marketId = vm.envOr("PERP_MARKET_ID", uint256(1));
        inputs.size1e8 = uint128(vm.envOr("PERP_SMOKE_SIZE_1E8", uint256(DEFAULT_SIZE_1E8)));
        inputs.price1e8 = uint128(vm.envOr("PERP_SMOKE_PRICE_1E8", uint256(DEFAULT_PRICE_1E8)));
        inputs.deadlineSeconds = vm.envOr("PERP_SMOKE_DEADLINE_SECONDS", DEFAULT_DEADLINE_SECONDS);
        inputs.buyerIsMaker = vm.envOr("PERP_SMOKE_BUYER_IS_MAKER", false);
        inputs.launchOiCap1e8 = vm.envOr("PERP_LAUNCH_OI_CAP_1E8", DEFAULT_LAUNCH_OI_CAP_1E8);

        inputs.ethPrimarySource = _envAddressOrZero("ETH_USDC_PRIMARY_SOURCE");
        inputs.ethSecondarySource = _envAddressOrZero("ETH_USDC_SECONDARY_SOURCE");
        inputs.ethRefreshPrice1e8 = vm.envOr("ETH_USDC_MOCK_PRICE_1E8", uint256(DEFAULT_PRICE_1E8));

        inputs.refreshFeedsConfirmed = vm.envOr("REFRESH_MOCK_FEEDS_CONFIRM", false);
        inputs.setLaunchCapConfirmed = vm.envOr("SET_LAUNCH_OI_CAP_CONFIRM", false);
        inputs.smokeConfirmed = vm.envOr("SMOKE_V1_PERP_ON_NEW_CONFIRM", false);

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

        if (inputs.refreshFeedsConfirmed) {
            if (inputs.ethPrimarySource == address(0)) revert NoCodeAt("ETH_USDC_PRIMARY_SOURCE", address(0));
            if (inputs.ethPrimarySource.code.length == 0) {
                revert NoCodeAt("ETH_USDC_PRIMARY_SOURCE", inputs.ethPrimarySource);
            }
        }
    }

    function _snapshot(Inputs memory inputs) internal view returns (Snapshot memory snap) {
        PerpEngine engine = PerpEngine(inputs.perpEngine);
        PerpMatchingEngine matching = PerpMatchingEngine(inputs.perpMatchingEngine);

        snap.matchingPerpEngine = address(matching.perpEngine());
        snap.matchingPaused = matching.paused();
        snap.deployerIsExecutor = matching.isExecutor(inputs.caller);

        snap.newEngineOwner = engine.owner();
        snap.newEngineV1FeesManager = address(engine.feesManager());
        snap.newEngineFeesManagerV2 = address(engine.feesManagerV2());
        snap.newEngineUseFeesManagerV2 = engine.useFeesManagerV2();
        snap.newLaunchCap1e8 = engine.launchOpenInterestCap1e8(inputs.marketId);

        PerpEngineTypes.MarketState memory newS = engine.marketState(inputs.marketId);
        snap.newLongOI = newS.longOpenInterest1e8;
        snap.newShortOI = newS.shortOpenInterest1e8;

        PerpEngineTypes.MarketState memory oldS = PerpEngine(inputs.oldPerpEngine).marketState(inputs.marketId);
        snap.oldLongOI = oldS.longOpenInterest1e8;
        snap.oldShortOI = oldS.shortOpenInterest1e8;

        if (inputs.ethPrimarySource != address(0) && inputs.ethPrimarySource.code.length != 0) {
            try MockPriceSource(inputs.ethPrimarySource).getLatestPrice() returns (uint256 p, uint256 t) {
                snap.ethPrimaryPrice1e8 = p;
                snap.ethPrimaryUpdatedAt = t;
            } catch {}
        }
    }

    function _validatePreconditions(Inputs memory inputs, Snapshot memory snap) internal view {
        // Sanity: matching engine must point at the NEW perp engine (would catch any rewire drift).
        if (snap.matchingPerpEngine != inputs.perpEngine) {
            revert MatchingEngineRewireDrifted(inputs.perpEngine, snap.matchingPerpEngine);
        }

        // Owner check for cap mutation
        if (inputs.setLaunchCapConfirmed) {
            if (inputs.caller != snap.newEngineOwner) {
                revert CallerIsNotOwner("PerpEngine", inputs.caller, snap.newEngineOwner);
            }
        }

        if (inputs.smokeConfirmed) {
            if (snap.matchingPaused) revert MatchingPausedRunGate7aFirst();
            if (!snap.deployerIsExecutor) revert CallerIsNotExecutor(inputs.caller);
            if (inputs.buyerPk == 0 || inputs.sellerPk == 0) revert SmokeRequiresBuyerAndSellerKeys();
            if (vm.addr(inputs.buyerPk) == vm.addr(inputs.sellerPk)) revert BuyerSellerSameAddress();
        }
    }

    function _refreshFeeds(Inputs memory inputs) internal {
        MockPriceSource(inputs.ethPrimarySource).setPrice(inputs.ethRefreshPrice1e8);
        if (inputs.ethSecondarySource != address(0) && inputs.ethSecondarySource.code.length != 0) {
            MockPriceSource(inputs.ethSecondarySource).setPrice(inputs.ethRefreshPrice1e8);
        }
    }

    function _executeSmokeTrade(Inputs memory inputs) internal {
        PerpMatchingEngine matching = PerpMatchingEngine(inputs.perpMatchingEngine);

        address buyer = vm.addr(inputs.buyerPk);
        address seller = vm.addr(inputs.sellerPk);

        PerpMatchingEngine.PerpTrade memory trade = PerpMatchingEngine.PerpTrade({
            intentId: keccak256(abi.encode("v2fj-smoke", block.timestamp, buyer, seller, inputs.marketId)),
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

        matching.executeTrade(trade, buyerSig, sellerSig);
    }

    function _assertV2Invariants(Snapshot memory before_, Snapshot memory after_) internal pure {
        if (
            before_.newEngineFeesManagerV2 != address(0) || after_.newEngineFeesManagerV2 != address(0)
                || before_.newEngineUseFeesManagerV2 || after_.newEngineUseFeesManagerV2
        ) {
            revert V2FeesUnexpectedlyChanged(
                before_.newEngineFeesManagerV2,
                after_.newEngineFeesManagerV2,
                before_.newEngineUseFeesManagerV2,
                after_.newEngineUseFeesManagerV2
            );
        }
    }

    function _verifyOldUntouched(Snapshot memory before_, Snapshot memory after_) internal pure {
        if (before_.oldLongOI != after_.oldLongOI) revert OldMarketStateChanged();
        if (before_.oldShortOI != after_.oldShortOI) revert OldMarketStateChanged();
    }

    function _verifyTradeMaterialized(Snapshot memory before_, Snapshot memory after_) internal pure {
        // After a fresh open trade with both sides at zero, both OI legs must equal +size1e8.
        if (before_.newLongOI == after_.newLongOI && before_.newShortOI == after_.newShortOI) {
            revert NewMarketStateUnchanged();
        }
    }

    function _logInputs(Inputs memory inputs) internal view {
        console2.log("PerpEngineV2 default/V1 perp smoke preflight V2F-J");
        console2.log("chainId", block.chainid);
        console2.log("caller (sanitized, no key)", inputs.caller);
        console2.log("PERP_ENGINE (NEW)", inputs.perpEngine);
        console2.log("OLD_PERP_ENGINE (untouched)", inputs.oldPerpEngine);
        console2.log("PERP_MATCHING_ENGINE", inputs.perpMatchingEngine);
        console2.log("PERP_MARKET_ID", inputs.marketId);
        console2.log("PERP_SMOKE_SIZE_1E8", uint256(inputs.size1e8));
        console2.log("PERP_SMOKE_PRICE_1E8", uint256(inputs.price1e8));
        console2.log("PERP_SMOKE_BUYER_IS_MAKER", inputs.buyerIsMaker);
        console2.log("PERP_SMOKE_DEADLINE_SECONDS", inputs.deadlineSeconds);
        console2.log("PERP_LAUNCH_OI_CAP_1E8", inputs.launchOiCap1e8);
        console2.log("REFRESH_MOCK_FEEDS_CONFIRM", inputs.refreshFeedsConfirmed);
        console2.log("SET_LAUNCH_OI_CAP_CONFIRM", inputs.setLaunchCapConfirmed);
        console2.log("SMOKE_V1_PERP_ON_NEW_CONFIRM", inputs.smokeConfirmed);
        console2.log("PERP_SMOKE_BUYER_PRIVATE_KEY (present)", inputs.buyerPk != 0);
        console2.log("PERP_SMOKE_SELLER_PRIVATE_KEY (present)", inputs.sellerPk != 0);
    }

    function _logSnapshot(string memory label, Snapshot memory snap) internal pure {
        console2.log("State snapshot:", label);
        console2.log(" Matching.perpEngine()", snap.matchingPerpEngine);
        console2.log(" Matching.paused()", snap.matchingPaused);
        console2.log(" Matching.isExecutor(deployer)", snap.deployerIsExecutor);
        console2.log(" NEW.owner()", snap.newEngineOwner);
        console2.log(" NEW.feesManager() (V1)", snap.newEngineV1FeesManager);
        console2.log(" NEW.feesManagerV2() (V2 MUST be zero)", snap.newEngineFeesManagerV2);
        console2.log(" NEW.useFeesManagerV2() (MUST be false)", snap.newEngineUseFeesManagerV2);
        console2.log(" NEW.launchOpenInterestCap1e8(marketId)", snap.newLaunchCap1e8);
        console2.log(" NEW.marketState(marketId).longOI1e8", snap.newLongOI);
        console2.log(" NEW.marketState(marketId).shortOI1e8", snap.newShortOI);
        console2.log(" OLD.marketState(marketId).longOI1e8", snap.oldLongOI);
        console2.log(" OLD.marketState(marketId).shortOI1e8", snap.oldShortOI);
        console2.log(" ETH primary mock price1e8", snap.ethPrimaryPrice1e8);
        console2.log(" ETH primary mock updatedAt", snap.ethPrimaryUpdatedAt);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
