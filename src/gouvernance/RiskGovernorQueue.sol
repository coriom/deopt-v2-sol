// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./RiskGovernorAdmin.sol";

abstract contract RiskGovernorQueue is RiskGovernorAdmin {
    /*//////////////////////////////////////////////////////////////
                            GENERIC TIMELOCK WRAPPERS
    //////////////////////////////////////////////////////////////*/

    function hashOperation(address target, uint256 value, bytes memory data, uint256 eta)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(target, value, data, eta));
    }

    function getQueuedOperation(bytes32 txHash)
        external
        view
        returns (
            address target,
            uint256 value,
            uint256 eta,
            bytes memory data,
            OperationState state
        )
    {
        QueuedOperation memory op = _getQueuedOperation(txHash);
        return (op.target, op.value, op.eta, op.data, op.state);
    }

    function queueOperation(address target, uint256 value, bytes memory data, uint256 eta)
        public
        onlyOwner
        returns (bytes32 txHash)
    {
        _validateTarget(target);

        txHash = timelock.queueTransaction(target, value, data, eta);
        _storeQueuedOperation(txHash, target, value, eta, data);

        emit OperationQueued(txHash, target, value, eta, data);
    }

    function cancelOperation(address target, uint256 value, bytes memory data, uint256 eta)
        public
        onlyGuardianOrOwner
        returns (bytes32 txHash)
    {
        _validateTarget(target);

        txHash = timelock.cancelTransaction(target, value, data, eta);
        _markOperationCancelled(txHash);

        emit OperationCancelled(txHash, target, value, eta, data);
    }

    function executeOperation(address target, uint256 value, bytes memory data, uint256 eta)
        public
        payable
        onlyOwner
        returns (bytes memory returnData)
    {
        _validateTarget(target);
        if (msg.value != value) revert TimelockValueMismatch();

        bytes32 txHash = keccak256(abi.encode(target, value, data, eta));
        returnData = timelock.executeTransaction{value: value}(target, value, data, eta);
        _markOperationExecuted(txHash);

        emit OperationExecuted(txHash, target, value, eta, data);
    }

    /*//////////////////////////////////////////////////////////////
                            RISK MODULE HELPERS
    //////////////////////////////////////////////////////////////*/

    function queueRiskModuleSetGuardian(address newGuardian, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.setGuardian, (newGuardian));
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModuleClearGuardian(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.clearGuardian, ());
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModulePause(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.pause, ());
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModuleUnpause(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.unpause, ());
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModulePauseRiskChecks(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.pauseRiskChecks, ());
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModuleUnpauseRiskChecks(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.unpauseRiskChecks, ());
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModulePauseCollateralValuation(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.pauseCollateralValuation, ());
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModuleUnpauseCollateralValuation(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.unpauseCollateralValuation, ());
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModulePauseWithdrawPreviews(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.pauseWithdrawPreviews, ());
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModuleUnpauseWithdrawPreviews(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.unpauseWithdrawPreviews, ());
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModuleSetEmergencyModes(
        bool riskChecksPaused_,
        bool collateralValuationPaused_,
        bool withdrawPreviewPaused_,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(
            IRiskModuleGov.setEmergencyModes,
            (riskChecksPaused_, collateralValuationPaused_, withdrawPreviewPaused_)
        );
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModuleClearEmergencyModes(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.clearEmergencyModes, ());
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModuleSetRiskParams(
        address baseToken,
        uint256 baseMMPerContract,
        uint256 imFactorBps,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.setRiskParams, (baseToken, baseMMPerContract, imFactorBps));
        return queueOperation(riskModule, 0, data, eta);
    }

    function queueRiskModuleSetCollateralConfig(address token, uint64 weightBps, bool isEnabled, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(IRiskModuleGov.setCollateralConfig, (token, weightBps, isEnabled));
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

    function queueRiskModuleSyncCollateralTokensFromVault(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IRiskModuleGov.syncCollateralTokensFromVault, ());
        return queueOperation(riskModule, 0, data, eta);
    }

    /*//////////////////////////////////////////////////////////////
                        MARGIN ENGINE HELPERS
    //////////////////////////////////////////////////////////////*/

    function queueMarginSetGuardian(address newGuardian, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.setGuardian, (newGuardian));
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginClearGuardian(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.clearGuardian, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginPause(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.pause, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginUnpause(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.unpause, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginPauseTrading(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.pauseTrading, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginUnpauseTrading(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.unpauseTrading, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginPauseLiquidation(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.pauseLiquidation, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginUnpauseLiquidation(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.unpauseLiquidation, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginPauseSettlement(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.pauseSettlement, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginUnpauseSettlement(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.unpauseSettlement, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginPauseCollateralOps(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.pauseCollateralOps, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginUnpauseCollateralOps(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.unpauseCollateralOps, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetEmergencyModes(
        bool tradingPaused_,
        bool liquidationPaused_,
        bool settlementPaused_,
        bool collateralOpsPaused_,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(
            IMarginEngineGov.setEmergencyModes,
            (tradingPaused_, liquidationPaused_, settlementPaused_, collateralOpsPaused_)
        );
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginClearEmergencyModes(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.clearEmergencyModes, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetMatchingEngine(address newMatchingEngine, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.setMatchingEngine, (newMatchingEngine));
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginClearMatchingEngine(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.clearMatchingEngine, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetOracle(address newOracle, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.setOracle, (newOracle));
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetRiskModule(address newRiskModule, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.setRiskModule, (newRiskModule));
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginClearRiskModule(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.clearRiskModule, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetInsuranceFund(address newInsuranceFund, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.setInsuranceFund, (newInsuranceFund));
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginClearInsuranceFund(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.clearInsuranceFund, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetFeesManager(address newFeesManager, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.setFeesManager, (newFeesManager));
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginClearFeesManager(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.clearFeesManager, ());
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
        bytes memory data = abi.encodeCall(IMarginEngineGov.setRiskParams, (baseToken, baseMMPerContract, imFactorBps));
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSyncRiskParamsFromRiskModule(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IMarginEngineGov.syncRiskParamsFromRiskModule, ());
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetLiquidationParams(
        uint256 liquidationThresholdBps,
        uint256 liquidationPenaltyBps,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data =
            abi.encodeCall(IMarginEngineGov.setLiquidationParams, (liquidationThresholdBps, liquidationPenaltyBps));
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetLiquidationHardenParams(uint256 closeFactorBps, uint256 minImprovementBps, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data =
            abi.encodeCall(IMarginEngineGov.setLiquidationHardenParams, (closeFactorBps, minImprovementBps));
        return queueOperation(marginEngine, 0, data, eta);
    }

    function queueMarginSetLiquidationPricingParams(
        uint256 liquidationPriceSpreadBps,
        uint256 minLiqPriceBpsOfIntrinsic,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(
            IMarginEngineGov.setLiquidationPricingParams, (liquidationPriceSpreadBps, minLiqPriceBpsOfIntrinsic)
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

    function queueOracleSetGuardian(address newGuardian, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOracleRouterGov.setGuardian, (newGuardian));
        return queueOperation(oracleRouter, 0, data, eta);
    }

    function queueOracleClearGuardian(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOracleRouterGov.clearGuardian, ());
        return queueOperation(oracleRouter, 0, data, eta);
    }

    function queueOraclePause(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOracleRouterGov.pause, ());
        return queueOperation(oracleRouter, 0, data, eta);
    }

    function queueOracleUnpause(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOracleRouterGov.unpause, ());
        return queueOperation(oracleRouter, 0, data, eta);
    }

    function queueOraclePauseReads(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOracleRouterGov.pauseReads, ());
        return queueOperation(oracleRouter, 0, data, eta);
    }

    function queueOracleUnpauseReads(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOracleRouterGov.unpauseReads, ());
        return queueOperation(oracleRouter, 0, data, eta);
    }

    function queueOraclePauseConfig(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOracleRouterGov.pauseConfig, ());
        return queueOperation(oracleRouter, 0, data, eta);
    }

    function queueOracleUnpauseConfig(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOracleRouterGov.unpauseConfig, ());
        return queueOperation(oracleRouter, 0, data, eta);
    }

    function queueOracleSetEmergencyModes(bool readPaused_, bool configPaused_, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(IOracleRouterGov.setEmergencyModes, (readPaused_, configPaused_));
        return queueOperation(oracleRouter, 0, data, eta);
    }

    function queueOracleClearEmergencyModes(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IOracleRouterGov.clearEmergencyModes, ());
        return queueOperation(oracleRouter, 0, data, eta);
    }

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

    function queueOracleSetFeedStatus(address baseAsset, address quoteAsset, bool isActive, uint256 eta)
        external
        returns (bytes32)
    {
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

    function queueFeesSetGuardian(address newGuardian, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IFeesManagerGov.setGuardian, (newGuardian));
        return queueOperation(feesManager, 0, data, eta);
    }

    function queueFeesClearGuardian(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IFeesManagerGov.clearGuardian, ());
        return queueOperation(feesManager, 0, data, eta);
    }

    function queueFeesPause(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IFeesManagerGov.pause, ());
        return queueOperation(feesManager, 0, data, eta);
    }

    function queueFeesUnpause(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IFeesManagerGov.unpause, ());
        return queueOperation(feesManager, 0, data, eta);
    }

    function queueFeesPauseConfig(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IFeesManagerGov.pauseConfig, ());
        return queueOperation(feesManager, 0, data, eta);
    }

    function queueFeesUnpauseConfig(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IFeesManagerGov.unpauseConfig, ());
        return queueOperation(feesManager, 0, data, eta);
    }

    function queueFeesPauseClaims(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IFeesManagerGov.pauseClaims, ());
        return queueOperation(feesManager, 0, data, eta);
    }

    function queueFeesUnpauseClaims(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IFeesManagerGov.unpauseClaims, ());
        return queueOperation(feesManager, 0, data, eta);
    }

    function queueFeesSetEmergencyModes(bool configPaused_, bool claimsPaused_, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(IFeesManagerGov.setEmergencyModes, (configPaused_, claimsPaused_));
        return queueOperation(feesManager, 0, data, eta);
    }

    function queueFeesClearEmergencyModes(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IFeesManagerGov.clearEmergencyModes, ());
        return queueOperation(feesManager, 0, data, eta);
    }

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

    function queueFeesSetMerkleRootWithEpoch(bytes32 newRoot, uint64 newEpoch, uint256 eta)
        external
        returns (bytes32)
    {
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
        bytes memory data =
            abi.encodeCall(ICollateralVaultGov.setCollateralToken, (token, isSupported, decimals, collateralFactorBps));
        return queueOperation(collateralVault, 0, data, eta);
    }

    function queueVaultSetTokenStrategy(address token, address adapter, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(ICollateralVaultGov.setTokenStrategy, (token, adapter));
        return queueOperation(collateralVault, 0, data, eta);
    }

    /*//////////////////////////////////////////////////////////////
                        INSURANCE FUND HELPERS
    //////////////////////////////////////////////////////////////*/

    function queueInsuranceSetGuardian(address newGuardian, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.setGuardian, (newGuardian));
        return queueOperation(insuranceFund, 0, data, eta);
    }

    function queueInsuranceClearGuardian(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.clearGuardian, ());
        return queueOperation(insuranceFund, 0, data, eta);
    }

    function queueInsurancePause(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.pause, ());
        return queueOperation(insuranceFund, 0, data, eta);
    }

    function queueInsuranceUnpause(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.unpause, ());
        return queueOperation(insuranceFund, 0, data, eta);
    }

    function queueInsurancePauseFunding(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.pauseFunding, ());
        return queueOperation(insuranceFund, 0, data, eta);
    }

    function queueInsuranceUnpauseFunding(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.unpauseFunding, ());
        return queueOperation(insuranceFund, 0, data, eta);
    }

    function queueInsurancePauseWithdraws(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.pauseWithdraws, ());
        return queueOperation(insuranceFund, 0, data, eta);
    }

    function queueInsuranceUnpauseWithdraws(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.unpauseWithdraws, ());
        return queueOperation(insuranceFund, 0, data, eta);
    }

    function queueInsurancePauseYieldOps(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.pauseYieldOps, ());
        return queueOperation(insuranceFund, 0, data, eta);
    }

    function queueInsuranceUnpauseYieldOps(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.unpauseYieldOps, ());
        return queueOperation(insuranceFund, 0, data, eta);
    }

    function queueInsuranceSetEmergencyModes(
        bool fundingPaused_,
        bool withdrawPaused_,
        bool yieldOpsPaused_,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data =
            abi.encodeCall(IInsuranceFundGov.setEmergencyModes, (fundingPaused_, withdrawPaused_, yieldOpsPaused_));
        return queueOperation(insuranceFund, 0, data, eta);
    }

    function queueInsuranceClearEmergencyModes(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.clearEmergencyModes, ());
        return queueOperation(insuranceFund, 0, data, eta);
    }

    function queueInsuranceSetOperator(address operator, bool allowed, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.setOperator, (operator, allowed));
        return queueOperation(insuranceFund, 0, data, eta);
    }

    function queueInsuranceSetTokenAllowed(address token, bool allowed, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.setTokenAllowed, (token, allowed));
        return queueOperation(insuranceFund, 0, data, eta);
    }

    function queueInsuranceSetBackstopCaller(address caller, bool allowed, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.setBackstopCaller, (caller, allowed));
        return queueOperation(insuranceFund, 0, data, eta);
    }

    /*//////////////////////////////////////////////////////////////
                        PERP MARKET REGISTRY HELPERS
    //////////////////////////////////////////////////////////////*/

    function queuePerpRegistrySetGuardian(address newGuardian, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpMarketRegistryGov.setGuardian, (newGuardian));
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    function queuePerpRegistryClearGuardian(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpMarketRegistryGov.clearGuardian, ());
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    function queuePerpRegistryPause(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpMarketRegistryGov.pause, ());
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    function queuePerpRegistryUnpause(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpMarketRegistryGov.unpause, ());
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    function queuePerpRegistryPauseCreation(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpMarketRegistryGov.pauseCreation, ());
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    function queuePerpRegistryUnpauseCreation(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpMarketRegistryGov.unpauseCreation, ());
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    function queuePerpRegistryPauseConfig(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpMarketRegistryGov.pauseConfig, ());
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    function queuePerpRegistryUnpauseConfig(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpMarketRegistryGov.unpauseConfig, ());
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    function queuePerpRegistrySetEmergencyModes(bool creationPaused_, bool configPaused_, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data =
            abi.encodeCall(IPerpMarketRegistryGov.setEmergencyModes, (creationPaused_, configPaused_));
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    function queuePerpRegistryClearEmergencyModes(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpMarketRegistryGov.clearEmergencyModes, ());
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    function queuePerpRegistrySetMarketCreator(address account, bool allowed, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(IPerpMarketRegistryGov.setMarketCreator, (account, allowed));
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    function queuePerpRegistrySetSettlementAssetAllowed(address asset, bool allowed, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(IPerpMarketRegistryGov.setSettlementAssetAllowed, (asset, allowed));
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    function queuePerpRegistrySetMarketOracle(uint256 marketId, address oracle_, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(IPerpMarketRegistryGov.setMarketOracle, (marketId, oracle_));
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    function queuePerpRegistrySetMarketStatus(uint256 marketId, bool isActive, bool isCloseOnly, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(IPerpMarketRegistryGov.setMarketStatus, (marketId, isActive, isCloseOnly));
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    function queuePerpRegistrySetRiskConfig(
        uint256 marketId,
        uint32 initialMarginBps,
        uint32 maintenanceMarginBps,
        uint32 liquidationPenaltyBps,
        uint128 maxPositionSize1e8,
        uint128 maxOpenInterest1e8,
        bool reduceOnlyDuringCloseOnly,
        uint256 eta
    ) external returns (bytes32) {
        IPerpMarketRegistryGov.RiskConfig memory cfg = IPerpMarketRegistryGov.RiskConfig({
            initialMarginBps: initialMarginBps,
            maintenanceMarginBps: maintenanceMarginBps,
            liquidationPenaltyBps: liquidationPenaltyBps,
            maxPositionSize1e8: maxPositionSize1e8,
            maxOpenInterest1e8: maxOpenInterest1e8,
            reduceOnlyDuringCloseOnly: reduceOnlyDuringCloseOnly
        });

        bytes memory data = abi.encodeCall(IPerpMarketRegistryGov.setRiskConfig, (marketId, cfg));
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    function queuePerpRegistrySetFundingConfig(
        uint256 marketId,
        bool isEnabled,
        uint32 fundingInterval,
        uint32 maxFundingRateBps,
        uint32 maxSkewFundingBps,
        uint32 oracleClampBps,
        uint256 eta
    ) external returns (bytes32) {
        IPerpMarketRegistryGov.FundingConfig memory cfg = IPerpMarketRegistryGov.FundingConfig({
            isEnabled: isEnabled,
            fundingInterval: fundingInterval,
            maxFundingRateBps: maxFundingRateBps,
            maxSkewFundingBps: maxSkewFundingBps,
            oracleClampBps: oracleClampBps
        });

        bytes memory data = abi.encodeCall(IPerpMarketRegistryGov.setFundingConfig, (marketId, cfg));
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    function queuePerpRegistrySetMarketMetadata(uint256 marketId, bytes32 metadata, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(IPerpMarketRegistryGov.setMarketMetadata, (marketId, metadata));
        return queueOperation(perpMarketRegistry, 0, data, eta);
    }

    /*//////////////////////////////////////////////////////////////
                            PERP ENGINE HELPERS
    //////////////////////////////////////////////////////////////*/

    function queuePerpEngineSetGuardian(address newGuardian, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.setGuardian, (newGuardian));
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineClearGuardian(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.clearGuardian, ());
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEnginePause(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.pause, ());
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineUnpause(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.unpause, ());
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEnginePauseTrading(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.pauseTrading, ());
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineUnpauseTrading(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.unpauseTrading, ());
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEnginePauseLiquidation(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.pauseLiquidation, ());
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineUnpauseLiquidation(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.unpauseLiquidation, ());
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEnginePauseFunding(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.pauseFunding, ());
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineUnpauseFunding(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.unpauseFunding, ());
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEnginePauseCollateralOps(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.pauseCollateralOps, ());
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineUnpauseCollateralOps(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.unpauseCollateralOps, ());
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineSetEmergencyModes(
        bool tradingPaused_,
        bool liquidationPaused_,
        bool fundingPaused_,
        bool collateralOpsPaused_,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(
            IPerpEngineGov.setEmergencyModes,
            (tradingPaused_, liquidationPaused_, fundingPaused_, collateralOpsPaused_)
        );
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineClearEmergencyModes(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.clearEmergencyModes, ());
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineSetMatchingEngine(address matchingEngine_, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.setMatchingEngine, (matchingEngine_));
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineSetOracle(address oracle_, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.setOracle, (oracle_));
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineSetRiskModule(address riskModule_, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.setRiskModule, (riskModule_));
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineSetCollateralSeizer(address collateralSeizer_, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.setCollateralSeizer, (collateralSeizer_));
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineClearCollateralSeizer(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.clearCollateralSeizer, ());
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineSetInsuranceFund(address insuranceFund_, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.setInsuranceFund, (insuranceFund_));
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineClearInsuranceFund(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.clearInsuranceFund, ());
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineSetFeesManager(address feesManager_, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.setFeesManager, (feesManager_));
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineClearFeesManager(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.clearFeesManager, ());
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineSetFeeRecipient(address feeRecipient_, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.setFeeRecipient, (feeRecipient_));
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineClearFeeRecipient(uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.clearFeeRecipient, ());
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineSetMarketRegistry(address registry_, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.setMarketRegistry, (registry_));
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineSetCollateralVault(address vault_, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.setCollateralVault, (vault_));
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineSetLiquidationParams(
        uint256 liquidationCloseFactorBps_,
        uint256 liquidationPenaltyBps_,
        uint256 liquidationPriceSpreadBps_,
        uint256 minLiquidationImprovementBps_,
        uint256 eta
    ) external returns (bytes32) {
        bytes memory data = abi.encodeCall(
            IPerpEngineGov.setLiquidationParams,
            (
                liquidationCloseFactorBps_,
                liquidationPenaltyBps_,
                liquidationPriceSpreadBps_,
                minLiquidationImprovementBps_
            )
        );
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineSetLiquidationCloseFactorBps(uint256 newCloseFactorBps, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(IPerpEngineGov.setLiquidationCloseFactorBps, (newCloseFactorBps));
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineSetLiquidationPenaltyBps(uint256 newPenaltyBps, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(IPerpEngineGov.setLiquidationPenaltyBps, (newPenaltyBps));
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineSetLiquidationPriceSpreadBps(uint256 newSpreadBps, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(IPerpEngineGov.setLiquidationPriceSpreadBps, (newSpreadBps));
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineSetMinLiquidationImprovementBps(uint256 newMinImprovementBps, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(IPerpEngineGov.setMinLiquidationImprovementBps, (newMinImprovementBps));
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineRecordResidualBadDebt(address trader, uint256 amountBase, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(IPerpEngineGov.recordResidualBadDebt, (trader, amountBase));
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineReduceResidualBadDebt(address trader, uint256 amountBase, uint256 eta)
        external
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(IPerpEngineGov.reduceResidualBadDebt, (trader, amountBase));
        return queueOperation(perpEngine, 0, data, eta);
    }

    function queuePerpEngineClearResidualBadDebt(address trader, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IPerpEngineGov.clearResidualBadDebt, (trader));
        return queueOperation(perpEngine, 0, data, eta);
    }
}