// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./CollateralVaultAdmin.sol";

abstract contract CollateralVaultYield is CollateralVaultAdmin {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                        INTERNAL PREVIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function _previewDeposit(address adapter, uint256 assets) internal view returns (uint256) {
        try IYieldAdapter(adapter).previewDeposit(assets) returns (uint256 s) {
            return s;
        } catch {
            revert AdapterPreviewFailed();
        }
    }

    function _previewWithdraw(address adapter, uint256 assets) internal view returns (uint256) {
        try IYieldAdapter(adapter).previewWithdraw(assets) returns (uint256 s) {
            return s;
        } catch {
            revert AdapterPreviewFailed();
        }
    }

    function _previewRedeem(address adapter, uint256 shares) internal view returns (uint256) {
        try IYieldAdapter(adapter).previewRedeem(shares) returns (uint256 a) {
            return a;
        } catch {
            revert AdapterPreviewFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL SYNC
    //////////////////////////////////////////////////////////////*/

    function _sync(address user, address token) internal {
        _requireSupportedToken(token);

        uint256 idle = idleBalances[user][token];
        uint256 shares = strategyShares[user][token];

        uint256 assetsFromShares = 0;
        if (shares != 0) {
            IYieldAdapter adapter = _requireStrategySet(token);
            assetsFromShares = _previewRedeem(address(adapter), shares);
        }

        uint256 effective = idle + assetsFromShares;
        balances[user][token] = effective;

        emit Synced(user, token, effective);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL STRATEGY MOVES
    //////////////////////////////////////////////////////////////*/

    function _maybeMoveToStrategy(address user, address token, uint256 amount) internal {
        if (amount == 0) return;
        if (!yieldOptIn[user][token]) return;

        address adapter = tokenStrategy[token];
        if (adapter == address(0)) return;

        _moveToStrategy(user, token, amount);
    }

    function _moveToStrategy(address user, address token, uint256 amount) internal {
        if (amount == 0) revert AmountZero();

        _requireSupportedToken(token);
        _requireYieldAllowed(user);

        IYieldAdapter adapter = _requireStrategySet(token);

        uint256 idle = idleBalances[user][token];
        if (idle < amount) revert NotEnoughIdle();

        uint256 expectedShares = _previewDeposit(address(adapter), amount);

        idleBalances[user][token] = idle - amount;

        IERC20(token).forceApprove(address(adapter), 0);
        IERC20(token).forceApprove(address(adapter), amount);

        uint256 sharesMinted = adapter.deposit(amount);
        if (sharesMinted != expectedShares) revert AdapterReturnedUnexpectedShares();

        strategyShares[user][token] += sharesMinted;
        tokenTotalStrategyShares[token] += sharesMinted;

        emit MovedToStrategy(user, token, amount, sharesMinted);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL RISK HELPER
    //////////////////////////////////////////////////////////////*/

    function _getWithdrawableAmountBestEffort(address user, address token)
        internal
        view
        returns (uint256 maxAllowed, bool ok)
    {
        address rm = address(riskModule);
        if (rm == address(0)) return (type(uint256).max, false);

        (bool success, bytes memory data) =
            rm.staticcall(abi.encodeWithSignature("getWithdrawableAmount(address,address)", user, token));

        if (!success || data.length < 32) return (type(uint256).max, false);

        maxAllowed = abi.decode(data, (uint256));
        return (maxAllowed, true);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL WITHDRAW CORE
    //////////////////////////////////////////////////////////////*/

    function _withdrawInternal(address user, address to, address token, uint256 amount) internal {
        if (amount == 0) revert AmountZero();
        if (to == address(0)) revert ZeroAddress();

        _requireSupportedToken(token);

        _sync(user, token);

        uint256 bal = balances[user][token];
        if (bal < amount) revert InsufficientBalance();

        {
            (uint256 maxAllowed, bool ok) = _getWithdrawableAmountBestEffort(user, token);
            if (ok && amount > maxAllowed) revert WithdrawExceedsRiskLimits();
        }

        balances[user][token] = bal - amount;

        uint256 idle = idleBalances[user][token];
        if (idle >= amount) {
            idleBalances[user][token] = idle - amount;
            IERC20(token).safeTransfer(to, amount);
            emit Withdrawn(user, token, amount);
            return;
        }

        uint256 remaining = amount - idle;

        if (idle > 0) {
            idleBalances[user][token] = 0;
            IERC20(token).safeTransfer(to, idle);
        }

        IYieldAdapter adapter = _requireStrategySet(token);

        uint256 sharesNeeded = _previewWithdraw(address(adapter), remaining);

        uint256 userShares = strategyShares[user][token];
        if (userShares < sharesNeeded) revert InsufficientStrategyShares();

        strategyShares[user][token] = userShares - sharesNeeded;

        uint256 sharesBurned = adapter.withdraw(remaining, to);
        if (sharesBurned != sharesNeeded) revert AdapterReturnedUnexpectedShares();

        tokenTotalStrategyShares[token] -= sharesBurned;

        emit Withdrawn(user, token, amount);

        _sync(user, token);
    }
}