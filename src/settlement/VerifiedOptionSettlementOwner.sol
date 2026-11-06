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

/// @notice Prototype owner of the legacy Registry. No general-purpose call or
///         ownership escape is exposed: once accepted, only a bounded oracle
///         proof can cause this contract to call setSettlementPrice.
/// @dev Its policy parameters are immutable and require separate approval.
contract VerifiedOptionSettlementOwner {
    error NotTimelock();
    error NotEmergencyGuardian();
    error UnsafeRegistryState();
    error UnsupportedSeries();
    error InvalidRoundProof();
    error InvalidPriceProof();
    error ProposalExists();
    error NoProposal();
    error ChallengeClosed();
    error NoMaterialDisagreement();
    error Disputed();
    error ChallengeOpen();
    error ForbiddenAdminCall();
    error InvalidFee();

    struct Proposal {
        uint256 price1e8;
        uint80 beforeRound;
        uint80 afterRound;
        uint64 proposedAt;
        bool disputed;
    }

    OptionProductRegistry public immutable registry;
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

    event PriceProposed(uint256 indexed optionId, uint256 price1e8, uint80 beforeRound, uint80 afterRound);
    event PriceDisputed(uint256 indexed optionId, uint256 pythPrice1e8);
    event PriceFinalized(uint256 indexed optionId, uint256 price1e8);
    event PriceProposalCancelled(uint256 indexed optionId);

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

    /// @dev Requires no legacy operator or pending arbitrary proposal. Existing
    ///      finalized prices cannot be undone, so a fresh preflight is needed.
    function acceptRegistryOwnership() external onlyTimelock {
        if (
            registry.pendingOwner() != address(this) || registry.owner() != timelock
                || registry.settlementOperator() != address(0) || registry.settlementFinalityDelay() != 0
                || !registry.settlementPaused() || !registry.creationPaused()
        ) revert UnsafeRegistryState();
        uint256[] memory series = registry.getAllOptionIds();
        for (uint256 i; i < series.length; i++) {
            (,, bool pending) = registry.getSettlementProposal(series[i]);
            if (pending || registry.isSettled(series[i])) revert UnsafeRegistryState();
        }
        registry.acceptOwnership();
        if (registry.owner() != address(this)) revert UnsafeRegistryState();
        // The historical guardian can clear pauses via setEmergencyModes.
        // Make this immutable adapter the Registry guardian, exposing only
        // pause calls to the external emergency guardian.
        registry.setGuardian(address(this));
        if (registry.guardian() != address(this)) revert UnsafeRegistryState();
    }

    function emergencyPauseSettlement() external onlyEmergencyGuardian {
        registry.pauseSettlement();
    }

    function emergencyPauseAll() external onlyEmergencyGuardian {
        registry.pause();
    }

    function _series(uint256 optionId)
        internal
        view
        returns (OptionProductRegistry.OptionSeries memory series, IHistoricalChainlinkFeed feed)
    {
        series = registry.getSeries(optionId);
        feed = chainlinkFeed[series.underlying];
        if (series.settlementAsset != settlementAsset || address(feed) == address(0)) revert UnsupportedSeries();
    }

    function _normalize(uint256 raw, uint8 decimals) internal pure returns (uint256) {
        if (raw == 0 || decimals > 18) revert InvalidPriceProof();
        uint256 normalized = decimals >= 8 ? raw / (10 ** (decimals - 8)) : raw * (10 ** (8 - decimals));
        if (normalized == 0) revert InvalidPriceProof();
        return normalized;
    }

    function _historicalPrice(IHistoricalChainlinkFeed feed, uint64 expiry, uint80 beforeId, uint80 afterId)
        internal
        view
        returns (uint256)
    {
        if (beforeId == 0 || afterId != beforeId + 1 || (beforeId >> 64) != (afterId >> 64)) {
            revert InvalidRoundProof(); // phase transitions fail closed
        }
        (uint80 actualBefore, int256 answer,, uint256 beforeAt, uint80 answeredBefore) = feed.getRoundData(beforeId);
        (uint80 actualAfter, int256 afterAnswer,, uint256 afterAt, uint80 answeredAfter) = feed.getRoundData(afterId);
        if (
            actualBefore != beforeId || actualAfter != afterId || answeredBefore < beforeId || answeredAfter < afterId
                || answer <= 0 || afterAnswer <= 0 || beforeAt == 0 || beforeAt > expiry || afterAt <= expiry
                || afterAt > block.timestamp || expiry - beforeAt > maxBeforeAge || afterAt - expiry > maxAfterLag
        ) revert InvalidRoundProof();
        return _normalize(uint256(answer), feed.decimals());
    }

    function propose(uint256 optionId, uint80 beforeId, uint80 afterId) external {
        if (
            registry.owner() != address(this) || registry.settlementOperator() != address(0)
                || registry.settlementFinalityDelay() != 0
        ) revert UnsafeRegistryState();
        (OptionProductRegistry.OptionSeries memory series, IHistoricalChainlinkFeed feed) = _series(optionId);
        if (block.timestamp < series.expiry || registry.isSettled(optionId)) revert InvalidPriceProof();
        if (proposals[optionId].proposedAt != 0) revert ProposalExists();
        uint256 price = _historicalPrice(feed, series.expiry, beforeId, afterId);
        proposals[optionId] = Proposal(price, beforeId, afterId, uint64(block.timestamp), false);
        emit PriceProposed(optionId, price, beforeId, afterId);
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
                || value.expo < -18 || value.expo > 10
        ) revert InvalidPriceProof();
        int256 exp = int256(value.expo) + 8;
        uint256 multiplier = 10 ** uint256(exp >= 0 ? exp : -exp);
        uint256 price = exp >= 0 ? uint256(uint64(value.price)) * multiplier : uint256(uint64(value.price)) / multiplier;
        if (price == 0 || uint256(value.conf) * 10_000 > uint256(uint64(value.price)) * maxPythConfidenceBps) {
            revert InvalidPriceProof();
        }
        return price;
    }

    /// @notice Anyone can submit a signed, unique Pyth historical update. A
    ///         material divergence freezes this series; it never selects a
    ///         new settlement price or grants an administrator that power.
    function challengeWithPyth(uint256 optionId, bytes[] calldata updateData) external payable {
        Proposal storage proposal = proposals[optionId];
        if (proposal.proposedAt == 0) revert NoProposal();
        if (block.timestamp >= uint256(proposal.proposedAt) + challengePeriod) revert ChallengeClosed();
        if (proposal.disputed) revert Disputed();
        uint256 fee = pyth.getUpdateFee(updateData);
        if (msg.value != fee) revert InvalidFee();
        uint256 alternative = _pythPrice(optionId, updateData, fee);
        uint256 difference =
            alternative > proposal.price1e8 ? alternative - proposal.price1e8 : proposal.price1e8 - alternative;
        if (difference * 10_000 <= proposal.price1e8 * maxDivergenceBps) revert NoMaterialDisagreement();
        proposal.disputed = true;
        emit PriceDisputed(optionId, alternative);
    }

    function cancelProposal(uint256 optionId) external onlyTimelock {
        if (proposals[optionId].proposedAt == 0) revert NoProposal();
        if (proposals[optionId].disputed) revert Disputed();
        delete proposals[optionId];
        emit PriceProposalCancelled(optionId);
    }

    function finalize(uint256 optionId) external {
        Proposal memory proposal = proposals[optionId];
        if (proposal.proposedAt == 0) revert NoProposal();
        if (proposal.disputed) revert Disputed();
        if (block.timestamp < uint256(proposal.proposedAt) + challengePeriod) revert ChallengeOpen();
        if (
            registry.owner() != address(this) || registry.settlementOperator() != address(0)
                || registry.settlementFinalityDelay() != 0
        ) revert UnsafeRegistryState();
        delete proposals[optionId];
        registry.setSettlementPrice(optionId, proposal.price1e8);
        emit PriceFinalized(optionId, proposal.price1e8);
    }

    /// @dev Narrow governance compatibility: Registry owns configuration,
    ///      but no selector that alters ownership, settlement roles, delay,
    ///      proposal, final price, or execution is forwarded.
    function executeRegistryAdmin(bytes calldata data) external onlyTimelock returns (bytes memory) {
        if (data.length < 4) revert ForbiddenAdminCall();
        bytes4 selector = bytes4(data[:4]);
        if (
            selector != OptionProductRegistry.setSeriesActive.selector
                && selector != OptionProductRegistry.unpause.selector
                && selector != OptionProductRegistry.unpauseSettlement.selector
                && selector != OptionProductRegistry.unpauseConfig.selector
                && selector != OptionProductRegistry.setOptionRiskConfig.selector
                && selector != OptionProductRegistry.setSeriesMetadata.selector
        ) revert ForbiddenAdminCall();
        if (selector == OptionProductRegistry.setSeriesActive.selector) {
            (uint256 optionId,) = abi.decode(data[4:], (uint256, bool));
            _series(optionId);
        }
        (bool ok, bytes memory result) = address(registry).call(data);
        if (!ok) assembly { revert(add(result, 32), mload(result)) }
        return result;
    }
}
