// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title OptionProductRegistry
/// @notice Registre central des séries d'options de DeOpt v2
/// @dev Ne gère pas les positions ni la marge, seulement la définition des instruments
///      + le prix de settlement officiel à l'expiration.
///      Utilisé par:
///        - MarginEngine (getSeries, getSettlementInfo)
///        - RiskModule   (OptionSeries, underlyingConfigs)
contract OptionProductRegistry {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Représente une série d'options (un instrument unique)
    /// @dev
    ///   - `strike` et `settlementPrice` sont dans la même convention d'unités
    ///     (ex: *1e8 si on suit un oracle type Chainlink 8 décimales).
    struct OptionSeries {
        address underlying;       // Sous-jacent (ex: WETH)
        address settlementAsset;  // Asset de règlement (ex: USDC)
        uint64 expiry;            // Timestamp d'expiration
        uint64 strike;            // Strike * 1e8 (ou autre convention cohérente avec l'oracle)
        bool isCall;              // true = Call, false = Put
        bool isEuropean;          // true = Européenne (pour usage futur / front)
        bool exists;              // Flag pour savoir si la série est enregistrée
        bool isActive;            // true = tradable, false = close-only / désactivée
    }

    /// @notice Configuration de risque / oracle par sous-jacent
    /// @dev
    ///   - Les champs *Shock* sont en basis points (bps).
    ///   - Le RiskModule utilise au minimum:
    ///       * isEnabled
    ///       * spotShockUpBps
    ///       * spotShockDownBps
    ///       * volShockUpBps
    struct UnderlyingConfig {
        address oracle;           // Oracle de prix pour ce sous-jacent (optionnel côté RiskModule)
        uint64 spotShockDownBps;  // choc spot down, ex: 2500 = -25%
        uint64 spotShockUpBps;    // choc spot up, ex: 2500 = +25%
        uint64 volShockDownBps;   // choc vol down (actuellement inutilisé par le RiskModule)
        uint64 volShockUpBps;     // choc vol up, ex: 1500 = 15% du ref
        bool isEnabled;           // sous-jacent utilisable ou non
    }

    /// @notice Proposition de prix de settlement (phase 1), finalisation (phase 2).
    /// @dev Permet une sécurité “conservative” (delay) avant de considérer un prix comme final.
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

    /// @notice Chocs de spot max autorisés (up/down) en bps.
    /// @dev On autorise jusqu'à 100% de choc pour laisser de la flexibilité,
    ///      mais on empêche les valeurs délirantes (ex: 50000 bps).
    uint64 public constant MAX_SPOT_SHOCK_BPS = 10_000; // 100%

    /// @notice Chocs de vol max autorisés (up/down) en bps.
    /// @dev 5000 bps = 50% du ref, déjà très conservateur.
    uint64 public constant MAX_VOL_SHOCK_BPS = 5_000; // 50%

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

    /// @notice Phase 1: proposition de prix
    event SettlementPriceProposed(uint256 indexed optionId, uint256 proposedPrice, uint256 proposedAt);

    /// @notice Phase 2: prix final (consommable par le MarginEngine)
    event SettlementPriceFinalized(uint256 indexed optionId, uint256 settlementPrice, uint256 finalizedAt);

    /// @notice Emis quand un asset de règlement est autorisé / désactivé
    event SettlementAssetConfigured(address indexed asset, bool isAllowed);

    /// @notice Emis quand le minExpiryDelay est mis à jour
    event MinExpiryDelaySet(uint256 oldDelay, uint256 newDelay);

    /// @notice Emis quand le délai de finalisation de settlement est mis à jour
    event SettlementFinalityDelaySet(uint256 oldDelay, uint256 newDelay);

    /// @notice Métadonnées arbitraires par série (hook V3)
    event SeriesMetadataSet(uint256 indexed optionId, bytes32 metadata);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping principal: optionId => définition de la série
    mapping(uint256 => OptionSeries) private _series;

    /// @notice Liste de tous les optionIds créés (pratique pour itérer off-chain)
    uint256[] private _allOptionIds;

    /// @notice Adresse "owner" (gouvernance / toi au début)
    address public owner;

    /// @notice Ownership 2-step (plus safe en prod)
    address public pendingOwner;

    /// @notice Rôle simple: qui a le droit de créer des séries ?
    mapping(address => bool) public isSeriesCreator;

    /// @notice Configuration de chaque sous-jacent (pour le moteur de risque)
    mapping(address => UnderlyingConfig) public underlyingConfigs;

    /// @notice Opérateur autorisé à fixer les prix de settlement
    address public settlementOperator;

    /// @notice Prix de settlement FINAL par série (mêmes unités que strike, ex: *1e8)
    mapping(uint256 => uint256) private _settlementPrice;

    /// @notice Flag indiquant si le prix de settlement a été FINALISÉ pour une série
    mapping(uint256 => bool) private _isSettled;

    /// @notice Timestamp de finalisation (utile audit / monitoring)
    mapping(uint256 => uint64) private _settledAt;

    /// @notice Phase 1: proposition de settlement (optionnelle si delay = 0)
    mapping(uint256 => SettlementProposal) private _settlementProposal;

    /// @notice Délai minimal entre maintenant et l'expiration à la création d'une série
    /// @dev 0 = pas de contrainte (comportement actuel), configurable ensuite.
    uint256 public minExpiryDelay;

    /// @notice Délai minimal entre la proposition et la finalisation du settlement.
    /// @dev 0 = pas de phase 2 (mode legacy): setSettlementPrice() finalise directement.
    uint256 public settlementFinalityDelay;

    /// @notice Asset de règlement autorisé ? (ex: USDC, USDT)
    mapping(address => bool) public isSettlementAssetAllowed;

    /// @notice Index par sous-jacent: liste des optionIds (actifs + inactifs)
    mapping(address => uint256[]) private _seriesByUnderlying;

    /// @notice Métadonnées libres par série (hook pour V3 : vol, hash off-chain, flags, etc.)
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
        if (msg.sender != owner && msg.sender != settlementOperator) {
            revert NotAuthorized();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner) {
        if (_owner == address(0)) revert NotAuthorized();
        owner = _owner;
        isSeriesCreator[_owner] = true;

        // par défaut pas de délai min (backward compatible)
        minExpiryDelay = 0;

        // par défaut: mode legacy (finalisation immédiate)
        settlementFinalityDelay = 0;

        emit OwnershipTransferred(address(0), _owner);
        emit SeriesCreatorSet(_owner, true);
        emit SettlementFinalityDelaySet(0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP MANAGEMENT (2-step)
    //////////////////////////////////////////////////////////////*/

    /// @notice Démarre un transfert d’ownership (2-step)
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert NotAuthorized();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Le nouveau owner accepte le transfert
    function acceptOwnership() external {
        address po = pendingOwner;
        if (msg.sender != po) revert NotAuthorized();
        address oldOwner = owner;
        owner = po;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }

    /// @notice Annule un transfert en cours
    function cancelOwnershipTransfer() external onlyOwner {
        if (pendingOwner == address(0)) revert OwnershipTransferNotInitiated();
        pendingOwner = address(0);
        // pas d'event dédié pour rester minimal; on peut en ajouter si tu veux
    }

    /// @dev En prod, “renounceOwnership” est souvent une footgun.
    ///      On le laisse volontairement, mais seulement si pendingOwner est nul.
    function renounceOwnership() external onlyOwner {
        // évite de renoncer en plein transfert
        if (pendingOwner != address(0)) revert NotAuthorized();
        address oldOwner = owner;
        owner = address(0);
        emit OwnershipTransferred(oldOwner, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Permet à l'owner d'ajouter ou retirer un créateur de séries
    function setSeriesCreator(address account, bool allowed) external onlyOwner {
        isSeriesCreator[account] = allowed;
        emit SeriesCreatorSet(account, allowed);
    }

    /// @notice Configure l'opérateur de settlement autorisé à publier les prix finaux
    function setSettlementOperator(address account) external onlyOwner {
        settlementOperator = account;
        emit SettlementOperatorSet(account);
    }

    /// @notice Configure les paramètres de risque / oracle d'un sous-jacent
    function setUnderlyingConfig(address underlying, UnderlyingConfig calldata cfg)
        external
        onlyOwner
    {
        if (underlying == address(0)) revert UnderlyingZero();

        // Bornes défensives sur les chocs de spot
        if (
            cfg.spotShockDownBps > MAX_SPOT_SHOCK_BPS ||
            cfg.spotShockUpBps   > MAX_SPOT_SHOCK_BPS
        ) {
            revert InvalidUnderlyingConfig();
        }

        // Bornes défensives sur les chocs de vol
        if (
            cfg.volShockDownBps > MAX_VOL_SHOCK_BPS ||
            cfg.volShockUpBps   > MAX_VOL_SHOCK_BPS
        ) {
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

    /// @notice Configure un asset de règlement autorisé (USDC, USDT, etc.)
    function setSettlementAssetAllowed(address asset, bool allowed) external onlyOwner {
        if (asset == address(0)) revert SettlementZero();
        isSettlementAssetAllowed[asset] = allowed;
        emit SettlementAssetConfigured(asset, allowed);
    }

    /// @notice Définit le délai minimal entre now et expiry lors de la création d'une série.
    function setMinExpiryDelay(uint256 _minExpiryDelay) external onlyOwner {
        uint256 old = minExpiryDelay;
        minExpiryDelay = _minExpiryDelay;
        emit MinExpiryDelaySet(old, _minExpiryDelay);
    }

    /// @notice Définit le délai minimal entre proposition et finalisation du settlement.
    /// @dev Reco prod: > 0 (ex: 10-30 min) si settlementOperator est externe / automatisé.
    function setSettlementFinalityDelay(uint256 _delay) external onlyOwner {
        // bornage défensif: éviter un délai délirant (ex: 30 jours) sauf si tu le veux vraiment
        // Ici: max 7 jours. Ajustable si tu préfères.
        if (_delay > 7 days) revert InvalidDelay();
        uint256 old = settlementFinalityDelay;
        settlementFinalityDelay = _delay;
        emit SettlementFinalityDelaySet(old, _delay);
    }

    /// @notice Crée une nouvelle série d'options et renvoie son optionId
    /// @dev Ajout de contrôles:
    ///      - underlying doit être configuré et isEnabled = true
    ///      - settlementAsset doit être dans l'allowlist
    ///      - expiry >= block.timestamp + minExpiryDelay (si > 0)
    function createSeries(
        address underlying,
        address settlementAsset,
        uint64 expiry,
        uint64 strike,
        bool isCall,
        bool isEuropean
    ) public onlySeriesCreator returns (uint256 optionId) {
        if (underlying == address(0)) revert UnderlyingZero();
        if (settlementAsset == address(0)) revert SettlementZero();

        // vérifier que le sous-jacent est activé
        UnderlyingConfig memory uCfg = underlyingConfigs[underlying];
        if (!uCfg.isEnabled) revert UnderlyingNotEnabled();

        // vérifier que l'asset de règlement est autorisé
        if (!isSettlementAssetAllowed[settlementAsset]) {
            revert SettlementAssetNotAllowed();
        }

        // ancien check: expiry > now
        if (expiry <= uint64(block.timestamp)) revert ExpiryInPast();

        // nouveau: délai minimal
        if (minExpiryDelay > 0 && expiry < uint64(block.timestamp + minExpiryDelay)) {
            revert ExpiryTooSoon();
        }

        if (strike == 0) revert StrikeZero();

        OptionSeries memory s = OptionSeries({
            underlying: underlying,
            settlementAsset: settlementAsset,
            expiry: expiry,
            strike: strike,
            isCall: isCall,
            isEuropean: isEuropean,
            exists: true,
            isActive: true // active par défaut à la création
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
            isCall,
            isEuropean
        );
    }

    /// @notice Crée un strip (tous les strikes d'une même échéance) en calls + puts
    function createStrip(
        address underlying,
        address settlementAsset,
        uint64 expiry,
        uint64[] calldata strikes,
        bool isEuropean
    ) external onlySeriesCreator {
        uint256 len = strikes.length;
        for (uint256 i = 0; i < len; i++) {
            createSeries(underlying, settlementAsset, expiry, strikes[i], true, isEuropean);  // Call
            createSeries(underlying, settlementAsset, expiry, strikes[i], false, isEuropean); // Put
        }
    }

    /// @notice Active / désactive une série (par ex. passer en close-only)
    function setSeriesActive(uint256 optionId, bool isActive) external onlyOwner {
        OptionSeries storage s = _series[optionId];
        if (!s.exists) revert UnknownSeries();

        s.isActive = isActive;
        emit SeriesStatusUpdated(optionId, isActive);
    }

    /*//////////////////////////////////////////////////////////////
                        SETTLEMENT (2-phase)
    //////////////////////////////////////////////////////////////*/

    /// @notice Mode legacy-compatible: si settlementFinalityDelay == 0 => finalise immédiatement.
    /// @notice Sinon: crée une PROPOSITION (phase 1). La finalisation se fait via finalizeSettlementPrice().
    function setSettlementPrice(uint256 optionId, uint256 settlementPrice)
        external
        onlyOwnerOrSettlementOperator
    {
        OptionSeries memory s = _series[optionId];
        if (!s.exists) revert UnknownSeries();
        if (settlementPrice == 0) revert SettlementPriceZero();
        if (uint64(block.timestamp) < s.expiry) revert NotExpiredYet();
        if (_isSettled[optionId]) revert SettlementAlreadySet();

        // mode legacy (delay == 0): finalisation immédiate (comportement proche de ton code)
        if (settlementFinalityDelay == 0) {
            _settlementPrice[optionId] = settlementPrice;
            _isSettled[optionId] = true;
            _settledAt[optionId] = uint64(block.timestamp);

            emit SettlementPriceFinalized(optionId, settlementPrice, block.timestamp);
            return;
        }

        // mode 2-phase: proposer une seule fois (conservative: pas de remplacement)
        SettlementProposal storage p = _settlementProposal[optionId];
        if (p.exists) revert SettlementProposalAlreadyExists();

        p.price = settlementPrice;
        p.proposedAt = uint64(block.timestamp);
        p.exists = true;

        emit SettlementPriceProposed(optionId, settlementPrice, block.timestamp);
    }

    /// @notice Finalise le settlement après le délai de sécurité.
    /// @dev Appelable par owner ou settlementOperator (même rôle que setSettlementPrice).
    function finalizeSettlementPrice(uint256 optionId) external onlyOwnerOrSettlementOperator {
        OptionSeries memory s = _series[optionId];
        if (!s.exists) revert UnknownSeries();
        if (_isSettled[optionId]) revert SettlementAlreadySet();
        if (uint64(block.timestamp) < s.expiry) revert NotExpiredYet();

        SettlementProposal memory p = _settlementProposal[optionId];
        if (!p.exists || p.price == 0) revert NoSettlementProposal();

        // délai de finalité
        if (block.timestamp < uint256(p.proposedAt) + settlementFinalityDelay) {
            revert SettlementFinalityDelayNotElapsed();
        }

        _settlementPrice[optionId] = p.price;
        _isSettled[optionId] = true;
        _settledAt[optionId] = uint64(block.timestamp);

        // cleanup storage (optionnel)
        delete _settlementProposal[optionId];

        emit SettlementPriceFinalized(optionId, _settlementPrice[optionId], block.timestamp);
    }

    /// @notice Permet à l’owner d’annuler une proposition (si tu dois corriger une erreur opérateur).
    /// @dev Strictement owner pour éviter des jeux opérateur.
    function cancelSettlementProposal(uint256 optionId) external onlyOwner {
        if (_isSettled[optionId]) revert SettlementAlreadySet();
        SettlementProposal memory p = _settlementProposal[optionId];
        if (!p.exists) revert NoSettlementProposal();
        delete _settlementProposal[optionId];
        // pas d'event dédié pour rester minimal; on peut en ajouter si tu veux
    }

    /// @notice Stocke une métadonnée arbitraire pour une série (hook V3)
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

    /// @notice Retourne le prix de settlement FINAL et un flag indiquant s'il a été finalisé.
    /// @dev Utilisé par le MarginEngine pour le payoff / settlement.
    function getSettlementInfo(uint256 optionId)
        external
        view
        returns (uint256 settlementPrice, bool isSet)
    {
        if (!_series[optionId].exists) revert UnknownSeries();
        return (_settlementPrice[optionId], _isSettled[optionId]);
    }

    /// @notice Retourne le timestamp de finalisation (0 si pas settlé)
    function getSettlementFinalizedAt(uint256 optionId) external view returns (uint64) {
        if (!_series[optionId].exists) revert UnknownSeries();
        return _settledAt[optionId];
    }

    /// @notice Retourne la proposition de settlement (si settlementFinalityDelay > 0)
    function getSettlementProposal(uint256 optionId)
        external
        view
        returns (uint256 proposedPrice, uint64 proposedAt, bool exists)
    {
        if (!_series[optionId].exists) revert UnknownSeries();
        SettlementProposal memory p = _settlementProposal[optionId];
        return (p.price, p.proposedAt, p.exists);
    }

    /// @notice Indique si la série est déjà settlée (prix de settlement finalisé)
    function isSettled(uint256 optionId) external view returns (bool) {
        if (!_series[optionId].exists) revert UnknownSeries();
        return _isSettled[optionId];
    }

    /// @notice Retourne tous les optionIds (pour debug / off-chain)
    function getAllOptionIds() external view returns (uint256[] memory) {
        return _allOptionIds;
    }

    /// @notice Retourne toutes les séries (IDs) pour un sous-jacent (actives + inactives)
    function getSeriesByUnderlying(address underlying)
        external
        view
        returns (uint256[] memory)
    {
        return _seriesByUnderlying[underlying];
    }

    /// @notice Retourne les séries ACTIVES et non expirées pour un sous-jacent.
    /// @dev Pratique pour le front, mais potentiellement coûteux si beaucoup de séries.
    function getActiveSeriesByUnderlying(address underlying)
        external
        view
        returns (uint256[] memory activeIds)
    {
        uint256[] memory allIds = _seriesByUnderlying[underlying];
        uint256 len = allIds.length;

        uint256 count;
        for (uint256 i = 0; i < len; i++) {
            OptionSeries memory s = _series[allIds[i]];
            if (s.exists && s.isActive && s.expiry >= uint64(block.timestamp)) {
                count++;
            }
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
                    s.isCall,
                    s.isEuropean
                )
            )
        );
    }
}
