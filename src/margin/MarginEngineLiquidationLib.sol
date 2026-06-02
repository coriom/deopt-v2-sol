// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CollateralVault} from "../collateral/CollateralVault.sol";
import {IOracle} from "../oracle/IOracle.sol";

import {MarginEngineSeizureLib} from "./MarginEngineSeizureLib.sol";

/// @title MarginEngineLiquidationLib
/// @notice V2G-P size remediation: external library that hosts the cash-settlement +
///         base-seizure + cross-collateral-seizure block of
///         `MarginEngine.liquidate(...)`. Marking the function `external` makes
///         Solidity compile this as a separately-deployed library that the engine
///         calls via `DELEGATECALL`, which trims engine runtime bytecode under the
///         EIP-170 24,576-byte limit.
/// @dev
///  - Pure of engine storage: every dependency (`_collateralVault`, `_oracle`,
///    `baseCollateralToken`, `liquidationOracleMaxDelay`, `liquidationPenaltyBps`,
///    `baseMaintenanceMarginPerContract`) is passed in by the caller.
///  - Events are declared in the library so the DELEGATECALL surface re-emits them
///    under the engine's address — observers indexed by engine address still see
///    `LiquidationCashflow` and `LiquidationSeize` exactly as before.
///  - The function deduplicates the cash-settlement loop, the base-collateral
///    seizure, and the cross-collateral seizure loop without altering any fee math,
///    position accounting, margin logic, or collateral logic.  It only moves the
///    bytecode for the orchestration off the engine.
///  - Helpers (`_syncVaultBestEffort`, `_vaultCfg`, `_getOraclePriceChecked`) are
///    re-implemented locally so the library is fully self-contained.
library MarginEngineLiquidationLib {
    /// @dev Mirrors `MarginEngineStorage.BPS` so the body reads identically to the
    ///      pre-extraction engine code.  Library-local constants don't grow engine
    ///      runtime bytecode.
    uint256 internal constant BPS = 10_000;

    // Events — re-declared in the library; emitted via DELEGATECALL so the engine
    // address remains the emitter from the indexer's point of view.
    event LiquidationCashflow(
        address indexed liquidator, address indexed trader, address indexed asset, uint256 paid, uint256 requested
    );
    event LiquidationSeize(
        address indexed liquidator,
        address indexed trader,
        address indexed asset,
        uint256 seizedAmount,
        uint256 appliedBaseValue
    );

    error OraclePriceUnavailable();
    error OraclePriceStale();

    /// @notice V2G-P: extracted second half of `MarginEngine.liquidate(...)`.
    ///         Settles cashflow on each touched option's settlement asset, then
    ///         seizes the configured liquidation penalty in base collateral
    ///         first and any other supported collateral after that.
    ///
    /// @dev    The caller (`MarginEngine.liquidate`) computes:
    ///          - `cashAssets[]`, `cashRequested[]`, `assetsCount` — the
    ///            per-asset cash settlement bundle from the option-loop.
    ///          - `totalContractsClosed` — used to compute the penalty cap.
    ///         The caller already did the trader-side risk pre-check and the
    ///         per-option position writes; this function only moves vault
    ///         balances and emits the corresponding events.
    ///
    /// @return seizedBaseTotal Total base-collateral-denominated value seized
    ///         from the trader across the base-token seizure and the
    ///         cross-collateral fallback loop.  The caller uses this in the
    ///         final `Liquidation` event.
    function settleCashAndSeize(
        address liquidator,
        address trader,
        address[] memory cashAssets,
        uint256[] memory cashRequested,
        uint256 assetsCount,
        uint256 totalContractsClosed,
        uint256 baseMaintenanceMarginPerContract,
        uint256 liquidationPenaltyBps,
        address baseCollateralToken,
        CollateralVault collateralVault,
        IOracle oracle,
        uint32 liquidationOracleMaxDelay
    ) external returns (uint256 seizedBaseTotal) {
        // Cash settlement leg — one transfer per option's settlement asset.
        for (uint256 i = 0; i < assetsCount; i++) {
            address asset = cashAssets[i];
            uint256 req = cashRequested[i];
            if (req == 0) continue;

            _syncVaultBestEffort(collateralVault, trader, asset);

            uint256 traderBal = collateralVault.balances(trader, asset);
            uint256 paid = req <= traderBal ? req : traderBal;

            if (paid > 0) {
                collateralVault.transferBetweenAccounts(asset, trader, liquidator, paid);
            }

            emit LiquidationCashflow(liquidator, trader, asset, paid, req);
        }

        // Penalty seizure — base collateral first, then fall through cross-asset.
        uint256 mmBase = baseMaintenanceMarginPerContract * totalContractsClosed;
        uint256 penaltyBase = Math.mulDiv(mmBase, liquidationPenaltyBps, BPS, Math.Rounding.Floor);

        uint256 remainingBase = penaltyBase;

        if (remainingBase > 0) {
            _syncVaultBestEffort(collateralVault, trader, baseCollateralToken);

            uint256 balBase = collateralVault.balances(trader, baseCollateralToken);
            uint256 seizeBaseTokenAmt = remainingBase <= balBase ? remainingBase : balBase;

            if (seizeBaseTokenAmt > 0) {
                collateralVault.transferBetweenAccounts(baseCollateralToken, trader, liquidator, seizeBaseTokenAmt);
                seizedBaseTotal += seizeBaseTokenAmt;
                remainingBase -= seizeBaseTokenAmt;

                emit LiquidationSeize(liquidator, trader, baseCollateralToken, seizeBaseTokenAmt, seizeBaseTokenAmt);
            }
        }

        if (remainingBase > 0) {
            for (uint256 i = 0; i < assetsCount; i++) {
                if (remainingBase == 0) break;

                address tok = cashAssets[i];
                if (tok == address(0) || tok == baseCollateralToken) continue;

                CollateralVault.CollateralTokenConfig memory cfg = collateralVault.getCollateralConfig(tok);
                if (!cfg.isSupported || cfg.decimals == 0) continue;

                _syncVaultBestEffort(collateralVault, trader, tok);

                (uint256 neededTok, bool ok) = MarginEngineSeizureLib.baseValueToTokenAmountUp(
                    tok, remainingBase, baseCollateralToken, collateralVault, oracle, liquidationOracleMaxDelay
                );
                if (!ok || neededTok == 0) continue;

                uint256 balTok = collateralVault.balances(trader, tok);
                uint256 seizeTok = neededTok <= balTok ? neededTok : balTok;
                if (seizeTok == 0) continue;

                uint256 pxTokBase = _getOraclePriceChecked(oracle, tok, baseCollateralToken, liquidationOracleMaxDelay);
                uint256 seizedBaseApprox = MarginEngineSeizureLib.tokenAmountToBaseValueDown(
                    tok, seizeTok, pxTokBase, baseCollateralToken, collateralVault
                );

                collateralVault.transferBetweenAccounts(tok, trader, liquidator, seizeTok);

                uint256 applied = seizedBaseApprox <= remainingBase ? seizedBaseApprox : remainingBase;
                seizedBaseTotal += applied;
                remainingBase -= applied;

                emit LiquidationSeize(liquidator, trader, tok, seizeTok, applied);
            }
        }
    }

    /// @dev Local mirror of `MarginEngineStorage._syncVaultBestEffort`. The vault
    ///      may or may not implement `syncAccountFor` (depending on its version);
    ///      we soft-call so a missing selector is a no-op, matching the engine.
    function _syncVaultBestEffort(CollateralVault collateralVault, address user, address token) private {
        (bool ok,) =
            address(collateralVault).call(abi.encodeWithSignature("syncAccountFor(address,address)", user, token));
        ok;
    }

    /// @dev Local mirror of `MarginEngineStorage._getOraclePriceChecked`. Reads the
    ///      oracle and applies the same staleness gate the engine applies on the
    ///      liquidation hot path.
    function _getOraclePriceChecked(IOracle oracle, address base, address quote, uint32 maxDelay)
        private
        view
        returns (uint256 p)
    {
        (uint256 px, uint256 updatedAt) = oracle.getPrice(base, quote);
        if (px == 0) revert OraclePriceUnavailable();

        if (maxDelay > 0) {
            if (updatedAt == 0) revert OraclePriceStale();
            if (updatedAt > block.timestamp) revert OraclePriceStale();
            if (block.timestamp - updatedAt > maxDelay) revert OraclePriceStale();
        }
        return px;
    }
}
