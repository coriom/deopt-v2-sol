// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./RiskGovernorAdmin.sol";

abstract contract RiskGovernorQueue is RiskGovernorAdmin {
    /*//////////////////////////////////////////////////////////////
                            GENERIC TIMELOCK WRAPPERS
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
        if (target == address(0)) revert ZeroAddress();

        txHash = timelock.queueTransaction(target, value, data, eta);
        emit OperationQueued(txHash, target, value, eta, data);
    }

    function cancelOperation(address target, uint256 value, bytes calldata data, uint256 eta)
        public
        onlyGuardianOrOwner
        returns (bytes32 txHash)
    {
        if (target == address(0)) revert ZeroAddress();

        txHash = timelock.cancelTransaction(target, value, data, eta);
        emit OperationCancelled(txHash, target, value, eta, data);
    }

    function executeOperation(address target, uint256 value, bytes calldata data, uint256 eta)
        public
        payable
        onlyOwner
        returns (bytes memory returnData)
    {
        if (target == address(0)) revert ZeroAddress();
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
        bytes memory data = abi.encodeCall(IMarginEngineGov.setRiskParams, (baseToken, baseMMPerContract, imFactorBps));
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

    function queueInsuranceSetOperator(address operator, bool allowed, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.setOperator, (operator, allowed));
        return queueOperation(insuranceFund, 0, data, eta);
    }

    function queueInsuranceSetTokenAllowed(address token, bool allowed, uint256 eta) external returns (bytes32) {
        bytes memory data = abi.encodeCall(IInsuranceFundGov.setTokenAllowed, (token, allowed));
        return queueOperation(insuranceFund, 0, data, eta);
    }
}