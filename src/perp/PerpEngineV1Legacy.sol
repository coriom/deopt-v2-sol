// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IFeesManager} from "../fees/IFeesManager.sol";

import "./PerpEngineViews.sol";

/// @title PerpEngineV1Legacy
/// @notice V1-only administration + view mixin.
/// @dev
///  This layer sits between the shared `PerpEngineViews` core and `PerpEngineTrading`
///  (V1). It re-exposes the legacy admin / view surface that V1 requires but that
///  V2 intentionally drops to fit under EIP-170:
///
///   - legacy public getters for storage fields flipped to `internal` in
///     `PerpEngineStorage` (visibility change only; storage layout is preserved
///     bit-for-bit for both V1 and V2)
///   - legacy `setFeesManager` V1 fee-manager setter
///   - legacy `setLiquidationParams` 4-arg alias
///   - governance bad-debt repair surface (record / reduce / clear / repay) still
///     wired to the V1 target of `RiskGovernorQueue`
///   - `getRiskMarkPrice1e8` V1 alias for `getMarkPrice`
///
///  V2 skips this mixin entirely; V2 governance uses `setFeesManagerV2` +
///  per-market registry liquidation config and does not need the legacy surface.
abstract contract PerpEngineV1Legacy is PerpEngineViews {
    /*//////////////////////////////////////////////////////////////
                LEGACY PUBLIC GETTERS FOR INTERNAL STORAGE
    //////////////////////////////////////////////////////////////*/

    function feesManager() external view returns (IFeesManager) {
        return _feesManager;
    }

    function liquidationCloseFactorBps() external view returns (uint256) {
        return _liquidationCloseFactorBps;
    }

    function liquidationPenaltyBps() external view returns (uint256) {
        return _liquidationPenaltyBps;
    }

    function liquidationPriceSpreadBps() external view returns (uint256) {
        return _liquidationPriceSpreadBps;
    }

    function minLiquidationImprovementBps() external view returns (uint256) {
        return _minLiquidationImprovementBps;
    }

    function liquidationOracleMaxDelay() external view returns (uint32) {
        return _liquidationOracleMaxDelay;
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function feeRecipient() external view returns (address) {
        return _feeRecipient;
    }

    /*//////////////////////////////////////////////////////////////
                    LEGACY V1 FEE-MANAGER SETTER
    //////////////////////////////////////////////////////////////*/

    function setFeesManager(address feesManager_) external onlyOwner {
        if (feesManager_ == address(0)) revert ZeroAddress();
        _feesManager = IFeesManager(feesManager_);
        emit FeesManagerSet(feesManager_);
    }

    /*//////////////////////////////////////////////////////////////
                LEGACY V1 LIQUIDATION FALLBACK ALIAS
    //////////////////////////////////////////////////////////////*/

    /// @dev Backward-compatible 4-arg alias. Semantically this now sets fallback defaults.
    function setLiquidationParams(
        uint256 closeFactorBps_,
        uint256 penaltyBps_,
        uint256 priceSpreadBps_,
        uint256 minImprovementBps_
    ) external onlyOwner {
        _setLiquidationFallbackParams(
            closeFactorBps_,
            penaltyBps_,
            priceSpreadBps_,
            minImprovementBps_,
            _liquidationOracleMaxDelay
        );
    }

    /*//////////////////////////////////////////////////////////////
                    LEGACY V1 RISK-MARK PRICE ALIAS
    //////////////////////////////////////////////////////////////*/

    /// @notice V1 policy: `getRiskMarkPrice1e8` is a direct alias for `getMarkPrice` (== oracle index/spot).
    /// @dev V1-only surface. V2 exposes only `getMarkPrice` and consumers should read that directly.
    function getRiskMarkPrice1e8(uint256 marketId) external view returns (uint256) {
        return _getMarkPrice1e8(marketId);
    }

    /*//////////////////////////////////////////////////////////////
                        BAD DEBT ADMIN SURFACE (V1)
    //////////////////////////////////////////////////////////////*/

    /// @notice Manually records additional residual bad debt on an account.
    /// @dev Emergency / governance tool. Prefer protocol-native liquidation path whenever possible.
    function recordResidualBadDebt(address trader, uint256 amountBase) external onlyOwner {
        if (trader == address(0)) revert ZeroAddress();
        if (amountBase == 0) revert AmountZero();

        _recordResidualBadDebt(trader, amountBase);
    }

    /// @notice Reduces residual bad debt on an account by up to `amountBase`.
    function reduceResidualBadDebt(address trader, uint256 amountBase)
        external
        onlyOwner
        returns (uint256 reducedBase)
    {
        if (trader == address(0)) revert ZeroAddress();
        if (amountBase == 0) revert AmountZero();

        reducedBase = _reduceResidualBadDebt(trader, amountBase);
    }

    /// @notice Clears all recorded residual bad debt for an account.
    function clearResidualBadDebt(address trader) external onlyOwner returns (uint256 clearedBase) {
        if (trader == address(0)) revert ZeroAddress();

        clearedBase = _clearResidualBadDebt(trader);
    }

    /// @notice Repays residual bad debt in base-token units by moving vault collateral from `payer` to protocol recipient.
    function repayResidualBadDebt(address payer, address trader, uint256 requestedAmountBase)
        external
        onlyOwner
        returns (BadDebtRepayment memory repayment)
    {
        if (payer == address(0) || trader == address(0)) revert ZeroAddress();
        if (requestedAmountBase == 0) revert AmountZero();

        address recipient = _resolvedBadDebtRepaymentRecipient();
        if (recipient == address(0)) revert InsuranceFundNotSet();

        address baseToken = _baseCollateralToken();

        _syncVaultBestEffort(payer, baseToken);
        if (payer != recipient) {
            _syncVaultBestEffort(recipient, baseToken);
        }

        repayment.requestedBase = requestedAmountBase;
        repayment.outstandingBase = _residualBadDebtOf(trader);

        if (repayment.outstandingBase == 0) {
            emit ResidualBadDebtRepaid(payer, trader, recipient, requestedAmountBase, 0, 0);
            return repayment;
        }

        uint256 payerBal = _collateralVault.balances(payer, baseToken);

        uint256 cappedToDebt =
            requestedAmountBase < repayment.outstandingBase ? requestedAmountBase : repayment.outstandingBase;

        repayment.repaidBase = payerBal < cappedToDebt ? payerBal : cappedToDebt;

        if (repayment.repaidBase != 0) {
            _collateralVault.transferBetweenAccounts(baseToken, payer, recipient, repayment.repaidBase);
            _reduceResidualBadDebt(trader, repayment.repaidBase);
        }

        repayment.remainingBase = _residualBadDebtOf(trader);

        emit ResidualBadDebtRepaid(
            payer, trader, recipient, requestedAmountBase, repayment.repaidBase, repayment.remainingBase
        );
    }
}
