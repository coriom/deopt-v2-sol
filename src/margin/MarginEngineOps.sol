// contracts/margin/MarginEngineOps.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {OptionProductRegistry} from "../OptionProductRegistry.sol";
import {CollateralVault} from "../CollateralVault.sol";
import {IRiskModule} from "../risk/IRiskModule.sol";
import {IMarginEngineState} from "../risk/IMarginEngineState.sol";

import {MarginEngineTrading} from "./MarginEngineTrading.sol";

/// @notice Views + collateral + settlement + liquidation + oracle views
abstract contract MarginEngineOps is MarginEngineTrading {
    /*//////////////////////////////////////////////////////////////
                          INTERNAL PURE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Derive margin ratio in BPS from (equity, maintenanceMargin).
    ///      - maintenanceMargin==0 => infinite ratio
    ///      - equity<=0 => 0 ratio
    function _marginRatioBpsFromRisk(int256 equity, uint256 maintenanceMargin) internal pure returns (uint256) {
        if (maintenanceMargin == 0) return type(uint256).max;
        if (equity <= 0) return 0;
        return (uint256(equity) * BPS) / maintenanceMargin;
    }

    /*//////////////////////////////////////////////////////////////
                          IMarginEngineState (required)
    //////////////////////////////////////////////////////////////*/

    function positions(address trader, uint256 optionId)
        external
        view
        override
        returns (IMarginEngineState.Position memory)
    {
        return _positions[trader][optionId];
    }

    /// @notice OPEN series only (positions non nulles)
    function getTraderSeries(address trader) external view override returns (uint256[] memory) {
        return traderSeries[trader];
    }

    function getTraderSeriesLength(address trader) external view override returns (uint256) {
        return traderSeries[trader].length;
    }

    function getTraderSeriesSlice(address trader, uint256 start, uint256 end)
        external
        view
        override
        returns (uint256[] memory slice)
    {
        uint256 len = traderSeries[trader].length;
        if (start > len) start = len;
        if (end > len) end = len;
        if (end < start) end = start;

        uint256 outLen = end - start;
        slice = new uint256[](outLen);
        for (uint256 i = 0; i < outLen; i++) {
            slice[i] = traderSeries[trader][start + i];
        }
    }

    /*//////////////////////////////////////////////////////////////
                    IMarginEngineState (optional helpers)
    //////////////////////////////////////////////////////////////*/

    function optionRegistry() external view override returns (address) {
        return address(_optionRegistry);
    }

    function collateralVault() external view override returns (address) {
        return address(_collateralVault);
    }

    function oracle() external view override returns (address) {
        return address(_oracle);
    }

    function riskModule() external view override returns (address) {
        return address(_riskModule);
    }

    function getPositionQuantity(address trader, uint256 optionId) external view override returns (int128) {
        // invariant: jamais int128.min (enforced by state transitions)
        return _positions[trader][optionId].quantity;
    }

    function isOpenSeries(address trader, uint256 optionId) external view override returns (bool) {
        return traderSeriesIndexPlus1[trader][optionId] != 0;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function getAccountRisk(address trader) external view returns (IRiskModule.AccountRisk memory risk) {
        if (address(_riskModule) == address(0)) {
            IRiskModule.AccountRisk memory empty;
            return empty;
        }
        return _riskModule.computeAccountRisk(trader);
    }

    function getFreeCollateral(address trader) external view returns (int256) {
        if (address(_riskModule) == address(0)) return 0;
        return _riskModule.computeFreeCollateral(trader);
    }

    function previewWithdrawImpact(address trader, address token, uint256 amount)
        external
        view
        returns (IRiskModule.WithdrawPreview memory preview)
    {
        if (address(_riskModule) == address(0)) return preview;
        return _riskModule.previewWithdrawImpact(trader, token, amount);
    }

    function isSeriesExpired(uint256 optionId) public view returns (bool) {
        OptionProductRegistry.OptionSeries memory series = _optionRegistry.getSeries(optionId);
        return block.timestamp >= series.expiry;
    }

    /*//////////////////////////////////////////////////////////////
                        USER COLLATERAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Dépôt correct via CollateralVault.depositFor(user, token, amount).
    ///      Si non implémenté dans CollateralVault => revert (évite créditer le mauvais compte).
    function depositCollateral(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert AmountZero();

        (bool ok,) = address(_collateralVault).call(
            abi.encodeWithSignature("depositFor(address,address,uint256)", msg.sender, token, amount)
        );
        if (!ok) revert VaultDepositForNotSupported();

        emit CollateralDeposited(msg.sender, token, amount);
    }

    /// @dev IMPORTANT: ne jamais appeler collateralVault.withdraw() ici (msg.sender=MarginEngine).
    ///      On force withdrawFor(user, token, amount). Si non supporté => revert.
    function withdrawCollateral(address token, uint256 amount) external whenNotPaused nonReentrant {
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

    /// @dev Returns settlement units per contract.
    function _computePerContractPayoff(OptionProductRegistry.OptionSeries memory series, uint256 settlementPrice)
        internal
        view
        returns (uint256 payoffPerContract)
    {
        _requireStandardContractSize(series);
        if (settlementPrice == 0) return 0;

        uint256 intrinsicPrice1e8;
        if (series.isCall) {
            intrinsicPrice1e8 = settlementPrice > uint256(series.strike) ? (settlementPrice - uint256(series.strike)) : 0;
        } else {
            intrinsicPrice1e8 = uint256(series.strike) > settlementPrice ? (uint256(series.strike) - settlementPrice) : 0;
        }

        if (intrinsicPrice1e8 == 0) return 0;

        payoffPerContract = _price1e8ToSettlementUnits(series.settlementAsset, intrinsicPrice1e8);
    }

    function _settleAccount(uint256 optionId, address trader) internal {
        if (trader == address(0)) revert ZeroAddress();
        if (insuranceFund == address(0)) revert InsuranceFundNotSet();

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

        // close
        pos.quantity = 0;
        _updateTotalShortContracts(trader, oldQty, 0);
        _updateOpenSeriesOnChange(trader, optionId, oldQty, 0);

        uint256 collectedFromTrader = 0;
        uint256 paidToTrader = 0;
        uint256 badDebt = 0;

        address asset = series.settlementAsset;

        // best-effort sync (yield)
        _syncVaultBestEffort(trader, asset);
        _syncVaultBestEffort(insuranceFund, asset);

        if (pnl > 0) {
            uint256 amountPay = uint256(pnl);

            uint256 fundBal = _collateralVault.balances(insuranceFund, asset);
            if (fundBal < amountPay) revert InsuranceFundInsufficient(amountPay, fundBal);

            _collateralVault.transferBetweenAccounts(asset, insuranceFund, trader, amountPay);

            paidToTrader = amountPay;
            seriesPaid[optionId] += amountPay;
        } else if (pnl < 0) {
            uint256 amountOwed = uint256(-pnl);

            uint256 traderBal = _collateralVault.balances(trader, asset);
            uint256 amountToCollect = traderBal >= amountOwed ? amountOwed : traderBal;

            if (amountToCollect > 0) {
                _collateralVault.transferBetweenAccounts(asset, trader, insuranceFund, amountToCollect);
                collectedFromTrader = amountToCollect;
                seriesCollected[optionId] += amountToCollect;
            }

            if (amountToCollect < amountOwed) {
                badDebt = amountOwed - amountToCollect;
                seriesBadDebt[optionId] += badDebt;
            }
        }

        emit AccountSettled(trader, optionId, pnl, collectedFromTrader, paidToTrader, badDebt);

        emit SeriesSettlementAccountingUpdated(optionId, seriesCollected[optionId], seriesPaid[optionId], seriesBadDebt[optionId]);
    }

    function settleAccount(uint256 optionId, address trader) public whenNotPaused nonReentrant {
        _settleAccount(optionId, trader);
    }

    function settleAccounts(uint256 optionId, address[] calldata traders) external whenNotPaused nonReentrant {
        uint256 len = traders.length;
        for (uint256 i = 0; i < len; i++) {
            _settleAccount(optionId, traders[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDATION LOGIC (A-1)
    //////////////////////////////////////////////////////////////*/

    function getMarginRatioBps(address trader) public view returns (uint256) {
        if (address(_riskModule) == address(0)) return type(uint256).max;
        IRiskModule.AccountRisk memory risk = _riskModule.computeAccountRisk(trader);
        return _marginRatioBpsFromRisk(risk.equity, risk.maintenanceMargin);
    }

    function isLiquidatable(address trader) public view returns (bool) {
        if (address(_riskModule) == address(0)) return false;

        IRiskModule.AccountRisk memory risk = _riskModule.computeAccountRisk(trader);
        if (risk.maintenanceMargin == 0) return false;
        if (risk.equity <= 0) return true;

        uint256 ratioBps = (uint256(risk.equity) * BPS) / risk.maintenanceMargin;
        return ratioBps < liquidationThresholdBps;
    }

    /// @dev Returns settlement units per contract.
    function _computeLiquidationPricePerContract(OptionProductRegistry.OptionSeries memory s)
        internal
        view
        returns (uint256 pricePerContract)
    {
        _requireStandardContractSize(s);

        (uint256 spot, uint256 updatedAt) = _oracle.getPrice(s.underlying, s.settlementAsset);
        if (spot == 0) revert OraclePriceUnavailable();

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
        whenNotPaused
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
        uint256 ratioBeforeBps = _marginRatioBpsFromRisk(riskBefore.equity, riskBefore.maintenanceMargin);

        if (!isLiquidatable(trader)) revert NotLiquidatable();

        uint256 traderTotalShort = totalShortContracts[trader];
        if (traderTotalShort == 0) revert NotLiquidatable();

        uint256 maxCloseOverall = (traderTotalShort * liquidationCloseFactorBps) / BPS;
        if (maxCloseOverall == 0) maxCloseOverall = 1;

        address liquidator = msg.sender;
        uint256 totalContractsClosed;

        // precise executed quantities for event
        uint128[] memory executed = new uint128[](optionIds.length);

        // track per settlement asset cash requested
        address[] memory cashAssets = new address[](optionIds.length);
        uint256[] memory cashRequested = new uint256[](optionIds.length);
        uint256 assetsCount;

        // for penalty fallback seize: track distinct settlement assets touched
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

            // accumulate req per settlementAsset
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

            // track touched assets unique (for penalty seize fallback)
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

            // position transfer: trader short reduced, liquidator short increased
            traderPos.quantity = _checkedAddInt128(oldTraderQty, delta);
            liqPos.quantity = _checkedSubInt128(oldLiqQty, delta);

            int128 newTraderQty = traderPos.quantity;
            int128 newLiqQty = liqPos.quantity;

            _updateTotalShortContracts(trader, oldTraderQty, newTraderQty);
            _updateTotalShortContracts(liquidator, oldLiqQty, newLiqQty);

            _updateOpenSeriesOnChange(trader, optionId, oldTraderQty, newTraderQty);
            _updateOpenSeriesOnChange(liquidator, optionId, oldLiqQty, newLiqQty);

            executed[i] = liqQty;
            totalContractsClosed += uint256(liqQty);
        }

        if (totalContractsClosed == 0) revert LiquidationNothingToDo();

        // cashflow: per settlement asset, pay min(balance, requested)
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

        // penalty = MM_floor(base) * closedContracts * penaltyBps
        uint256 mmBase = _mulChecked(baseMaintenanceMarginPerContract, totalContractsClosed);
        uint256 penaltyBaseValue = Math.mulDiv(mmBase, liquidationPenaltyBps, BPS, Math.Rounding.Down);

        uint256 remainingBase = penaltyBaseValue;
        uint256 seizedBaseValueTotal = 0;

        // 1) seize in base token first
        if (remainingBase > 0) {
            _syncVaultBestEffort(trader, baseCollateralToken);

            uint256 balBase = _collateralVault.balances(trader, baseCollateralToken);
            uint256 seizeBaseTokenAmt = remainingBase <= balBase ? remainingBase : balBase;

            if (seizeBaseTokenAmt > 0) {
                _collateralVault.transferBetweenAccounts(baseCollateralToken, trader, liquidator, seizeBaseTokenAmt);
                seizedBaseValueTotal += seizeBaseTokenAmt;
                remainingBase -= seizeBaseTokenAmt;

                emit LiquidationSeize(liquidator, trader, baseCollateralToken, seizeBaseTokenAmt, seizeBaseTokenAmt);
            }
        }

        // 2) fallback: seize remaining penalty value using settlement assets touched (if oracle ok)
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
                uint256 seizedBaseValueApprox = _tokenAmountToBaseValueDown(tok, seizeTok, pxTokBase);

                _collateralVault.transferBetweenAccounts(tok, trader, liquidator, seizeTok);

                uint256 applied = seizedBaseValueApprox <= remainingBase ? seizedBaseValueApprox : remainingBase;
                seizedBaseValueTotal += applied;
                remainingBase -= applied;

                emit LiquidationSeize(liquidator, trader, tok, seizeTok, applied);
            }
        }

        // post-check improvement
        IRiskModule.AccountRisk memory riskAfter = _riskModule.computeAccountRisk(trader);
        uint256 ratioAfterBps = _marginRatioBpsFromRisk(riskAfter.equity, riskAfter.maintenanceMargin);

        if (riskBefore.equity > 0) {
            if (ratioAfterBps < ratioBeforeBps + minLiquidationImprovementBps) revert LiquidationNotImproving();
        } else {
            bool improved = (riskAfter.maintenanceMargin < riskBefore.maintenanceMargin) || (riskAfter.equity > riskBefore.equity);
            if (!improved) revert LiquidationNotImproving();
        }

        emit Liquidation(liquidator, trader, optionIds, executed, seizedBaseValueTotal);

        _enforceInitialMargin(liquidator);
    }

    /*//////////////////////////////////////////////////////////////
                        ORACLE HELPERS
    //////////////////////////////////////////////////////////////*/

    function getUnderlyingSpot(uint256 optionId) external view returns (uint256 price, uint256 updatedAt) {
        OptionProductRegistry.OptionSeries memory series = _optionRegistry.getSeries(optionId);
        _requireStandardContractSize(series);
        return _oracle.getPrice(series.underlying, series.settlementAsset);
    }
}
