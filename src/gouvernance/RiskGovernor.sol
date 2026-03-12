// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ProtocolTimelock.sol";

/*//////////////////////////////////////////////////////////////
                            GOVERNANCE INTERFACES
//////////////////////////////////////////////////////////////*/

interface IRiskModuleGov {
    function setOracle(address _oracle) external;
    function setMarginEngine(address _marginEngine) external;
    function setMaxOracleDelay(uint256 _maxOracleDelay) external;
    function setOracleDownMmMultiplier(uint256 _multiplierBps) external;
    function setRiskParams(address _baseToken, uint256 _baseMMPerContract, uint256 _imFactorBps) external;
    function setCollateralConfig(address token, uint64 weightBps, bool isEnabled) external;
}

interface IMarginEngineGov {
    function setOracle(address oracle_) external;
    function setRiskModule(address riskModule_) external;
    function setInsuranceFund(address insuranceFund_) external;
    function setFeesManager(address feesManager_) external;
    function setFeeRecipient(address feeRecipient_) external;
    function clearFeeRecipient() external;
    function setRiskParams(address baseToken_, uint256 baseMMPerContract_, uint256 imFactorBps_) external;
    function setLiquidationParams(uint256 liquidationThresholdBps_, uint256 liquidationPenaltyBps_) external;
    function setLiquidationHardenParams(uint256 closeFactorBps_, uint256 minImprovementBps_) external;
    function setLiquidationPricingParams(uint256 liquidationPriceSpreadBps_, uint256 minLiqPriceBpsOfIntrinsic_) external;
    function setLiquidationOracleMaxDelay(uint32 delay_) external;
}

interface IOracleRouterGov {
    function setFeed(
        address baseAsset,
        address quoteAsset,
        address primarySource,
        address secondarySource,
        uint32 maxDelay,
        uint16 maxDeviationBps,
        bool isActive
    ) external;

    function setFeedStatus(address baseAsset, address quoteAsset, bool isActive) external;
    function clearFeed(address baseAsset, address quoteAsset) external;
    function setMaxOracleDelay(uint32 _delay) external;
}

interface IFeesManagerGov {
    function setFeeBpsCap(uint16 newCap) external;
    function setDefaultFees(
        uint16 makerNotionalFeeBps,
        uint16 makerPremiumCapBps,
        uint16 takerNotionalFeeBps,
        uint16 takerPremiumCapBps
    ) external;
    function setMerkleRoot(bytes32 newRoot) external;
    function setMerkleRootWithEpoch(bytes32 newRoot, uint64 newEpoch) external;
    function setOverride(
        address trader,
        uint16 makerNotionalFeeBps,
        uint16 makerPremiumCapBps,
        uint16 takerNotionalFeeBps,
        uint16 takerPremiumCapBps,
        uint64 expiry,
        bool enabled
    ) external;
    function disableOverride(address trader) external;
}

interface IOptionProductRegistryGov {
    struct UnderlyingConfig {
        address oracle;
        uint64 spotShockDownBps;
        uint64 spotShockUpBps;
        uint64 volShockDownBps;
        uint64 volShockUpBps;
        bool isEnabled;
    }

    function setSeriesCreator(address account, bool allowed) external;
    function setSettlementOperator(address account) external;
    function setUnderlyingConfig(address underlying, UnderlyingConfig calldata cfg) external;
    function setSettlementAssetAllowed(address asset, bool allowed) external;
    function setMinExpiryDelay(uint256 _minExpiryDelay) external;
    function setSettlementFinalityDelay(uint256 _delay) external;
    function setSeriesActive(uint256 optionId, bool isActive) external;
    function setSeriesMetadata(uint256 optionId, bytes32 metadata) external;
}

interface ICollateralVaultGov {
    function setMarginEngine(address _marginEngine) external;
    function setRiskModule(address _riskModule) external;
    function setCollateralToken(address token, bool isSupported, uint8 decimals, uint16 collateralFactorBps) external;
    function setTokenStrategy(address token, address adapter) external;
}

interface IInsuranceFundGov {
    function setOperator(address operator, bool allowed) external;
    function setTokenAllowed(address token, bool allowed) external;
}

/*//////////////////////////////////////////////////////////////
                            RISK GOVERNOR
//////////////////////////////////////////////////////////////*/

/// @title RiskGovernor
/// @notice Wrapper de gouvernance orienté risque / paramètres protocole au-dessus du ProtocolTimelock.
/// @dev
///  Architecture visée:
///   - les contrats sensibles sont ownés par ProtocolTimelock
///   - RiskGovernor est autorisé comme proposer + executor sur le timelock
///   - l'owner de RiskGovernor est le multisig / admin protocolaire
///   - le guardian de RiskGovernor peut annuler les opérations via le timelock
///
///  Design:
///   - fonctions typed pour construire / queue les opérations sensibles
///   - exécution et annulation génériques
///   - adresses des modules gouvernés configurables
contract RiskGovernor {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);
    event GuardianSet(address indexed oldGuardian, address indexed newGuardian);

    event RiskModuleSet(address indexed oldTarget, address indexed newTarget);
    event MarginEngineSet(address indexed oldTarget, address indexed newTarget);
    event OracleRouterSet(address indexed oldTarget, address indexed newTarget);
    event FeesManagerSet(address indexed oldTarget, address indexed newTarget);
    event OptionRegistrySet(address indexed oldTarget, address indexed newTarget);
    event CollateralVaultSet(address indexed oldTarget, address indexed newTarget);
    event InsuranceFundSet(address indexed oldTarget, address indexed newTarget);

    event OperationQueued(bytes32 indexed txHash, address indexed target, uint256 value, uint256 eta, bytes data);
    event OperationCancelled(bytes32 indexed txHash, address indexed target, uint256 value, uint256 eta, bytes data);
    event OperationExecuted(bytes32 indexed txHash, address indexed target, uint256 value, uint256 eta, bytes data);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error ZeroAddress();
    error OwnershipTransferNotInitiated();
    error TimelockValueMismatch();

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;
    address public guardian;

    ProtocolTimelock public immutable timelock;

    address public riskModule;
    address public marginEngine;
    address public oracleRouter;
    address public feesManager;
    address public optionRegistry;
    address public collateralVault;
    address public insuranceFund;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner) revert NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _owner,
        address _guardian,
        address _timelock,
        address _riskModule,
        address _marginEngine,
        address _oracleRouter,
        address _feesManager,
        address _optionRegistry,
        address _collateralVault,
        address _insuranceFund
    ) {
        if (_owner == address(0) || _timelock == address(0)) revert ZeroAddress();

        owner = _owner;
        guardian = _guardian;
        timelock = ProtocolTimelock(payable(_timelock));

        riskModule = _riskModule;
        marginEngine = _marginEngine;
        oracleRouter = _oracleRouter;
        feesManager = _feesManager;
        optionRegistry = _optionRegistry;
        collateralVault = _collateralVault;
        insuranceFund = _insuranceFund;

        emit OwnershipTransferred(address(0), _owner);
        emit GuardianSet(address(0), _guardian);
        emit RiskModuleSet(address(0), _riskModule);
        emit MarginEngineSet(address(0), _marginEngine);
        emit OracleRouterSet(address(0), _oracleRouter);
        emit FeesManagerSet(address(0), _feesManager);
        emit OptionRegistrySet(address(0), _optionRegistry);
        emit CollateralVaultSet(address(0), _collateralVault);
        emit InsuranceFundSet(address(0), _insuranceFund);
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
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function setGuardian(address newGuardian) external onlyOwner {
        address old = guardian;
        guardian = newGuardian;
        emit GuardianSet(old, newGuardian);
    }

    function setRiskModuleTarget(address newTarget) external onlyOwner {
        address old = riskModule;
        riskModule = newTarget;
        emit RiskModuleSet(old, newTarget);
    }

    function setMarginEngineTarget(address newTarget) external onlyOwner {
        address old = marginEngine;
        marginEngine = newTarget;
        emit MarginEngineSet(old, newTarget);
    }

    function setOracleRouterTarget(address newTarget) external onlyOwner {
        address old = oracleRouter;
        oracleRouter = newTarget;
        emit OracleRouterSet(old, newTarget);
    }

    function setFeesManagerTarget(address newTarget) external onlyOwner {
        address old = feesManager;
        feesManager = newTarget;
        emit FeesManagerSet(old, newTarget);
    }

    function setOptionRegistryTarget(address newTarget) external onlyOwner {
        address old = optionRegistry;
        optionRegistry = newTarget;
        emit OptionRegistrySet(old, newTarget);
    }

    function setCollateralVaultTarget(address newTarget) external onlyOwner {
        address old = collateralVault;
        collateralVault = newTarget;
        emit CollateralVaultSet(old, newTarget);
    }

    function setInsuranceFundTarget(address newTarget) external onlyOwner {
        address old = insuranceFund;
        insuranceFund = newTarget;
        emit InsuranceFundSet(old, newTarget);
    }

    /*//////////////////////////////////////////////////////////////
                            GENERIC TIMLOCK WRAPPERS
    //////////////////////////////////////////////////////////////*/

    function hashOperation(address target, uint256 value, bytes calldata data, uint256 eta)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(target, value, data, eta));
    }

    function queueOperation(address target, uint256 value, bytes calldata data, uint256 eta)
        public
        onlyOwner
        returns (bytes32 txHash)
    {
        txHash = timelock.queueTransaction(target, value, data, eta);
        emit OperationQueued(txHash, target, value, eta, data);
    }

    function cancelOperation(address target, uint256 value, bytes calldata data, uint256 eta)
        public
        onlyGuardianOrOwner
        returns (bytes32 txHash)
    {
        txHash = timelock.cancelTransaction(target, value, data, eta);
        emit OperationCancelled(txHash, target, value, eta, data);
    }

    function executeOperation(address target, uint256 value, bytes calldata data, uint256 eta)
        public
        payable
        onlyOwner
        returns (bytes memory returnData)
    {
        if (msg.value != value) revert TimelockValueMismatch();

        bytes32 txHash = keccak256(abi.encode(target, value, data, eta));
        returnData = timelock.executeTransaction{value: value}(target, value, data, eta);
        emit OperationExecuted(txHash, target, value, eta, data);
    }

    /*//////////////////////////////////////////////////////////////
                            RISK MODULE HELPERS
    //////////////////////////////////////////////////////////////*/

    function queueRiskModuleSetRiskParams(
        address baseToken,
        uint256 baseMMPerContract,
        uint256 imFactorBps,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(
            IRiskModuleGov.setRiskParams,
            (baseToken, baseMMPerContract, imFactorBps)
        );
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModuleSetCollateralConfig(
        address token,
        uint64 weightBps,
        bool isEnabled,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(
            IRiskModuleGov.setCollateralConfig,
            (token, weightBps, isEnabled)
        );
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModuleSetOracle(address newOracle, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.setOracle, (newOracle));
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModuleSetMarginEngine(address newMarginEngine, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.setMarginEngine, (newMarginEngine));
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModuleSetMaxOracleDelay(uint256 newDelay, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.setMaxOracleDelay, (newDelay));
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModuleSetOracleDownMmMultiplier(uint256 multiplierBps, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.setOracleDownMmMultiplier, (multiplierBps));
        return queueOperation(riskModule, 0, data, eta);
    }

    /*//////////////////////////////////////////////////////////////
                        MARGIN ENGINE HELPERS
    //////////////////////////////////////////////////////////////*/

    function queueMarginSetOracle(address newOracle, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.setOracle, (newOracle));
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetRiskModule(address newRiskModule, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.setRiskModule, (newRiskModule));
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetInsuranceFund(address newInsuranceFund, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.setInsuranceFund, (newInsuranceFund));
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetFeesManager(address newFeesManager, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.setFeesManager, (newFeesManager));
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetFeeRecipient(address newFeeRecipient, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.setFeeRecipient, (newFeeRecipient));
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginClearFeeRecipient(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.clearFeeRecipient, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetRiskParams(
        address baseToken,
        uint256 baseMMPerContract,
        uint256 imFactorBps,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(
            IMarginEngineGov.setRiskParams,
            (baseToken, baseMMPerContract, imFactorBps)
        );
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetLiquidationParams(
        uint256 liquidationThresholdBps,
        uint256 liquidationPenaltyBps,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(
            IMarginEngineGov.setLiquidationParams,
            (liquidationThresholdBps, liquidationPenaltyBps)
        );
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetLiquidationHardenParams(
        uint256 closeFactorBps,
        uint256 minImprovementBps,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(
            IMarginEngineGov.setLiquidationHardenParams,
            (closeFactorBps, minImprovementBps)
        );
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetLiquidationPricingParams(
        uint256 liquidationPriceSpreadBps,
        uint256 minLiqPriceBpsOfIntrinsic,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(
            IMarginEngineGov.setLiquidationPricingParams,
            (liquidationPriceSpreadBps, minLiqPriceBpsOfIntrinsic)
        );
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetLiquidationOracleMaxDelay(uint32 delay, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.setLiquidationOracleMaxDelay, (delay));
        return queueOperation(marginEngine, 0, data, eta);
    }

    /*//////////////////////////////////////////////////////////////
                        ORACLE ROUTER HELPERS
    //////////////////////////////////////////////////////////////*/

    function queueOracleSetFeed(
        address baseAsset,
        address quoteAsset,
        address primarySource,
        address secondarySource,
        uint32 maxDelay,
        uint16 maxDeviationBps,
        bool isActive,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(
            IOracleRouterGov.setFeed,
            (baseAsset, quoteAsset, primarySource, secondarySource, maxDelay, maxDeviationBps, isActive)
        );
        return queueOperation(oracleRouter, 0, data, eta);
    }

    function queueOracleSetFeedStatus(
        address baseAsset,
        address quoteAsset,
        bool isActive,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOracleRouterGov.setFeedStatus, (baseAsset, quoteAsset, isActive));
        return queueOperation(oracleRouter, 0, data, eta);
    }

    function queueOracleClearFeed(address baseAsset, address quoteAsset, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOracleRouterGov.clearFeed, (baseAsset, quoteAsset));
        return queueOperation(oracleRouter, 0, data, eta);
    }

    function queueOracleSetMaxOracleDelay(uint32 delay, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOracleRouterGov.setMaxOracleDelay, (delay));
        return queueOperation(oracleRouter, 0, data, eta);
    }

    /*//////////////////////////////////////////////////////////////
                            FEES MANAGER HELPERS
    //////////////////////////////////////////////////////////////*/

    function queueFeesSetFeeBpsCap(uint16 newCap, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IFeesManagerGov.setFeeBpsCap, (newCap));
        return queueOperation(feesManager, 0, data, eta);
    }

    function queueFeesSetDefaultFees(
        uint16 makerNotionalFeeBps,
        uint16 makerPremiumCapBps,
        uint16 takerNotionalFeeBps,
        uint16 takerPremiumCapBps,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(
            IFeesManagerGov.setDefaultFees,
            (makerNotionalFeeBps, makerPremiumCapBps, takerNotionalFeeBps, takerPremiumCapBps)
        );
        return queueOperation(feesManager, 0, data, eta);
    }

    function queueFeesSetMerkleRoot(bytes32 newRoot, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IFeesManagerGov.setMerkleRoot, (newRoot));
        return queueOperation(feesManager, 0, data, eta);
    }

    function queueFeesSetMerkleRootWithEpoch(bytes32 newRoot, uint64 newEpoch, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IFeesManagerGov.setMerkleRootWithEpoch, (newRoot, newEpoch));
        return queueOperation(feesManager, 0, data, eta);
    }

    function queueFeesSetOverride(
        address trader,
        uint16 makerNotionalFeeBps,
        uint16 makerPremiumCapBps,
        uint16 takerNotionalFeeBps,
        uint16 takerPremiumCapBps,
        uint64 expiry,
        bool enabled,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(
            IFeesManagerGov.setOverride,
            (
                trader,
                makerNotionalFeeBps,
                makerPremiumCapBps,
                takerNotionalFeeBps,
                takerPremiumCapBps,
                expiry,
                enabled
            )
        );
        return queueOperation(feesManager, 0, data, eta);
    }

    function queueFeesDisableOverride(address trader, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IFeesManagerGov.disableOverride, (trader));
        return queueOperation(feesManager, 0, data, eta);
    }

    /*//////////////////////////////////////////////////////////////
                        OPTION REGISTRY HELPERS
    //////////////////////////////////////////////////////////////*/

    function queueRegistrySetSeriesCreator(address account, bool allowed, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOptionProductRegistryGov.setSeriesCreator, (account, allowed));
        return queueOperation(optionRegistry, 0, data, eta);
    }

    function queueRegistrySetSettlementOperator(address account, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOptionProductRegistryGov.setSettlementOperator, (account));
        return queueOperation(optionRegistry, 0, data, eta);
    }

    function queueRegistrySetUnderlyingConfig(
        address underlying,
        address oracle_,
        uint64 spotShockDownBps,
        uint64 spotShockUpBps,
        uint64 volShockDownBps,
        uint64 volShockUpBps,
        bool isEnabled,
        uint256 eta
    ) external returns (bytes32) {
        IOptionProductRegistryGov.UnderlyingConfig memory cfg = IOptionProductRegistryGov.UnderlyingConfig({
            oracle: oracle_,
            spotShockDownBps: spotShockDownBps,
            spotShockUpBps: spotShockUpBps,
            volShockDownBps: volShockDownBps,
            volShockUpBps: volShockUpBps,
            isEnabled: isEnabled
        });

        bytes memory data = abi.encodeCall(IOptionProductRegistryGov.setUnderlyingConfig, (underlying, cfg));
        return queueOperation(optionRegistry, 0, data, eta);
    }

    function queueRegistrySetSettlementAssetAllowed(address asset, bool allowed, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(IOptionProductRegistryGov.setSettlementAssetAllowed, (asset, allowed));
        return queueOperation(optionRegistry, 0, data, eta);
    }

    function queueRegistrySetMinExpiryDelay(uint256 newDelay, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOptionProductRegistryGov.setMinExpiryDelay, (newDelay));
        return queueOperation(optionRegistry, 0, data, eta);
    }

    function queueRegistrySetSettlementFinalityDelay(uint256 newDelay, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOptionProductRegistryGov.setSettlementFinalityDelay, (newDelay));
        return queueOperation(optionRegistry, 0, data, eta);
    }

    function queueRegistrySetSeriesActive(uint256 optionId, bool isActive, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOptionProductRegistryGov.setSeriesActive, (optionId, isActive));
        return queueOperation(optionRegistry, 0, data, eta);
    }

    function queueRegistrySetSeriesMetadata(uint256 optionId, bytes32 metadata, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(IOptionProductRegistryGov.setSeriesMetadata, (optionId, metadata));
        return queueOperation(optionRegistry, 0, data, eta);
    }

    /*//////////////////////////////////////////////////////////////
                        COLLATERAL VAULT HELPERS
    //////////////////////////////////////////////////////////////*/

    function queueVaultSetMarginEngine(address newMarginEngine, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(ICollateralVaultGov.setMarginEngine, (newMarginEngine));
        return queueOperation(collateralVault, 0, data, eta);
    }

    function queueVaultSetRiskModule(address newRiskModule, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(ICollateralVaultGov.setRiskModule, (newRiskModule));
        return queueOperation(collateralVault, 0, data, eta);
    }

    function queueVaultSetCollateralToken(
        address token,
        bool isSupported,
        uint8 decimals,
        uint16 collateralFactorBps,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(
            ICollateralVaultGov.setCollateralToken,
            (token, isSupported, decimals, collateralFactorBps)
        );
        return queueOperation(collateralVault, 0, data, eta);
    }

    function queueVaultSetTokenStrategy(address token, address adapter, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(ICollateralVaultGov.setTokenStrategy, (token, adapter));
        return queueOperation(collateralVault, 0, data, eta);
    }

    /*//////////////////////////////////////////////////////////////
                        INSURANCE FUND HELPERS
    //////////////////////////////////////////////////////////////*/

    function queueInsuranceSetOperator(address operator, bool allowed, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.setOperator, (operator, allowed));
        return queueOperation(insuranceFund, 0, data, eta);
    }

    function queueInsuranceSetTokenAllowed(address token, bool allowed, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.setTokenAllowed, (token, allowed));
        return queueOperation(insuranceFund, 0, data, eta);
    }
}