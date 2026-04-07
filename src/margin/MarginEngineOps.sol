// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {OptionProductRegistry} from "../OptionProductRegistry.sol";
import {CollateralVault} from "../collateral/CollateralVault.sol";
import {IRiskModule} from "../risk/IRiskModule.sol";
import {IMarginEngineState} from "../risk/IMarginEngineState.sol";

import {MarginEngineViews} from "./MarginEngineViews.sol";

/// @title MarginEngineOps
/// @notice Stateful collateral / settlement / liquidation layer for the options engine.
/// @dev
///  Responsibilities:
///   - user collateral wrappers
///   - option settlement accounting
///   - options liquidation flow
///
///  Architectural note:
///   - read surfaces now live in MarginEngineViews
///   - this layer should remain focused on state-changing logic
///
///  Canonical conventions:
///   - risk amounts suffixed `Base` are denominated in native units of the protocol base collateral token
///   - settlement accounting amounts are denominated in settlement-asset native units
///   - `shortfall` is transient during an operation
///   - `badDebt` is the final residual uncovered amount recorded by the protocol
///
///  Settlement design:
///   - collections from losing shorts are routed to a settlement sink
///   - longs are paid first from the settlement sink
///   - if needed, insurance fund tops up the remaining shortfall
///   - any residual uncovered remainder becomes explicit series bad debt
abstract contract MarginEngineOps is MarginEngineViews {
    /*//////////////////////////////////////////////////////////////
                        USER COLLATERAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Correct deposit path via CollateralVault.depositFor(user, token, amount).
    ///      If not implemented in CollateralVault => revert.
    function depositCollateral(address token, uint256 amount) external whenCollateralOpsNotPaused nonReentrant {
        if (amount == 0) revert AmountZero();

        (bool ok,) = address(_collateralVault).call(
            abi.encodeWithSignature("depositFor(address,address,uint256)", msg.sender, token, amount)
        );
        if (!ok) revert VaultDepositForNotSupported();

        emit CollateralDeposited(msg.sender, token, amount);
    }

    /// @dev IMPORTANT: never call collateralVault.withdraw() here (msg.sender = MarginEngine).
    ///      Force withdrawFor(user, token, amount). If unsupported => revert.
    function withdrawCollateral(address token, uint256 amount) external whenCollateralOpsNotPaused nonReentrant {
        if (address(_riskModule) == address(0)) revert RiskModuleNotSet();
        if (amount == 0) revert AmountZero();

        IRiskModule.WithdrawPreview memory preview = _riskModule.previewWithdrawImpact(msg.sender, token, amount);

        if (amount > preview.maxWithdrawable) revert WithdrawTooLarge();
        if (preview.marginRatioAfterBps < liquidationThresholdBps) revert WithdrawWouldBreachMargin();

        (bool ok,) = address(_collateralVault).call(
            abi.encodeWithSignature("withdrawFor(address,address,uint256)", msg.sender, token, amount)
        );
        if (!ok) revert VaultWithdrawForNotSupported();

        emit CollateralWithdrawn(msg.sender, token, amount, preview.marginRatioAfterBps);
    }

    /*//////////////////////////////////////////////////////////////
                    PAYOFF & PnL HELPERS (SETTLEMENT)
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns settlement-native units per contract.
    function _computePerContractPayoff(OptionProductRegistry.OptionSeries memory series, uint256 settlementPrice)
        internal
        view
        returns (uint256 payoffPerContract)
    {
        _requireStandardContractSize(series);
        if (settlementPrice == 0) return 0;

        uint256 intrinsicPrice1e8;
        if (series.isCall) {
            intrinsicPrice1e8 =
                settlementPrice > uint256(series.strike) ? (settlementPrice - uint256(series.strike)) : 0;
        } else {
            intrinsicPrice1e8 =
                uint256(series.strike) > settlementPrice ? (uint256(series.strike) - settlementPrice) : 0;
        }

        if (intrinsicPrice1e8 == 0) return 0;
        payoffPerContract = _price1e8ToSettlementUnits(series.settlementAsset, intrinsicPrice1e8);
    }

    /// @dev Canonical settlement sink.
    ///      Priority:
    ///       1) insuranceFund when configured
    ///       2) MarginEngine itself as internal sink / pooled settlement account
    function _settlementSink() internal view returns (address sink) {
        sink = insuranceFund;
        if (sink == address(0)) sink = address(this);
    }

    function _collectFromTraderUpTo(address trader, address toAccount, address asset, uint256 requestedAmount)
        internal
        returns (uint256 collected)
    {
        if (requestedAmount == 0) return 0;

        _syncVaultBestEffort(trader, asset);
        if (toAccount != address(this) && toAccount != trader) {
            _syncVaultBestEffort(toAccount, asset);
        }

        uint256 traderBal = _collateralVault.balances(trader, asset);
        collected = traderBal >= requestedAmount ? requestedAmount : traderBal;

        if (collected > 0) {
            _collateralVault.transferBetweenAccounts(asset, trader, toAccount, collected);
        }
    }

    /// @dev Pays from a settlement pool/sink already holding funds.
    function _payFromSettlementSinkUpTo(address asset, address fromAccount, address toAccount, uint256 requestedAmount)
        internal
        returns (uint256 paid)
    {
        if (requestedAmount == 0) return 0;

        _syncVaultBestEffort(fromAccount, asset);
        if (toAccount != fromAccount) {
            _syncVaultBestEffort(toAccount, asset);
        }

        uint256 fromBal = _collateralVault.balances(fromAccount, asset);
        paid = fromBal >= requestedAmount ? requestedAmount : fromBal;

        if (paid > 0) {
            _collateralVault.transferBetweenAccounts(asset, fromAccount, toAccount, paid);
        }
    }

    function _payFromInsuranceFundUpTo(address asset, address toAccount, uint256 requestedAmount)
        internal
        returns (uint256 paid)
    {
        if (requestedAmount == 0) return 0;
        if (insuranceFund == address(0)) return 0;

        _syncVaultBestEffort(insuranceFund, asset);

        (bool ok, bytes memory data) = insuranceFund.call(
            abi.encodeWithSignature("coverVaultShortfall(address,address,uint256)", asset, toAccount, requestedAmount)
        );

        if (ok && data.length >= 32) {
            paid = abi.decode(data, (uint256));
            if (paid > requestedAmount) paid = requestedAmount;
            return paid;
        }

        uint256 fundBal = _collateralVault.balances(insuranceFund, asset);
        paid = fundBal >= requestedAmount ? requestedAmount : fundBal;

        if (paid > 0) {
            _collateralVault.transferBetweenAccounts(asset, insuranceFund, toAccount, paid);
        }
    }

    function _recordSeriesSettlementAccounting(
        uint256 optionId,
        uint256 collectedFromTrader,
        uint256 paidToTrader,
        uint256 badDebt
    ) internal {
        if (collectedFromTrader > 0) {
            seriesCollected[optionId] = _addChecked(seriesCollected[optionId], collectedFromTrader);
        }

        if (paidToTrader > 0) {
            seriesPaid[optionId] = _addChecked(seriesPaid[optionId], paidToTrader);
        }

        if (badDebt > 0) {
            seriesBadDebt[optionId] = _addChecked(seriesBadDebt[optionId], badDebt);
        }

        emit SeriesSettlementAccountingUpdated(
            optionId,
            seriesCollected[optionId],
            seriesPaid[optionId],
            seriesBadDebt[optionId]
        );
    }

    /// @dev Settlement hierarchy for a winning long:
    ///      1) settlement sink
    ///      2) insurance fund top-up if sink != insuranceFund
    ///      3) residual becomes bad debt
    function _resolveLongSettlementPayout(address settlementAsset, address trader, uint256 amountDue)
        internal
        returns (uint256 paidToTrader, uint256 badDebt)
    {
        if (amountDue == 0) return (0, 0);

        address sink = _settlementSink();

        paidToTrader = _payFromSettlementSinkUpTo(settlementAsset, sink, trader, amountDue);

        if (paidToTrader < amountDue && insuranceFund != address(0) && sink != insuranceFund) {
            uint256 remaining = amountDue - paidToTrader;
            uint256 insurancePaid = _payFromInsuranceFundUpTo(settlementAsset, trader, remaining);
            paidToTrader = _addChecked(paidToTrader, insurancePaid);
        }

        if (paidToTrader < amountDue) {
            badDebt = amountDue - paidToTrader;
        }
    }

    /// @dev Settlement hierarchy for a losing short:
    ///      1) collect what can actually be taken from trader
    ///      2) residual uncollectable remainder becomes bad debt
    function _resolveShortSettlementCollection(address settlementAsset, address trader, uint256 amountOwed)
        internal
        returns (uint256 collectedFromTrader, uint256 badDebt)
    {
        if (amountOwed == 0) return (0, 0);

        address sink = _settlementSink();
        collectedFromTrader = _collectFromTraderUpTo(trader, sink, settlementAsset, amountOwed);

        if (collectedFromTrader < amountOwed) {
            badDebt = amountOwed - collectedFromTrader;
        }
    }

    function _settleAccount(uint256 optionId, address trader) internal {
        if (trader == address(0)) revert ZeroAddress();

        OptionProductRegistry.OptionSeries memory series = _optionRegistry.getSeries(optionId);
        _requireStandardContractSize(series);

        if (block.timestamp < series.expiry) revert NotExpired();

        (uint256 settlementPrice, bool isSet) = _optionRegistry.getSettlementInfo(optionId);
        if (!isSet || settlementPrice == 0) revert SettlementNotSet();

        _requireSettlementAssetConfigured(series.settlementAsset);

        if (isAccountSettled[optionId][trader]) revert SettlementAlreadyProcessed();
        isAccountSettled[optionId][trader] = true;

        IMarginEngineState.Position storage pos = _positions[trader][optionId];
        int128 oldQty = pos.quantity;

        _ensureQtyAllowed(oldQty);

        if (oldQty == 0) {
            emit AccountSettled(trader, optionId, 0, 0, 0, 0);
            return;
        }

        uint256 payoffPerContract = _computePerContractPayoff(series, settlementPrice);

        int256 pnl;
        if (payoffPerContract == 0) {
            pnl = 0;
        } else {
            int256 q = int256(oldQty);
            uint256 absQty = q >= 0 ? uint256(q) : uint256(-q);

            uint256 amount = _mulChecked(absQty, payoffPerContract);
            if (amount > uint256(type(int256).max)) revert PnlOverflow();

            pnl = q >= 0 ? int256(amount) : -int256(amount);
        }

        // Close position before transfers so settlement cannot be replayed.
        pos.quantity = 0;
        _syncPositionIndexes(trader, optionId, oldQty, 0);

        uint256 collectedFromTrader = 0;
        uint256 paidToTrader = 0;
        uint256 badDebt = 0;

        address asset = series.settlementAsset;

        _syncVaultBestEffort(trader, asset);
        _syncVaultBestEffort(_settlementSink(), asset);
        if (insuranceFund != address(0)) {
            _syncVaultBestEffort(insuranceFund, asset);
        }

        if (pnl > 0) {
            uint256 amountDue = uint256(pnl);
            (paidToTrader, badDebt) = _resolveLongSettlementPayout(asset, trader, amountDue);
        } else if (pnl < 0) {
            uint256 amountOwed = uint256(-pnl);
            (collectedFromTrader, badDebt) = _resolveShortSettlementCollection(asset, trader, amountOwed);
        }

        _recordSeriesSettlementAccounting(optionId, collectedFromTrader, paidToTrader, badDebt);

        emit AccountSettled(trader, optionId, pnl, collectedFromTrader, paidToTrader, badDebt);
    }

    function settleAccount(uint256 optionId, address trader) public whenSettlementNotPaused nonReentrant {
        _settleAccount(optionId, trader);
    }

    function settleAccounts(uint256 optionId, address[] calldata traders) external whenSettlementNotPaused nonReentrant {
        uint256 len = traders.length;
        for (uint256 i = 0; i < len; i++) {
            _settleAccount(optionId, traders[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDATION LOGIC (OPTIONS)
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns settlement-native units per contract.
    function _computeLiquidationPricePerContract(OptionProductRegistry.OptionSeries memory s)
        internal
        view
        returns (uint256 pricePerContract)
    {
        _requireStandardContractSize(s);

        (uint256 spot, uint256 updatedAt, bool ok) = _oracle.getPriceSafe(s.underlying, s.settlementAsset);
        if (!ok || spot == 0) revert OraclePriceUnavailable();

        uint32 maxDelay = liquidationOracleMaxDelay;
        if (maxDelay > 0) {
            if (updatedAt == 0) revert OraclePriceStale();
            if (updatedAt > block.timestamp) revert OraclePriceStale();
            if (block.timestamp - updatedAt > maxDelay) revert OraclePriceStale();
        }

        uint256 intrinsicPrice1e8 = _intrinsic1e8(s, spot);
        uint256 liqPrice1e8 = intrinsicPrice1e8;

        if (intrinsicPrice1e8 > 0 && minLiquidationPriceBpsOfIntrinsic > 0) {
            uint256 floorPx = (intrinsicPrice1e8 * minLiquidationPriceBpsOfIntrinsic) / BPS;
            if (liqPrice1e8 < floorPx) liqPrice1e8 = floorPx;
        }

        if (liquidationPriceSpreadBps > 0) {
            liqPrice1e8 = (liqPrice1e8 * (BPS + liquidationPriceSpreadBps)) / BPS;
        }

        pricePerContract = _price1e8ToSettlementUnits(s.settlementAsset, liqPrice1e8);
    }

    function liquidate(address trader, uint256[] calldata optionIds, uint128[] calldata quantities)
        external
        whenLiquidationNotPaused
        nonReentrant
    {
        if (trader == address(0)) revert ZeroAddress();
        if (trader == msg.sender) revert InvalidTrade();
        if (optionIds.length == 0 || optionIds.length != quantities.length) revert LengthMismatch();
        if (address(_riskModule) == address(0)) revert RiskModuleNotSet();
        if (liquidationCloseFactorBps == 0) revert LiquidationCloseFactorZero();

        _requireBaseConfigured();
        _requireRiskParamsSynced();

        IRiskModule.AccountRisk memory riskBefore = _riskModule.computeAccountRisk(trader);
        uint256 ratioBeforeBps = _marginRatioBpsFromRisk(riskBefore.equityBase, riskBefore.maintenanceMarginBase);

        if (!isLiquidatable(trader)) revert NotLiquidatable();

        uint256 traderTotalShort = totalShortContracts[trader];
        if (traderTotalShort == 0) revert NotLiquidatable();

        uint256 maxCloseOverall = Math.mulDiv(traderTotalShort, liquidationCloseFactorBps, BPS, Math.Rounding.Down);
        if (maxCloseOverall == 0) maxCloseOverall = 1;

        address liquidator = msg.sender;
        uint256 totalContractsClosed;

        uint128[] memory executed = new uint128[](optionIds.length);

        address[] memory cashAssets = new address[](optionIds.length);
        uint256[] memory cashRequested = new uint256[](optionIds.length);
        uint256 assetsCount;

        address[] memory touchedAssets = new address[](optionIds.length);
        uint256 touchedCount;

        for (uint256 i = 0; i < optionIds.length; i++) {
            if (totalContractsClosed >= maxCloseOverall) break;

            uint256 optionId = optionIds[i];
            uint128 requestedQty = quantities[i];
            if (requestedQty == 0) continue;

            OptionProductRegistry.OptionSeries memory s = _optionRegistry.getSeries(optionId);
            _requireStandardContractSize(s);

            if (block.timestamp >= s.expiry) continue;
            _requireSettlementAssetConfigured(s.settlementAsset);

            IMarginEngineState.Position storage traderPos = _positions[trader][optionId];
            if (traderPos.quantity >= 0) continue;

            IMarginEngineState.Position storage liqPos = _positions[liquidator][optionId];

            int128 oldTraderQty = traderPos.quantity;
            int128 oldLiqQty = liqPos.quantity;

            _ensureQtyAllowed(oldTraderQty);
            _ensureQtyAllowed(oldLiqQty);

            uint256 traderShortAbs = uint256(-int256(oldTraderQty));
            uint256 remainingAllowance = maxCloseOverall - totalContractsClosed;

            uint256 liqQtyU = uint256(requestedQty);
            if (liqQtyU > traderShortAbs) liqQtyU = traderShortAbs;
            if (liqQtyU > remainingAllowance) liqQtyU = remainingAllowance;
            if (liqQtyU == 0) continue;

            if (liqQtyU > uint256(uint128(type(int128).max))) revert QuantityTooLarge();
            uint128 liqQty = uint128(liqQtyU);
            int128 delta = _toInt128(liqQty);

            uint256 liqPricePerContract = _computeLiquidationPricePerContract(s);
            uint256 req = _mulChecked(liqPricePerContract, uint256(liqQty));

            {
                bool found;
                for (uint256 k = 0; k < assetsCount; k++) {
                    if (cashAssets[k] == s.settlementAsset) {
                        cashRequested[k] = _addChecked(cashRequested[k], req);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    cashAssets[assetsCount] = s.settlementAsset;
                    cashRequested[assetsCount] = req;
                    assetsCount++;
                }
            }

            {
                bool tfound;
                for (uint256 k2 = 0; k2 < touchedCount; k2++) {
                    if (touchedAssets[k2] == s.settlementAsset) {
                        tfound = true;
                        break;
                    }
                }
                if (!tfound) {
                    touchedAssets[touchedCount] = s.settlementAsset;
                    touchedCount++;
                }
            }

            traderPos.quantity = _checkedAddInt128(oldTraderQty, delta);
            liqPos.quantity = _checkedSubInt128(oldLiqQty, delta);

            int128 newTraderQty = traderPos.quantity;
            int128 newLiqQty = liqPos.quantity;

            _syncPositionIndexes(trader, optionId, oldTraderQty, newTraderQty);
            _syncPositionIndexes(liquidator, optionId, oldLiqQty, newLiqQty);

            executed[i] = liqQty;
            totalContractsClosed += uint256(liqQty);
        }

        if (totalContractsClosed == 0) revert LiquidationNothingToDo();

        for (uint256 i = 0; i < assetsCount; i++) {
            address asset = cashAssets[i];
            uint256 req = cashRequested[i];
            if (req == 0) continue;

            _syncVaultBestEffort(trader, asset);

            uint256 traderBal = _collateralVault.balances(trader, asset);
            uint256 paid = req <= traderBal ? req : traderBal;

            if (paid > 0) {
                _collateralVault.transferBetweenAccounts(asset, trader, liquidator, paid);
            }

            emit LiquidationCashflow(liquidator, trader, asset, paid, req);
        }

        uint256 mmBase = _mulChecked(baseMaintenanceMarginPerContract, totalContractsClosed);
        uint256 penaltyBase = Math.mulDiv(mmBase, liquidationPenaltyBps, BPS, Math.Rounding.Down);

        uint256 remainingBase = penaltyBase;
        uint256 seizedBaseTotal = 0;

        if (remainingBase > 0) {
            _syncVaultBestEffort(trader, baseCollateralToken);

            uint256 balBase = _collateralVault.balances(trader, baseCollateralToken);
            uint256 seizeBaseTokenAmt = remainingBase <= balBase ? remainingBase : balBase;

            if (seizeBaseTokenAmt > 0) {
                _collateralVault.transferBetweenAccounts(baseCollateralToken, trader, liquidator, seizeBaseTokenAmt);
                seizedBaseTotal = _addChecked(seizedBaseTotal, seizeBaseTokenAmt);
                remainingBase -= seizeBaseTokenAmt;

                emit LiquidationSeize(liquidator, trader, baseCollateralToken, seizeBaseTokenAmt, seizeBaseTokenAmt);
            }
        }

        if (remainingBase > 0) {
            for (uint256 i = 0; i < touchedCount; i++) {
                if (remainingBase == 0) break;

                address tok = touchedAssets[i];
                if (tok == address(0) || tok == baseCollateralToken) continue;

                CollateralVault.CollateralTokenConfig memory cfg = _vaultCfg(tok);
                if (!cfg.isSupported || cfg.decimals == 0) continue;

                _syncVaultBestEffort(trader, tok);

                (uint256 neededTok, bool ok) = _baseValueToTokenAmountUp(tok, remainingBase);
                if (!ok || neededTok == 0) continue;

                uint256 balTok = _collateralVault.balances(trader, tok);
                uint256 seizeTok = neededTok <= balTok ? neededTok : balTok;
                if (seizeTok == 0) continue;

                uint256 pxTokBase = _getOraclePriceChecked(tok, baseCollateralToken);
                uint256 seizedBaseApprox = _tokenAmountToBaseValueDown(tok, seizeTok, pxTokBase);

                _collateralVault.transferBetweenAccounts(tok, trader, liquidator, seizeTok);

                uint256 applied = seizedBaseApprox <= remainingBase ? seizedBaseApprox : remainingBase;
                seizedBaseTotal = _addChecked(seizedBaseTotal, applied);
                remainingBase -= applied;

                emit LiquidationSeize(liquidator, trader, tok, seizeTok, applied);
            }
        }

        IRiskModule.AccountRisk memory riskAfter = _riskModule.computeAccountRisk(trader);
        uint256 ratioAfterBps = _marginRatioBpsFromRisk(riskAfter.equityBase, riskAfter.maintenanceMarginBase);

        if (riskBefore.equityBase > 0) {
            if (ratioAfterBps < ratioBeforeBps + minLiquidationImprovementBps) revert LiquidationNotImproving();
        } else {
            bool improved = (riskAfter.maintenanceMarginBase < riskBefore.maintenanceMarginBase)
                || (riskAfter.equityBase > riskBefore.equityBase);
            if (!improved) revert LiquidationNotImproving();
        }

        emit Liquidation(liquidator, trader, optionIds, executed, seizedBaseTotal);

        _enforceInitialMargin(liquidator);
    }
}