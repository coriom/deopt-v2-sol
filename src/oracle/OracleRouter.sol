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
///      * si le feed direct échoue, le router tente aussi le feed reverse si présent/actif
///  - Reverse support:
///      * si feed (base,quote) absent/inactif/indisponible, tente (quote,base) et inverse le prix
///  - Emergency layer:
///      * guardian opérationnel distinct de l’owner
///      * pause globale legacy
///      * pauses granulaires: read / config
///      * getPriceSafe => best-effort, retourne false si lecture pausée
///      * getPrice => revert si lecture pausée
contract OracleRouter is IOracle {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BPS = 10_000;
    uint256 internal constant PRICE_SCALE = 1e8;
    uint32 internal constant MAX_ALLOWED_DELAY = 3600;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    struct FeedConfig {
        IPriceSource primarySource;
        IPriceSource secondarySource; // optionnel
        uint32 maxDelay; // staleness locale (0 = off)
        uint16 maxDeviationBps; // ex: 500 = 5%
        bool isActive;
    }

    enum ReadStatus {
        Ok,
        FeedInactive,
        NoSource,
        Stale,
        Future,
        Deviation
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event GuardianSet(address indexed guardian);

    event Paused(address indexed account);
    event Unpaused(address indexed account);

    event GlobalPauseSet(bool isPaused);
    event ReadPauseSet(bool isPaused);
    event ConfigPauseSet(bool isPaused);
    event EmergencyModeUpdated(bool readPaused, bool configPaused);

    event FeedConfigured(
        address indexed baseAsset,
        address indexed quoteAsset,
        address primarySource,
        address secondarySource,
        uint32 maxDelay,
        uint16 maxDeviationBps,
        bool isActive
    );

    event FeedCleared(address indexed baseAsset, address indexed quoteAsset);
    event FeedStatusSet(address indexed baseAsset, address indexed quoteAsset, bool isActive);

    event MaxOracleDelaySet(uint32 oldDelay, uint32 newDelay);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;

    /// @notice Emergency guardian allowed to trigger operational freezes.
    address public guardian;

    /// @notice Legacy global pause.
    bool public paused;

    /// @notice Granular emergency flags.
    bool public readPaused;
    bool public configPaused;

    /// @notice Garde de fraîcheur globale (0 = off). Défaut: 600s.
    uint32 public maxOracleDelay;

    mapping(bytes32 => FeedConfig) public feeds;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error GuardianNotAuthorized();
    error ZeroAddress();
    error FeedNotActive();
    error NoSource();
    error StalePrice();
    error FutureTimestamp();
    error DeviationTooHigh();
    error DeviationOutOfRange();
    error DelayOutOfRange();
    error SameAssetPair();
    error OraclePaused();
    error ConfigPausedError();

    // ownership 2-step
    error OwnershipTransferNotInitiated();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != owner && msg.sender != guardian) revert GuardianNotAuthorized();
        _;
    }

    modifier whenConfigNotPaused() {
        if (_isConfigPaused()) revert ConfigPausedError();
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

        emit EmergencyModeUpdated(false, false);
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
                                GUARDIAN
    //////////////////////////////////////////////////////////////*/

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        _setGuardian(guardian_);
    }

    function clearGuardian() external onlyOwner {
        _setGuardian(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Legacy global pause.
    function pause() external onlyGuardianOrOwner {
        if (!paused) {
            paused = true;
            emit Paused(msg.sender);
            emit GlobalPauseSet(true);
        }
    }

    /// @notice Clears legacy global pause.
    /// @dev Owner only, so guardian can escalate but not fully normalize alone.
    function unpause() external onlyOwner {
        if (paused) {
            paused = false;
            emit Unpaused(msg.sender);
            emit GlobalPauseSet(false);
        }
    }

    function pauseReads() external onlyGuardianOrOwner {
        if (!readPaused) {
            readPaused = true;
            emit ReadPauseSet(true);
            emit EmergencyModeUpdated(readPaused, configPaused);
        }
    }

    function unpauseReads() external onlyOwner {
        if (readPaused) {
            readPaused = false;
            emit ReadPauseSet(false);
            emit EmergencyModeUpdated(readPaused, configPaused);
        }
    }

    function pauseConfig() external onlyGuardianOrOwner {
        if (!configPaused) {
            configPaused = true;
            emit ConfigPauseSet(true);
            emit EmergencyModeUpdated(readPaused, configPaused);
        }
    }

    function unpauseConfig() external onlyOwner {
        if (configPaused) {
            configPaused = false;
            emit ConfigPauseSet(false);
            emit EmergencyModeUpdated(readPaused, configPaused);
        }
    }

    function setEmergencyModes(bool readPaused_, bool configPaused_) external onlyGuardianOrOwner {
        _setEmergencyModes(readPaused_, configPaused_);
    }

    function clearEmergencyModes() external onlyOwner {
        _setEmergencyModes(false, false);
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
    ) external onlyOwner whenConfigNotPaused {
        if (baseAsset == address(0) || quoteAsset == address(0)) revert ZeroAddress();
        if (baseAsset == quoteAsset) revert SameAssetPair();
        if (maxDelay > MAX_ALLOWED_DELAY) revert DelayOutOfRange();
        if (maxDeviationBps > uint16(BPS)) revert DeviationOutOfRange();

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

    function setFeedStatus(address baseAsset, address quoteAsset, bool isActive)
        external
        onlyOwner
        whenConfigNotPaused
    {
        if (baseAsset == address(0) || quoteAsset == address(0)) revert ZeroAddress();
        if (baseAsset == quoteAsset) revert SameAssetPair();

        bytes32 key = _pairKey(baseAsset, quoteAsset);
        FeedConfig storage cfg = feeds[key];

        if (isActive) {
            if (address(cfg.primarySource) == address(0) && address(cfg.secondarySource) == address(0)) {
                revert NoSource();
            }
        }

        cfg.isActive = isActive;
        emit FeedStatusSet(baseAsset, quoteAsset, isActive);
    }

    function clearFeed(address baseAsset, address quoteAsset) external onlyOwner whenConfigNotPaused {
        if (baseAsset == address(0) || quoteAsset == address(0)) revert ZeroAddress();
        if (baseAsset == quoteAsset) revert SameAssetPair();

        bytes32 key = _pairKey(baseAsset, quoteAsset);
        delete feeds[key];

        emit FeedCleared(baseAsset, quoteAsset);
    }

    function setMaxOracleDelay(uint32 _delay) external onlyOwner whenConfigNotPaused {
        if (_delay > MAX_ALLOWED_DELAY) revert DelayOutOfRange();
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

    /// @notice Best-effort helper: renvoie (0,0,false) si aucun prix utilisable.
    /// @dev Retourne aussi false si les lectures oracle sont pausées.
    function getPriceSafe(address baseAsset, address quoteAsset)
        external
        view
        returns (uint256 price, uint256 updatedAt, bool ok)
    {
        if (_isReadPaused()) return (0, 0, false);
        if (baseAsset == address(0) || quoteAsset == address(0)) return (0, 0, false);

        if (baseAsset == quoteAsset) return (PRICE_SCALE, block.timestamp, true);

        (bool okDir, uint256 pDir, uint256 tDir,) = _tryDirect(baseAsset, quoteAsset);
        if (okDir) return (pDir, tDir, true);

        (bool okRev, uint256 pRev, uint256 tRev,) = _tryReverse(baseAsset, quoteAsset);
        if (okRev) return (pRev, tRev, true);

        return (0, 0, false);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL EMERGENCY HELPERS
    //////////////////////////////////////////////////////////////*/

    function _isReadPaused() internal view returns (bool) {
        return paused || readPaused;
    }

    function _isConfigPaused() internal view returns (bool) {
        return paused || configPaused;
    }

    function _setGuardian(address guardian_) internal {
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    function _setEmergencyModes(bool readPaused_, bool configPaused_) internal {
        if (readPaused != readPaused_) {
            readPaused = readPaused_;
            emit ReadPauseSet(readPaused_);
        }

        if (configPaused != configPaused_) {
            configPaused = configPaused_;
            emit ConfigPauseSet(configPaused_);
        }

        emit EmergencyModeUpdated(readPaused_, configPaused_);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _effectiveDelay(uint32 feedMaxDelay) internal view returns (uint32 d) {
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

    function _readConfiguredFeed(FeedConfig memory cfg)
        internal
        view
        returns (bool ok, uint256 price, uint256 updatedAt, ReadStatus status)
    {
        if (!cfg.isActive) {
            return (false, 0, 0, ReadStatus.FeedInactive);
        }

        (uint256 p1, uint256 t1, bool ok1Raw) = _readSource(cfg.primarySource);
        (uint256 p2, uint256 t2, bool ok2Raw) = _readSource(cfg.secondarySource);

        if (!ok1Raw && !ok2Raw) {
            return (false, 0, 0, ReadStatus.NoSource);
        }

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
            if (sawFuture) return (false, 0, 0, ReadStatus.Future);
            return (false, 0, 0, ReadStatus.Stale);
        }

        if (ok1 && !ok2) return (true, p1, t1, ReadStatus.Ok);
        if (!ok1 && ok2) return (true, p2, t2, ReadStatus.Ok);

        uint16 maxDev = cfg.maxDeviationBps;

        if (maxDev == 0) {
            if (p1 != p2) return (false, 0, 0, ReadStatus.Deviation);
            return (true, p1, t1, ReadStatus.Ok);
        }

        uint256 dev = _deviationBps(p1, p2);
        if (dev > uint256(maxDev)) return (false, 0, 0, ReadStatus.Deviation);

        return (true, p1, t1, ReadStatus.Ok);
    }

    function _invertPrice(uint256 price1e8) internal pure returns (uint256 inv1e8) {
        if (price1e8 == 0) revert NoSource();
        inv1e8 = Math.mulDiv(PRICE_SCALE, PRICE_SCALE, price1e8, Math.Rounding.Down);
    }

    function _tryDirect(address baseAsset, address quoteAsset)
        internal
        view
        returns (bool ok, uint256 price, uint256 updatedAt, ReadStatus status)
    {
        bytes32 key = _pairKey(baseAsset, quoteAsset);
        FeedConfig memory cfg = feeds[key];
        return _readConfiguredFeed(cfg);
    }

    function _tryReverse(address baseAsset, address quoteAsset)
        internal
        view
        returns (bool ok, uint256 price, uint256 updatedAt, ReadStatus status)
    {
        bytes32 rkey = _pairKey(quoteAsset, baseAsset);
        FeedConfig memory rcfg = feeds[rkey];

        (bool okRev, uint256 revPrice, uint256 revUpdatedAt, ReadStatus st) = _readConfiguredFeed(rcfg);
        if (!okRev) return (false, 0, 0, st);

        return (true, _invertPrice(revPrice), revUpdatedAt, ReadStatus.Ok);
    }

    function _revertForStatuses(
        bool directConfigured,
        bool reverseConfigured,
        ReadStatus directStatus,
        ReadStatus reverseStatus
    ) internal pure {
        if (!directConfigured && !reverseConfigured) revert FeedNotActive();

        if (directStatus == ReadStatus.Future || reverseStatus == ReadStatus.Future) revert FutureTimestamp();
        if (directStatus == ReadStatus.Deviation || reverseStatus == ReadStatus.Deviation) revert DeviationTooHigh();
        if (directStatus == ReadStatus.Stale || reverseStatus == ReadStatus.Stale) revert StalePrice();
        if (directStatus == ReadStatus.NoSource || reverseStatus == ReadStatus.NoSource) revert NoSource();

        revert FeedNotActive();
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
        if (_isReadPaused()) revert OraclePaused();
        if (baseAsset == address(0) || quoteAsset == address(0)) revert ZeroAddress();

        if (baseAsset == quoteAsset) {
            return (PRICE_SCALE, block.timestamp);
        }

        bytes32 key = _pairKey(baseAsset, quoteAsset);
        bytes32 rkey = _pairKey(quoteAsset, baseAsset);

        FeedConfig memory cfg = feeds[key];
        FeedConfig memory rcfg = feeds[rkey];

        bool directConfigured =
            cfg.isActive && (address(cfg.primarySource) != address(0) || address(cfg.secondarySource) != address(0));

        bool reverseConfigured =
            rcfg.isActive && (address(rcfg.primarySource) != address(0) || address(rcfg.secondarySource) != address(0));

        (bool okDir, uint256 pDir, uint256 tDir, ReadStatus stDir) = _readConfiguredFeed(cfg);
        if (okDir) return (pDir, tDir);

        (bool okRev, uint256 pRev, uint256 tRev, ReadStatus stRev) = _tryReverse(baseAsset, quoteAsset);
        if (okRev) return (pRev, tRev);

        _revertForStatuses(directConfigured, reverseConfigured, stDir, stRev);
        revert FeedNotActive();
    }
}