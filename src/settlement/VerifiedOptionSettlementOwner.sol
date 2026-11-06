// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {OptionProductRegistry} from "../OptionProductRegistry.sol";

interface IHistoricalChainlinkFeed {
    function decimals() external view returns (uint8);
    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IHistoricalPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    struct PriceFeed {
        bytes32 id;
        Price price;
        Price emaPrice;
    }

    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);
    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PriceFeed[] memory);
}

/// @notice Prototype Registry owner. Pre-existing series retain a narrowly
///         scoped Timelock settlement path; prospective series require an
///         oracle proof. No general-purpose ownership escape is exposed.
/// @dev Its policy parameters are immutable and require separate approval.
contract VerifiedOptionSettlementOwner {
    error NotTimelock();
    error NotEmergencyGuardian();
    error WrongChain();
    error UnsafeRegistryState();
    error UnsupportedSeries();
    error LegacySeriesRestricted();
    error TooManyLegacySeries();
    error UnresolvedDivergence();
    error InvalidRoundProof();
    error InvalidPriceProof();
    error ProposalExists();
    error NoProposal();
    error ChallengeClosed();
    error NoMaterialDisagreement();
    error InvalidState();
    error ChallengeOpen();
    error ForbiddenAdminCall();
    error InvalidFee();

    enum SettlementState {
        PRICE_UNAVAILABLE,
        PRICE_PROPOSED,
        CHALLENGED,
        RESOLVED,
        FINALIZED
    }

    struct Proposal {
        uint256 chainlinkPrice1e8;
        uint256 pythPrice1e8;
        uint256 selectedPrice1e8;
        uint80 beforeRound;
        uint80 afterRound;
        uint64 proposedAt;
        SettlementState state;
    }

    OptionProductRegistry public immutable registry;
    uint256 public immutable deploymentChainId;
    address public immutable timelock;
    address public immutable emergencyGuardian;
    address public immutable settlementAsset;
    IHistoricalPyth public immutable pyth;
    uint64 public immutable maxBeforeAge;
    uint64 public immutable maxAfterLag;
    uint64 public immutable challengePeriod;
    uint32 public immutable maxDivergenceBps;
    uint32 public immutable maxPythConfidenceBps;

    mapping(address => IHistoricalChainlinkFeed) public chainlinkFeed;
    mapping(address => bytes32) public pythPriceId;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => bool) public settlementEligible;
    mapping(uint256 => bool) public legacySeries;

    event PriceProposed(uint256 indexed optionId, uint256 price1e8, uint80 beforeRound, uint80 afterRound);
    event PriceDisputed(uint256 indexed optionId, uint256 pythPrice1e8);
    event PythFallbackProposed(uint256 indexed optionId, uint256 price1e8, uint80 beforeRound, uint80 afterRound);
    event PriceResolved(uint256 indexed optionId, uint256 price1e8, bool pythSelected);
    event PriceFinalized(uint256 indexed optionId, uint256 price1e8);
    event ControlledSeriesCreated(uint256 indexed optionId, address indexed underlying);
    event LegacyPriceFinalized(uint256 indexed optionId, uint256 price1e8);

    constructor(
        address registry_,
        address timelock_,
        address emergencyGuardian_,
        address settlementAsset_,
        address pyth_,
        address[2] memory underlyings,
        address[2] memory chainlinkFeeds,
        bytes32[2] memory pythIds,
        uint64 maxBeforeAge_,
        uint64 maxAfterLag_,
        uint64 challengePeriod_,
        uint32 maxDivergenceBps_,
        uint32 maxPythConfidenceBps_
    ) {
        if (
            registry_ == address(0) || timelock_ == address(0) || emergencyGuardian_ == address(0)
                || settlementAsset_ == address(0) || pyth_ == address(0) || maxBeforeAge_ == 0 || maxBeforeAge_ > 1_500
                || maxAfterLag_ == 0 || maxAfterLag_ > 1_500 || challengePeriod_ < 2 days || challengePeriod_ > 7 days
                || maxDivergenceBps_ == 0 || maxDivergenceBps_ > 100 || maxPythConfidenceBps_ == 0
                || maxPythConfidenceBps_ > 100
        ) revert InvalidPriceProof();
        registry = OptionProductRegistry(registry_);
        deploymentChainId = block.chainid;
        timelock = timelock_;
        emergencyGuardian = emergencyGuardian_;
        settlementAsset = settlementAsset_;
        pyth = IHistoricalPyth(pyth_);
        maxBeforeAge = maxBeforeAge_;
        maxAfterLag = maxAfterLag_;
        challengePeriod = challengePeriod_;
        maxDivergenceBps = maxDivergenceBps_;
        maxPythConfidenceBps = maxPythConfidenceBps_;
        for (uint256 i; i < 2; i++) {
            if (
                underlyings[i] == address(0) || chainlinkFeeds[i] == address(0) || pythIds[i] == bytes32(0)
                    || (i != 0 && underlyings[i] == underlyings[0])
            ) revert InvalidPriceProof();
            chainlinkFeed[underlyings[i]] = IHistoricalChainlinkFeed(chainlinkFeeds[i]);
            pythPriceId[underlyings[i]] = pythIds[i];
        }
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert NotTimelock();
        _;
    }

    modifier onlyEmergencyGuardian() {
        if (msg.sender != emergencyGuardian) revert NotEmergencyGuardian();
        _;
    }

    modifier sameChain() {
        if (block.chainid != deploymentChainId) revert WrongChain();
        _;
    }

    /// @dev Requires no legacy operator or pending arbitrary proposal. Existing
    ///      finalized prices cannot be undone, so a fresh preflight is needed.
    function acceptRegistryOwnership() external onlyTimelock sameChain {
        if (
            registry.pendingOwner() != address(this) || registry.owner() != timelock
                || registry.settlementOperator() != address(0) || registry.settlementFinalityDelay() != 0
                || !registry.settlementPaused() || !registry.creationPaused()
        ) revert UnsafeRegistryState();
        // Snapshot historical IDs while creation is paused. Only those IDs
        // retain their previous Timelock-governed price-setting path.
        uint256[] memory existing = registry.getAllOptionIds();
        if (existing.length > 32) revert TooManyLegacySeries();
        for (uint256 i; i < existing.length; ++i) {
            (,, bool pending) = registry.getSettlementProposal(existing[i]);
            if (pending) revert UnsafeRegistryState();
            legacySeries[existing[i]] = true;
        }
        registry.acceptOwnership();
        if (registry.owner() != address(this)) revert UnsafeRegistryState();
        // The historical guardian can clear pauses via setEmergencyModes.
        // Make this immutable adapter the Registry guardian, exposing only
        // pause calls to the external emergency guardian.
        registry.setGuardian(address(this));
        if (registry.guardian() != address(this)) revert UnsafeRegistryState();
    }

    function emergencyPauseSettlement() external onlyEmergencyGuardian sameChain {
        registry.pauseSettlement();
    }

    function emergencyPauseAll() external onlyEmergencyGuardian sameChain {
        registry.pause();
    }

    /// @notice Preserve the historical Timelock price power for the exact
    ///         series that existed before ownership transfer. This path is
    ///         deliberately unavailable to every prospective series.
    function finalizeLegacyPrice(uint256 optionId, uint256 price1e8) external onlyTimelock sameChain {
        if (!legacySeries[optionId] || settlementEligible[optionId]) revert LegacySeriesRestricted();
        if (
            registry.owner() != address(this) || registry.settlementOperator() != address(0)
                || registry.settlementFinalityDelay() != 0
        ) revert UnsafeRegistryState();
        registry.setSettlementPrice(optionId, price1e8);
        emit LegacyPriceFinalized(optionId, price1e8);
    }

    /// @notice Create only a prospective, inactive European Call. Existing
    ///         series are deliberately ineligible for this new price policy.
    /// @dev The temporary creator/creation permission and the deactivation
    ///      occur in one transaction. Registry.createSeries makes no external
    ///      calls; any revert rolls back the entire sequence.
    function createInactiveCallSeries(address underlying, uint64 expiry, uint64 strike)
        external
        onlyTimelock
        sameChain
        returns (uint256 optionId)
    {
        if (address(chainlinkFeed[underlying]) == address(0)) revert UnsupportedSeries();
        if (
            registry.owner() != address(this) || !registry.creationPaused() || registry.paused()
                || registry.configPaused()
        ) revert UnsafeRegistryState();
        registry.setSeriesCreator(address(this), true);
        registry.unpauseCreation();
        optionId = registry.createSeries(underlying, settlementAsset, expiry, strike, true, true);
        registry.pauseCreation();
        registry.setSeriesCreator(address(this), false);
        registry.setSeriesActive(optionId, false);
        settlementEligible[optionId] = true;
        emit ControlledSeriesCreated(optionId, underlying);
    }

    function _series(uint256 optionId)
        internal
        view
        returns (OptionProductRegistry.OptionSeries memory series, IHistoricalChainlinkFeed feed)
    {
        series = registry.getSeries(optionId);
        feed = chainlinkFeed[series.underlying];
        if (series.settlementAsset != settlementAsset || address(feed) == address(0)) revert UnsupportedSeries();
        if (!settlementEligible[optionId]) revert LegacySeriesRestricted();
    }

    function _normalize(uint256 raw, uint8 decimals) internal pure returns (uint256) {
        if (raw == 0 || decimals > 18) revert InvalidPriceProof();
        uint256 normalized = decimals >= 8 ? raw / (10 ** (decimals - 8)) : raw * (10 ** (8 - decimals));
        if (normalized == 0) revert InvalidPriceProof();
        return normalized;
    }

    function _chainlinkBoundary(IHistoricalChainlinkFeed feed, uint64 expiry, uint80 beforeId, uint80 afterId)
        internal
        view
        returns (uint256 price, uint256 beforeAt, uint256 afterAt)
    {
        if (beforeId == 0 || afterId != beforeId + 1 || (beforeId >> 64) != (afterId >> 64)) {
            revert InvalidRoundProof(); // phase transitions fail closed
        }
        uint256 beforeTimestamp;
        uint256 afterTimestamp;
        uint80 actualBefore;
        uint80 actualAfter;
        uint80 answeredBefore;
        uint80 answeredAfter;
        int256 answer;
        int256 afterAnswer;
        (actualBefore, answer,, beforeTimestamp, answeredBefore) = feed.getRoundData(beforeId);
        (actualAfter, afterAnswer,, afterTimestamp, answeredAfter) = feed.getRoundData(afterId);
        if (
            actualBefore != beforeId || actualAfter != afterId || answeredBefore != beforeId || answeredAfter != afterId
                || answer <= 0 || afterAnswer <= 0 || beforeTimestamp == 0 || beforeTimestamp > expiry
                || afterTimestamp <= expiry || afterTimestamp > block.timestamp
        ) revert InvalidRoundProof();
        beforeAt = beforeTimestamp;
        afterAt = afterTimestamp;
        price = _normalize(uint256(answer), feed.decimals());
    }

    function propose(uint256 optionId, uint80 beforeId, uint80 afterId) external sameChain {
        if (
            registry.owner() != address(this) || registry.settlementOperator() != address(0)
                || registry.settlementFinalityDelay() != 0
        ) revert UnsafeRegistryState();
        (OptionProductRegistry.OptionSeries memory series, IHistoricalChainlinkFeed feed) = _series(optionId);
        if (block.timestamp < series.expiry || registry.isSettled(optionId)) revert InvalidPriceProof();
        if (proposals[optionId].state != SettlementState.PRICE_UNAVAILABLE) revert ProposalExists();
        (uint256 price, uint256 beforeAt, uint256 afterAt) = _chainlinkBoundary(feed, series.expiry, beforeId, afterId);
        if (series.expiry - beforeAt > maxBeforeAge || afterAt - series.expiry > maxAfterLag) {
            revert InvalidRoundProof();
        }
        proposals[optionId] =
            Proposal(price, 0, 0, beforeId, afterId, uint64(block.timestamp), SettlementState.PRICE_PROPOSED);
        emit PriceProposed(optionId, price, beforeId, afterId);
    }

    /// @notice Pyth is admissible only when the authenticated adjacent
    ///         Chainlink boundary proves that the primary is too stale.
    ///         Missing rounds and phase transitions deliberately fail closed.
    function proposePythFallback(uint256 optionId, uint80 beforeId, uint80 afterId, bytes[] calldata updateData)
        external
        payable
        sameChain
    {
        if (
            registry.owner() != address(this) || registry.settlementOperator() != address(0)
                || registry.settlementFinalityDelay() != 0
        ) revert UnsafeRegistryState();
        (OptionProductRegistry.OptionSeries memory series, IHistoricalChainlinkFeed feed) = _series(optionId);
        if (block.timestamp < series.expiry || registry.isSettled(optionId)) revert InvalidPriceProof();
        if (proposals[optionId].state != SettlementState.PRICE_UNAVAILABLE) revert ProposalExists();
        (, uint256 beforeAt, uint256 afterAt) = _chainlinkBoundary(feed, series.expiry, beforeId, afterId);
        if (series.expiry - beforeAt <= maxBeforeAge && afterAt - series.expiry <= maxAfterLag) {
            revert InvalidRoundProof();
        }
        uint256 fee = pyth.getUpdateFee(updateData);
        if (msg.value != fee) revert InvalidFee();
        uint256 price = _pythPrice(optionId, updateData, fee);
        proposals[optionId] =
            Proposal(0, price, 0, beforeId, afterId, uint64(block.timestamp), SettlementState.PRICE_PROPOSED);
        emit PythFallbackProposed(optionId, price, beforeId, afterId);
    }

    function _pythPrice(uint256 optionId, bytes[] calldata updateData, uint256 fee) internal returns (uint256) {
        (OptionProductRegistry.OptionSeries memory series,) = _series(optionId);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = pythPriceId[series.underlying];
        IHistoricalPyth.PriceFeed[] memory updates =
            pyth.parsePriceFeedUpdatesUnique{value: fee}(updateData, ids, series.expiry, series.expiry + maxAfterLag);
        if (updates.length != 1 || updates[0].id != ids[0]) revert InvalidPriceProof();
        IHistoricalPyth.Price memory value = updates[0].price;
        if (
            value.price <= 0 || value.publishTime < series.expiry || value.publishTime > series.expiry + maxAfterLag
                || value.publishTime > block.timestamp || value.expo < -18 || value.expo > 10
        ) revert InvalidPriceProof();
        int256 exp = int256(value.expo) + 8;
        uint256 multiplier = 10 ** uint256(exp >= 0 ? exp : -exp);
        uint256 price = exp >= 0 ? uint256(uint64(value.price)) * multiplier : uint256(uint64(value.price)) / multiplier;
        if (price == 0 || uint256(value.conf) * 10_000 > uint256(uint64(value.price)) * maxPythConfidenceBps) {
            revert InvalidPriceProof();
        }
        return price;
    }

    /// @notice Material divergence is recorded, but never overrides an
    ///         admissible pre-expiry Chainlink price.
    function challengeWithPyth(uint256 optionId, bytes[] calldata updateData) external payable sameChain {
        Proposal storage proposal = proposals[optionId];
        if (proposal.state == SettlementState.PRICE_UNAVAILABLE) revert NoProposal();
        if (proposal.state != SettlementState.PRICE_PROPOSED) revert InvalidState();
        if (proposal.chainlinkPrice1e8 == 0) revert InvalidState();
        if (block.timestamp >= uint256(proposal.proposedAt) + challengePeriod) revert ChallengeClosed();
        uint256 fee = pyth.getUpdateFee(updateData);
        if (msg.value != fee) revert InvalidFee();
        uint256 alternative = _pythPrice(optionId, updateData, fee);
        uint256 difference = alternative > proposal.chainlinkPrice1e8
            ? alternative - proposal.chainlinkPrice1e8
            : proposal.chainlinkPrice1e8 - alternative;
        if (difference * 10_000 <= proposal.chainlinkPrice1e8 * maxDivergenceBps) revert NoMaterialDisagreement();
        proposal.pythPrice1e8 = alternative;
        proposal.state = SettlementState.CHALLENGED;
        emit PriceDisputed(optionId, alternative);
    }

    /// @notice Resolve once, at a deadline fixed by the first proof. There is
    ///         no reset or administrative price-selection path.
    function resolve(uint256 optionId) external sameChain {
        Proposal storage proposal = proposals[optionId];
        if (proposal.state == SettlementState.PRICE_UNAVAILABLE) revert NoProposal();
        if (block.timestamp < uint256(proposal.proposedAt) + challengePeriod) revert ChallengeOpen();
        if (proposal.state == SettlementState.CHALLENGED) revert UnresolvedDivergence();
        if (proposal.state != SettlementState.PRICE_PROPOSED) revert InvalidState();
        bool pythSelected = proposal.chainlinkPrice1e8 == 0;
        proposal.selectedPrice1e8 = pythSelected ? proposal.pythPrice1e8 : proposal.chainlinkPrice1e8;
        proposal.state = SettlementState.RESOLVED;
        emit PriceResolved(optionId, proposal.selectedPrice1e8, pythSelected);
    }

    function finalize(uint256 optionId) external sameChain {
        Proposal storage proposal = proposals[optionId];
        if (proposal.state != SettlementState.RESOLVED) revert InvalidState();
        if (
            registry.owner() != address(this) || registry.settlementOperator() != address(0)
                || registry.settlementFinalityDelay() != 0
        ) revert UnsafeRegistryState();
        proposal.state = SettlementState.FINALIZED;
        registry.setSettlementPrice(optionId, proposal.selectedPrice1e8);
        emit PriceFinalized(optionId, proposal.selectedPrice1e8);
    }

    /// @dev Narrow governance compatibility: Registry owns configuration,
    ///      but no selector that alters ownership, settlement roles, delay,
    ///      proposal, final price, or execution is forwarded.
    function executeRegistryAdmin(bytes calldata data) external onlyTimelock sameChain returns (bytes memory) {
        if (data.length < 4) revert ForbiddenAdminCall();
        bytes4 selector = bytes4(data[:4]);
        if (
            selector != OptionProductRegistry.setSeriesActive.selector
                && selector != OptionProductRegistry.unpause.selector
                && selector != OptionProductRegistry.unpauseSettlement.selector
                && selector != OptionProductRegistry.unpauseConfig.selector
                && selector != OptionProductRegistry.setSeriesMetadata.selector
        ) revert ForbiddenAdminCall();
        if (selector == OptionProductRegistry.setSeriesActive.selector) {
            (uint256 optionId, bool isActive) = abi.decode(data[4:], (uint256, bool));
            if (isActive && !settlementEligible[optionId]) revert ForbiddenAdminCall();
            registry.getSeries(optionId);
        }
        (bool ok, bytes memory result) = address(registry).call(data);
        if (!ok) assembly { revert(add(result, 32), mload(result)) }
        return result;
    }
}
