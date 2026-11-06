// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IRiskModule} from "../risk/IRiskModule.sol";
import {IOracle} from "../oracle/IOracle.sol";
import {OptionProductRegistry} from "../OptionProductRegistry.sol";

interface IOptionWithdrawalVault {
    function marginEngine() external view returns (address);
    function riskModule() external view returns (address);
}

interface IOptionWithdrawalEngineGate {
    function collateralVault() external view returns (address);
    function riskModule() external view returns (address);
    function optionRegistry() external view returns (address);
    function oracle() external view returns (address);
    function getTraderSeries(address trader) external view returns (uint256[] memory);
    function liquidationOracleMaxDelay() external view returns (uint32);
    function liquidationThresholdBps() external view returns (uint256);
}

interface IOptionWithdrawalRiskWiring {
    function collateralVault() external view returns (address);
    function marginEngine() external view returns (address);
    function optionRegistry() external view returns (address);
    function oracle() external view returns (address);
}

/// @notice Withdrawal-only adapter for the existing non-upgradeable Vault.
/// @dev The Vault calls getWithdrawableAmount by staticcall on its riskModule
///      pointer. MarginEngine and every other risk consumer keep the original
///      RiskModule. This adapter must be set as Vault.riskModule by governance.
///      It fails closed on stale wiring, oracle failure, or an unbounded account.
contract OptionWithdrawalRiskGate {
    error BadDependency();
    error WiringChanged();
    error TooManyOpenSeries();
    error UnsafeOracle();

    uint256 public constant MAX_OPEN_SERIES = 64;

    IOptionWithdrawalVault public immutable vault;
    IOptionWithdrawalEngineGate public immutable engine;
    IRiskModule public immutable originalRiskModule;
    OptionProductRegistry public immutable registry;
    IOracle public immutable oracle;

    constructor(address vault_, address engine_, address risk_, address registry_, address oracle_) {
        if (
            vault_ == address(0) || engine_ == address(0) || risk_ == address(0) || registry_ == address(0)
                || oracle_ == address(0)
        ) revert BadDependency();
        vault = IOptionWithdrawalVault(vault_);
        engine = IOptionWithdrawalEngineGate(engine_);
        originalRiskModule = IRiskModule(risk_);
        registry = OptionProductRegistry(registry_);
        oracle = IOracle(oracle_);
    }

    function getWithdrawableAmount(address trader, address token) external view returns (uint256) {
        if (
            vault.marginEngine() != address(engine) || vault.riskModule() != address(this)
                || engine.collateralVault() != address(vault) || engine.riskModule() != address(originalRiskModule)
                || engine.optionRegistry() != address(registry) || engine.oracle() != address(oracle)
        ) revert WiringChanged();
        IOptionWithdrawalRiskWiring risk = IOptionWithdrawalRiskWiring(address(originalRiskModule));
        if (
            risk.collateralVault() != address(vault) || risk.marginEngine() != address(engine)
                || risk.optionRegistry() != address(registry) || risk.oracle() != address(oracle)
        ) revert WiringChanged();

        uint256[] memory seriesIds = engine.getTraderSeries(trader);
        if (seriesIds.length > MAX_OPEN_SERIES) revert TooManyOpenSeries();
        if (seriesIds.length != 0) {
            uint32 maxDelay = engine.liquidationOracleMaxDelay();
            if (maxDelay == 0) revert UnsafeOracle();
            for (uint256 i = 0; i < seriesIds.length; i++) {
                OptionProductRegistry.OptionSeries memory series = registry.getSeries(seriesIds[i]);
                (uint256 price, uint256 updatedAt, bool ok) =
                    oracle.getPriceSafe(series.underlying, series.settlementAsset);
                if (
                    !ok || price == 0 || updatedAt == 0 || updatedAt > block.timestamp
                        || block.timestamp - updatedAt > maxDelay
                ) revert UnsafeOracle();
            }
        }

        uint256 maximum = originalRiskModule.getWithdrawableAmount(trader, token);
        if (maximum == 0) return 0;

        // The legacy Vault passes no requested amount to this hook. Preview
        // the maximum amount, and allow that bound only if the complete
        // withdrawal would preserve the account's liquidation threshold.
        IRiskModule.WithdrawPreview memory preview = originalRiskModule.previewWithdrawImpact(trader, token, maximum);
        if (
            preview.maxWithdrawable < maximum || preview.wouldBreachMargin
                || preview.marginRatioAfterBps < engine.liquidationThresholdBps()
        ) return 0;
        return maximum;
    }
}
