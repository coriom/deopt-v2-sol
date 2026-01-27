// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title OptionProductRegistry
/// @notice Registre central des séries d'options de DeOpt v2
/// @dev Ne gère pas les positions ni la marge, seulement la définition des instruments
///      + le prix de settlement officiel à l'expiration.
///      Conventions d'unités (verrouillées ici):
///        - strike et settlementPrice sont en PRICE_SCALE (= 1e8)
///        - contractSize1e8 = quantité d'underlying par contrat, en 1e8
///          (1 contrat = 1 underlying => contractSize1e8 = 1e8)
contract OptionProductRegistry {
    /*//////////////////////////////////////////////////////////////
                                UNITS
    //////////////////////////////////////////////////////////////*/

    /// @notice Convention de prix: 1e8 (type Chainlink 8 decimals)
    uint256 public constant PRICE_SCALE = 1e8;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Représente une série d'options (un instrument unique)
    /// @dev
    ///   - `strike` et `settlementPrice` sont en PRICE_SCALE (1e8).
    ///   - `contractSize1e8` : taille d'un contrat en "unités d'underlying" normalisées 1e8.
    ///        Ex: 1 contrat = 1 underlying => 1e8 ; 0.1 => 1e7.
    struct OptionSeries {
        address underlying;       // Sous-jacent (ex: WETH)
        address settlementAsset;  // Asset de règlement (ex: USDC)
        uint64 expiry;            // Timestamp d'expiration
        uint64 strike;            // Strike * 1e8 (PRICE_SCALE)
        uint128 contractSize1e8;  // Taille contrat (underlying) * 1e8
        bool isCall;              // true = Call, false = Put
        bool isEuropean;          // true = Européenne (pour usage futur / front)
        bool exists;              // Flag pour savoir si la série est enregistrée
        bool isActive;            // true = tradable, false = close-only / désactivée
    }

    /// @notice Configuration de risque / oracle par sous-jacent
    /// @dev
    ///   - Les champs *Shock* sont en basis points (bps).
    struct UnderlyingConfig {
        address oracle;           // Oracle de prix pour ce sous-jacent (optionnel côté RiskModule)
        uint64 spotShockDownBps;  // choc spot down, ex: 2500 = -25%
        uint64 spotShockUpBps;    // choc spot up, ex: 2500 = +25%
        uint64 volShockDownBps;   // choc vol down (actuellement inutilisé par le RiskModule)
        uint64 volShockUpBps;     // choc vol up, ex: 1500 = 15% du ref
        bool isEnabled;           // sous-jacent utilisable ou non
    }

    /// @notice Proposition de prix de settlement (phase 1), finalisation (phase 2).
    struct SettlementProposal {
        uint256 price;      // prix proposé en 1e8
        uint64 proposedAt;  // timestamp de proposition
        bool exists;        // proposal set
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error UnderlyingZero();
    error SettlementZero();
    error ExpiryInPast();
    error ExpiryTooSoon();              // expiry > now mais < now + minExpiryDelay
    error StrikeZero();
    error ContractSizeZero();
    error SeriesAlreadyExists();
    error UnknownSeries();
    error NotAuthorized();
    error SettlementPriceZero();
    error SettlementAlreadySet();
    error NotExpiredYet();
    error InvalidUnderlyingConfig();    // nouveaux paramètres de sous-jacent hors bornes
    error UnderlyingNotEnabled();       // underlying non activé dans underlyingConfigs
    error SettlementAssetNotAllowed();  // settlementAsset non autorisé

    // settlement hardening
    error SettlementProposalAlreadyExists();
    error NoSettlementProposal();
    error SettlementFinalityDelayNotElapsed();
    error InvalidDelay();
    error OwnershipTransferNotInitiated();

    /*//////////////////////////////////////////////////////////////
                              DEFENSIVE LIMITS
    //////////////////////////////////////////////////////////////*/

    uint64 public constant MAX_SPOT_SHOCK_BPS = 10_000; // 100%
    uint64 public constant MAX_VOL_SHOCK_BPS  = 5_000;  // 50%

    // ============ Hardening: bornes contractSize / strike (anti overflow & dust) ============
    // contractSize1e8 est multiplié par des prix (1e8) puis re-mis à l'échelle.
    // On borne à quelque chose de très large mais fini pour éviter des tailles absurdes.
    uint128 public constant MAX_CONTRACT_SIZE_1E8 = 1_000_000 * uint128(PRICE_SCALE); // 1e6 underlying / contrat
    uint64 public constant MAX_STRIKE_1E8 = type(uint64).max; // déjà borné par uint64

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event SeriesCreated(
        uint256 indexed optionId,
        address indexed underlying,
        address indexed settlementAsset,
        uint64 expiry,
        uint64 strike,
        uint128 contractSize1e8,
        bool isCall,
        bool isEuropean
    );

    event SeriesCreatorSet(address indexed account, bool isAllowed);

    event SeriesStatusUpdated(uint256 indexed optionId, bool isActive);

    event UnderlyingConfigSet(
        address indexed underlying,
        address oracle,
        uint64 spotShockDownBps,
        uint64 spotShockUpBps,
        uint64 volShockDownBps,
        uint64 volShockUpBps,
        bool isEnabled
    );

    event SettlementOperatorSet(address indexed account);

    event SettlementPriceProposed(uint256 indexed optionId, uint256 proposedPrice, uint256 proposedAt);
    event SettlementPriceFinalized(uint256 indexed optionId, uint256 settlementPrice, uint256 finalizedAt);

    event SettlementAssetConfigured(address indexed asset, bool isAllowed);

    event MinExpiryDelaySet(uint256 oldDelay, uint256 newDelay);
    event SettlementFinalityDelaySet(uint256 oldDelay, uint256 newDelay);

    event SeriesMetadataSet(uint256 indexed optionId, bytes32 metadata);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(uint256 => OptionSeries) private _series;
    uint256[] private _allOptionIds;

    address public owner;
    address public pendingOwner;

    mapping(address => bool) public isSeriesCreator;
    mapping(address => UnderlyingConfig) public underlyingConfigs;

    address public settlementOperator;

    mapping(uint256 => uint256) private _settlementPrice;
    mapping(uint256 => bool) private _isSettled;
    mapping(uint256 => uint64) private _settledAt;

    mapping(uint256 => SettlementProposal) private _settlementProposal;

    uint256 public minExpiryDelay;
    uint256 public settlementFinalityDelay;

    mapping(address => bool) public isSettlementAssetAllowed;

    mapping(address => uint256[]) private _seriesByUnderlying;

    mapping(uint256 => bytes32) public seriesMetadata;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlySeriesCreator() {
        if (!isSeriesCreator[msg.sender]) revert NotAuthorized();
        _;
    }

    modifier onlyOwnerOrSettlementOperator() {
        if (msg.sender != owner && msg.sender != settlementOperator) revert NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner) {
        if (_owner == address(0)) revert NotAuthorized();
        owner = _owner;
        isSeriesCreator[_owner] = true;

        minExpiryDelay = 0;
        settlementFinalityDelay = 0;

        emit OwnershipTransferred(address(0), _owner);
        emit SeriesCreatorSet(_owner, true);
        emit SettlementFinalityDelaySet(0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP MANAGEMENT (2-step)
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert NotAuthorized();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        address po = pendingOwner;
        if (msg.sender != po) revert NotAuthorized();
        address oldOwner = owner;
        owner = po;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        if (pendingOwner == address(0)) revert OwnershipTransferNotInitiated();
        pendingOwner = address(0);
    }

    function renounceOwnership() external onlyOwner {
        if (pendingOwner != address(0)) revert NotAuthorized();
        address oldOwner = owner;
        owner = address(0);
        emit OwnershipTransferred(oldOwner, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setSeriesCreator(address account, bool allowed) external onlyOwner {
        isSeriesCreator[account] = allowed;
        emit SeriesCreatorSet(account, allowed);
    }

    function setSettlementOperator(address account) external onlyOwner {
        settlementOperator = account;
        emit SettlementOperatorSet(account);
    }

    function setUnderlyingConfig(address underlying, UnderlyingConfig calldata cfg) external onlyOwner {
        if (underlying == address(0)) revert UnderlyingZero();

        if (cfg.spotShockDownBps > MAX_SPOT_SHOCK_BPS || cfg.spotShockUpBps > MAX_SPOT_SHOCK_BPS) {
            revert InvalidUnderlyingConfig();
        }
        if (cfg.volShockDownBps > MAX_VOL_SHOCK_BPS || cfg.volShockUpBps > MAX_VOL_SHOCK_BPS) {
            revert InvalidUnderlyingConfig();
        }

        underlyingConfigs[underlying] = cfg;

        emit UnderlyingConfigSet(
            underlying,
            cfg.oracle,
            cfg.spotShockDownBps,
            cfg.spotShockUpBps,
            cfg.volShockDownBps,
            cfg.volShockUpBps,
            cfg.isEnabled
        );
    }

    function setSettlementAssetAllowed(address asset, bool allowed) external onlyOwner {
        if (asset == address(0)) revert SettlementZero();
        isSettlementAssetAllowed[asset] = allowed;
        emit SettlementAssetConfigured(asset, allowed);
    }

    function setMinExpiryDelay(uint256 _minExpiryDelay) external onlyOwner {
        uint256 old = minExpiryDelay;
        minExpiryDelay = _minExpiryDelay;
        emit MinExpiryDelaySet(old, _minExpiryDelay);
    }

    function setSettlementFinalityDelay(uint256 _delay) external onlyOwner {
        if (_delay > 7 days) revert InvalidDelay();
        uint256 old = settlementFinalityDelay;
        settlementFinalityDelay = _delay;
        emit SettlementFinalityDelaySet(old, _delay);
    }

    /*//////////////////////////////////////////////////////////////
                            SERIES CREATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Crée une nouvelle série d'options (default: 1 contrat = 1 underlying, donc contractSize1e8 = 1e8)
    function createSeries(
        address underlying,
        address settlementAsset,
        uint64 expiry,
        uint64 strike,
        bool isCall,
        bool isEuropean
    ) public onlySeriesCreator returns (uint256 optionId) {
        optionId = _createSeries(
            underlying,
            settlementAsset,
            expiry,
            strike,
            uint128(PRICE_SCALE), // 1 contrat = 1 underlying
            isCall,
            isEuropean
        );
    }

    /// @notice Crée une nouvelle série d'options en spécifiant explicitement la taille d'un contrat.
    function createSeries(
        address underlying,
        address settlementAsset,
        uint64 expiry,
        uint64 strike,
        uint128 contractSize1e8,
        bool isCall,
        bool isEuropean
    ) public onlySeriesCreator returns (uint256 optionId) {
        optionId = _createSeries(
            underlying,
            settlementAsset,
            expiry,
            strike,
            contractSize1e8,
            isCall,
            isEuropean
        );
    }

    function _createSeries(
        address underlying,
        address settlementAsset,
        uint64 expiry,
        uint64 strike,
        uint128 contractSize1e8,
        bool isCall,
        bool isEuropean
    ) internal returns (uint256 optionId) {
        if (underlying == address(0)) revert UnderlyingZero();
        if (settlementAsset == address(0)) revert SettlementZero();

        UnderlyingConfig memory uCfg = underlyingConfigs[underlying];
        if (!uCfg.isEnabled) revert UnderlyingNotEnabled();

        if (!isSettlementAssetAllowed[settlementAsset]) revert SettlementAssetNotAllowed();

        if (expiry <= uint64(block.timestamp)) revert ExpiryInPast();
        if (minExpiryDelay > 0 && expiry < uint64(block.timestamp + minExpiryDelay)) revert ExpiryTooSoon();

        if (strike == 0) revert StrikeZero();
        if (contractSize1e8 == 0) revert ContractSizeZero();
        if (contractSize1e8 > MAX_CONTRACT_SIZE_1E8) revert InvalidUnderlyingConfig(); // reuse error

        OptionSeries memory s = OptionSeries({
            underlying: underlying,
            settlementAsset: settlementAsset,
            expiry: expiry,
            strike: strike,
            contractSize1e8: contractSize1e8,
            isCall: isCall,
            isEuropean: isEuropean,
            exists: true,
            isActive: true
        });

        optionId = _computeOptionId(s);
        if (_series[optionId].exists) revert SeriesAlreadyExists();

        _series[optionId] = s;
        _allOptionIds.push(optionId);
        _seriesByUnderlying[underlying].push(optionId);

        emit SeriesCreated(
            optionId,
            underlying,
            settlementAsset,
            expiry,
            strike,
            contractSize1e8,
            isCall,
            isEuropean
        );
    }

    /// @notice Crée un strip (tous les strikes d'une même échéance) en calls + puts (default contractSize1e8 = 1e8)
    function createStrip(
        address underlying,
        address settlementAsset,
        uint64 expiry,
        uint64[] calldata strikes,
        bool isEuropean
    ) external onlySeriesCreator {
        uint256 len = strikes.length;
        for (uint256 i = 0; i < len; i++) {
            createSeries(underlying, settlementAsset, expiry, strikes[i], true, isEuropean);
            createSeries(underlying, settlementAsset, expiry, strikes[i], false, isEuropean);
        }
    }

    /// @notice Crée un strip avec taille de contrat explicite
    function createStrip(
        address underlying,
        address settlementAsset,
        uint64 expiry,
        uint64[] calldata strikes,
        uint128 contractSize1e8,
        bool isEuropean
    ) external onlySeriesCreator {
        uint256 len = strikes.length;
        for (uint256 i = 0; i < len; i++) {
            createSeries(underlying, settlementAsset, expiry, strikes[i], contractSize1e8, true, isEuropean);
            createSeries(underlying, settlementAsset, expiry, strikes[i], contractSize1e8, false, isEuropean);
        }
    }

    function setSeriesActive(uint256 optionId, bool isActive) external onlyOwner {
        OptionSeries storage s = _series[optionId];
        if (!s.exists) revert UnknownSeries();

        s.isActive = isActive;
        emit SeriesStatusUpdated(optionId, isActive);
    }

    /*//////////////////////////////////////////////////////////////
                        SETTLEMENT (2-phase)
    //////////////////////////////////////////////////////////////*/

    function setSettlementPrice(uint256 optionId, uint256 settlementPrice) external onlyOwnerOrSettlementOperator {
        OptionSeries memory s = _series[optionId];
        if (!s.exists) revert UnknownSeries();
        if (settlementPrice == 0) revert SettlementPriceZero();
        if (uint64(block.timestamp) < s.expiry) revert NotExpiredYet();
        if (_isSettled[optionId]) revert SettlementAlreadySet();

        if (settlementFinalityDelay == 0) {
            _settlementPrice[optionId] = settlementPrice;
            _isSettled[optionId] = true;
            _settledAt[optionId] = uint64(block.timestamp);

            emit SettlementPriceFinalized(optionId, settlementPrice, block.timestamp);
            return;
        }

        SettlementProposal storage p = _settlementProposal[optionId];
        if (p.exists) revert SettlementProposalAlreadyExists();

        p.price = settlementPrice;
        p.proposedAt = uint64(block.timestamp);
        p.exists = true;

        emit SettlementPriceProposed(optionId, settlementPrice, block.timestamp);
    }

    function finalizeSettlementPrice(uint256 optionId) external onlyOwnerOrSettlementOperator {
        OptionSeries memory s = _series[optionId];
        if (!s.exists) revert UnknownSeries();
        if (_isSettled[optionId]) revert SettlementAlreadySet();
        if (uint64(block.timestamp) < s.expiry) revert NotExpiredYet();

        SettlementProposal memory p = _settlementProposal[optionId];
        if (!p.exists || p.price == 0) revert NoSettlementProposal();

        if (block.timestamp < uint256(p.proposedAt) + settlementFinalityDelay) {
            revert SettlementFinalityDelayNotElapsed();
        }

        _settlementPrice[optionId] = p.price;
        _isSettled[optionId] = true;
        _settledAt[optionId] = uint64(block.timestamp);

        delete _settlementProposal[optionId];

        emit SettlementPriceFinalized(optionId, _settlementPrice[optionId], block.timestamp);
    }

    function cancelSettlementProposal(uint256 optionId) external onlyOwner {
        if (_isSettled[optionId]) revert SettlementAlreadySet();
        SettlementProposal memory p = _settlementProposal[optionId];
        if (!p.exists) revert NoSettlementProposal();
        delete _settlementProposal[optionId];
    }

    function setSeriesMetadata(uint256 optionId, bytes32 metadata) external onlyOwner {
        OptionSeries memory s = _series[optionId];
        if (!s.exists) revert UnknownSeries();

        seriesMetadata[optionId] = metadata;
        emit SeriesMetadataSet(optionId, metadata);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getSeries(uint256 optionId) external view returns (OptionSeries memory) {
        OptionSeries memory s = _series[optionId];
        if (!s.exists) revert UnknownSeries();
        return s;
    }

    function seriesExists(uint256 optionId) external view returns (bool) {
        return _series[optionId].exists;
    }

    function totalSeries() external view returns (uint256) {
        return _allOptionIds.length;
    }

    function seriesAt(uint256 index) external view returns (uint256) {
        require(index < _allOptionIds.length, "INDEX_OOB");
        return _allOptionIds[index];
    }

    function getSettlementInfo(uint256 optionId) external view returns (uint256 settlementPrice, bool isSet) {
        if (!_series[optionId].exists) revert UnknownSeries();
        return (_settlementPrice[optionId], _isSettled[optionId]);
    }

    function getSettlementFinalizedAt(uint256 optionId) external view returns (uint64) {
        if (!_series[optionId].exists) revert UnknownSeries();
        return _settledAt[optionId];
    }

    function getSettlementProposal(uint256 optionId)
        external
        view
        returns (uint256 proposedPrice, uint64 proposedAt, bool exists)
    {
        if (!_series[optionId].exists) revert UnknownSeries();
        SettlementProposal memory p = _settlementProposal[optionId];
        return (p.price, p.proposedAt, p.exists);
    }

    function isSettled(uint256 optionId) external view returns (bool) {
        if (!_series[optionId].exists) revert UnknownSeries();
        return _isSettled[optionId];
    }

    function getAllOptionIds() external view returns (uint256[] memory) {
        return _allOptionIds;
    }

    function getSeriesByUnderlying(address underlying) external view returns (uint256[] memory) {
        return _seriesByUnderlying[underlying];
    }

    function getActiveSeriesByUnderlying(address underlying) external view returns (uint256[] memory activeIds) {
        uint256[] memory allIds = _seriesByUnderlying[underlying];
        uint256 len = allIds.length;

        uint256 count;
        for (uint256 i = 0; i < len; i++) {
            OptionSeries memory s = _series[allIds[i]];
            if (s.exists && s.isActive && s.expiry >= uint64(block.timestamp)) count++;
        }

        activeIds = new uint256[](count);
        uint256 j;
        for (uint256 i = 0; i < len; i++) {
            OptionSeries memory s = _series[allIds[i]];
            if (s.exists && s.isActive && s.expiry >= uint64(block.timestamp)) {
                activeIds[j++] = allIds[i];
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _computeOptionId(OptionSeries memory s) internal pure returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(
                    s.underlying,
                    s.settlementAsset,
                    s.expiry,
                    s.strike,
                    s.contractSize1e8,
                    s.isCall,
                    s.isEuropean
                )
            )
        );
    }
}
