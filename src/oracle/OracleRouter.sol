// src/oracle/OracleRouter.sol
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
///  - Deviation: si secondaire configurée et "usable":
///      * maxDeviationBps == 0 => égalité stricte
///      * sinon |p1-p2| / min(p1,p2) <= maxDeviationBps
///  - Hardening:
///      * refuse updatedAt == 0
///      * refuse updatedAt dans le futur
///      * si une source est invalide (stale/future), on l’ignore et on fallback sur l’autre (si possible)
///  - Reverse support:
///      * si feed (base,quote) absent/inactif, tente (quote,base) et inverse le prix
contract OracleRouter is IOracle {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BPS = 10_000;
    uint256 internal constant PRICE_SCALE = 1e8;

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
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

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
    address public pendingOwner;

    /// @notice Garde de fraîcheur globale (0 = off). Défaut: 600s.
    uint32 public maxOracleDelay;

    mapping(bytes32 => FeedConfig) public feeds;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error ZeroAddress();
    error FeedNotActive();
    error NoSource();
    error StalePrice();
    error FutureTimestamp();
    error DeviationTooHigh();
    error DeviationOutOfRange();
    error DelayOutOfRange();

    // ownership 2-step
    error OwnershipTransferNotInitiated();

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
                            OWNERSHIP (2-step)
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        address po = pendingOwner;
        if (msg.sender != po) revert NotAuthorized();
        address old = owner;
        owner = po;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, po);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        if (pendingOwner == address(0)) revert OwnershipTransferNotInitiated();
        pendingOwner = address(0);
    }

    function renounceOwnership() external onlyOwner {
        if (pendingOwner != address(0)) revert NotAuthorized();
        address old = owner;
        owner = address(0);
        emit OwnershipTransferred(old, address(0));
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

        if (maxDelay > 3600) revert DelayOutOfRange();
        if (maxDeviationBps > uint16(BPS)) revert DeviationOutOfRange();

        // si on active, il faut au moins une source
        if (isActive) {
            if (address(primarySource) == address(0) && address(secondarySource) == address(0)) {
                revert NoSource();
            }
        }

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

    function getFeed(address baseAsset, address quoteAsset) external view returns (FeedConfig memory cfg) {
        bytes32 key = _pairKey(baseAsset, quoteAsset);
        return feeds[key];
    }

    function hasActiveFeed(address baseAsset, address quoteAsset) external view returns (bool) {
        bytes32 key = _pairKey(baseAsset, quoteAsset);
        FeedConfig memory cfg = feeds[key];
        return cfg.isActive && (address(cfg.primarySource) != address(0) || address(cfg.secondarySource) != address(0));
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

    function _isTimestampUsable(uint256 updatedAt, uint32 feedMaxDelay) internal view returns (bool ok, bool isFuture) {
        if (updatedAt == 0) return (false, false);
        if (updatedAt > block.timestamp) return (false, true);

        uint32 d = _effectiveDelay(feedMaxDelay);
        if (d == 0) return (true, false);

        if (block.timestamp - updatedAt > d) return (false, false);

        return (true, false);
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
        return Math.mulDiv(diff, BPS, minP, Math.Rounding.Down);
    }

    function _getPriceFromConfig(FeedConfig memory cfg) internal view returns (uint256 price, uint256 updatedAt) {
        (uint256 p1, uint256 t1, bool ok1Raw) = _readSource(cfg.primarySource);
        (uint256 p2, uint256 t2, bool ok2Raw) = _readSource(cfg.secondarySource);

        if (!ok1Raw && !ok2Raw) revert NoSource();

        bool sawFuture;
        bool ok1;
        bool ok2;

        if (ok1Raw) {
            (bool tsOk, bool fut) = _isTimestampUsable(t1, cfg.maxDelay);
            if (fut) sawFuture = true;
            ok1 = tsOk;
        }

        if (ok2Raw) {
            (bool tsOk, bool fut) = _isTimestampUsable(t2, cfg.maxDelay);
            if (fut) sawFuture = true;
            ok2 = tsOk;
        }

        if (!ok1 && !ok2) {
            if (sawFuture) revert FutureTimestamp();
            revert StalePrice();
        }

        // fallback single usable
        if (ok1 && !ok2) return (p1, t1);
        if (!ok1 && ok2) return (p2, t2);

        // both usable => deviation check
        uint16 maxDev = cfg.maxDeviationBps;

        if (maxDev == 0) {
            if (p1 != p2) revert DeviationTooHigh();
            // primary choisi => timestamp doit correspondre au prix retourné (t1)
            return (p1, t1);
        }

        uint256 dev = _deviationBps(p1, p2);
        if (dev > uint256(maxDev)) revert DeviationTooHigh();

        // primary choisi => timestamp doit correspondre au prix retourné (t1)
        return (p1, t1);
    }

    function _invertPrice(uint256 price1e8) internal pure returns (uint256 inv1e8) {
        // inv = (1e8*1e8)/price
        if (price1e8 == 0) revert NoSource();
        inv1e8 = Math.mulDiv(PRICE_SCALE, PRICE_SCALE, price1e8, Math.Rounding.Down);
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
        if (baseAsset == address(0) || quoteAsset == address(0)) revert ZeroAddress();

        // identité
        if (baseAsset == quoteAsset) {
            return (PRICE_SCALE, block.timestamp);
        }

        // try direct
        bytes32 key = _pairKey(baseAsset, quoteAsset);
        FeedConfig memory cfg = feeds[key];

        if (cfg.isActive) {
            return _getPriceFromConfig(cfg);
        }

        // try reverse
        bytes32 rkey = _pairKey(quoteAsset, baseAsset);
        FeedConfig memory rcfg = feeds[rkey];

        if (!rcfg.isActive) revert FeedNotActive();

        (uint256 revPrice, uint256 revUpdatedAt) = _getPriceFromConfig(rcfg);

        return (_invertPrice(revPrice), revUpdatedAt);
    }
}
