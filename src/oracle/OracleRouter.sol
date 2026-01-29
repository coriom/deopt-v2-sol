// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./IOracle.sol";
import "./IPriceSource.sol";

/// @title OracleRouter
/// @notice Oracle central: route vers différentes sources + règles de sécurité.
/// @dev
///  - Tous les prix sont en 1e8.
///  - Staleness: combine `maxOracleDelay` global (0=off) et `maxDelay` par feed (0=off) via min(non-zero).
///  - Deviation: si secondaire configurée et lisible:
///      * maxDeviationBps == 0 => égalité stricte
///      * sinon |p1-p2| / min(p1,p2) <= maxDeviationBps
///  - Hardening:
///      * refuse updatedAt == 0
///      * refuse updatedAt dans le futur (même si staleness off)
///      * fallback si primary fail vers secondary (si configured)
contract OracleRouter is IOracle {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    struct FeedConfig {
        IPriceSource primarySource;
        IPriceSource secondarySource; // optionnel
        uint32 maxDelay;              // staleness locale (0 = off)
        uint16 maxDeviationBps;       // ex: 500 = 5%
        bool isActive;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event FeedConfigured(
        address indexed baseAsset,
        address indexed quoteAsset,
        address primarySource,
        address secondarySource,
        uint32 maxDelay,
        uint16 maxDeviationBps,
        bool isActive
    );

    event MaxOracleDelaySet(uint32 oldDelay, uint32 newDelay);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;

    /// @notice Garde de fraîcheur globale (0 = off). Défaut: 600s.
    uint32 public maxOracleDelay;

    mapping(bytes32 => FeedConfig) public feeds;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error FeedNotActive();
    error NoSource();
    error StalePrice();
    error FutureTimestamp();
    error DeviationTooHigh();
    error ZeroAddress();
    error DeviationOutOfRange();
    error DelayOutOfRange();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);

        uint32 defaultDelay = 600;
        maxOracleDelay = defaultDelay;
        emit MaxOracleDelaySet(0, defaultDelay);
    }

    /*//////////////////////////////////////////////////////////////
                            OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN CONFIG
    //////////////////////////////////////////////////////////////*/

    function _pairKey(address baseAsset, address quoteAsset) internal pure returns (bytes32) {
        return keccak256(abi.encode(baseAsset, quoteAsset));
    }

    function setFeed(
        address baseAsset,
        address quoteAsset,
        IPriceSource primarySource,
        IPriceSource secondarySource,
        uint32 maxDelay,
        uint16 maxDeviationBps,
        bool isActive
    ) external onlyOwner {
        if (baseAsset == address(0) || quoteAsset == address(0)) revert ZeroAddress();

        if (address(primarySource) == address(0) && address(secondarySource) == address(0)) {
            revert NoSource();
        }

        if (maxDelay > 3600) revert DelayOutOfRange();
        if (maxDeviationBps > uint16(BPS)) revert DeviationOutOfRange();

        bytes32 key = _pairKey(baseAsset, quoteAsset);
        feeds[key] = FeedConfig({
            primarySource: primarySource,
            secondarySource: secondarySource,
            maxDelay: maxDelay,
            maxDeviationBps: maxDeviationBps,
            isActive: isActive
        });

        emit FeedConfigured(
            baseAsset,
            quoteAsset,
            address(primarySource),
            address(secondarySource),
            maxDelay,
            maxDeviationBps,
            isActive
        );
    }

    function setMaxOracleDelay(uint32 _delay) external onlyOwner {
        if (_delay > 3600) revert DelayOutOfRange();
        uint32 old = maxOracleDelay;
        maxOracleDelay = _delay;
        emit MaxOracleDelaySet(old, _delay);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function getFeed(address baseAsset, address quoteAsset)
        external
        view
        returns (FeedConfig memory cfg)
    {
        bytes32 key = _pairKey(baseAsset, quoteAsset);
        return feeds[key];
    }

    function hasActiveFeed(address baseAsset, address quoteAsset) external view returns (bool) {
        bytes32 key = _pairKey(baseAsset, quoteAsset);
        FeedConfig memory cfg = feeds[key];
        return
            cfg.isActive &&
            (address(cfg.primarySource) != address(0) || address(cfg.secondarySource) != address(0));
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _effectiveDelay(uint32 feedMaxDelay) internal view returns (uint32 d) {
        // min non-nul entre feedMaxDelay et maxOracleDelay
        uint32 g = maxOracleDelay;

        if (feedMaxDelay != 0 && g != 0) return feedMaxDelay < g ? feedMaxDelay : g;
        if (feedMaxDelay != 0) return feedMaxDelay;
        if (g != 0) return g;
        return 0;
    }

    function _checkTimestampAndStaleness(uint256 updatedAt, uint32 feedMaxDelay) internal view {
        // Toujours exiger un timestamp non nul.
        if (updatedAt == 0) revert StalePrice();

        // Toujours refuser les timestamps futurs (même si delay off).
        if (updatedAt > block.timestamp) revert FutureTimestamp();

        uint32 d = _effectiveDelay(feedMaxDelay);
        if (d == 0) return;

        if (block.timestamp - updatedAt > d) revert StalePrice();
    }

    function _readSource(IPriceSource src) internal view returns (uint256 p, uint256 t, bool ok) {
        if (address(src) == address(0)) return (0, 0, false);

        try src.getLatestPrice() returns (uint256 price, uint256 updatedAt) {
            if (price == 0) return (0, 0, false);
            return (price, updatedAt, true);
        } catch {
            return (0, 0, false);
        }
    }

    function _deviationBps(uint256 p1, uint256 p2) internal pure returns (uint256 bps_) {
        uint256 minP = p1 < p2 ? p1 : p2;
        if (minP == 0) return type(uint256).max;
        uint256 diff = p1 > p2 ? (p1 - p2) : (p2 - p1);
        return Math.mulDiv(diff, BPS, minP);
    }

    /*//////////////////////////////////////////////////////////////
                            ORACLE LOGIC
    //////////////////////////////////////////////////////////////*/

    function getPrice(address baseAsset, address quoteAsset)
        external
        view
        override
        returns (uint256 price, uint256 updatedAt)
    {
        bytes32 key = _pairKey(baseAsset, quoteAsset);
        FeedConfig memory cfg = feeds[key];

        if (!cfg.isActive) revert FeedNotActive();

        (uint256 p1, uint256 t1, bool ok1) = _readSource(cfg.primarySource);
        (uint256 p2, uint256 t2, bool ok2) = _readSource(cfg.secondarySource);

        if (!ok1 && !ok2) revert NoSource();

        // Single-source fallback
        if (ok1 && !ok2) {
            _checkTimestampAndStaleness(t1, cfg.maxDelay);
            return (p1, t1);
        }
        if (!ok1 && ok2) {
            _checkTimestampAndStaleness(t2, cfg.maxDelay);
            return (p2, t2);
        }

        // Both ok => enforce timestamp + staleness + deviation check
        _checkTimestampAndStaleness(t1, cfg.maxDelay);
        _checkTimestampAndStaleness(t2, cfg.maxDelay);

        uint16 maxDev = cfg.maxDeviationBps;

        // maxDev == 0 => strict equality if secondary exists and is readable
        if (maxDev == 0) {
            if (p1 != p2) revert DeviationTooHigh();
            // updatedAt = plus frais (info downstream)
            return (p1, t1 >= t2 ? t1 : t2);
        }

        uint256 dev = _deviationBps(p1, p2);
        if (dev > uint256(maxDev)) revert DeviationTooHigh();

        // Return primary price, fresher updatedAt
        return (p1, t1 >= t2 ? t1 : t2);
    }
}
