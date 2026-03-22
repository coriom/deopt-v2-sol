// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CollateralVaultViews.sol";

abstract contract CollateralVaultActions is CollateralVaultViews {
    /*//////////////////////////////////////////////////////////////
                            USER: YIELD SETTINGS
    //////////////////////////////////////////////////////////////*/

    function setYieldOptIn(address token, bool optedIn) external {
        if (_isAuthorizedEngine(msg.sender)) revert YieldNotAllowedForProtocolAccount();

        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        yieldOptIn[msg.sender][token] = optedIn;
        emit YieldOptInSet(msg.sender, token, optedIn);
    }

    function syncAccount(address token) external nonReentrant {
        _sync(msg.sender, token);
    }

    function syncAccountFor(address user, address token) external nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        _sync(user, token);
    }

    /*//////////////////////////////////////////////////////////////
                            USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(address token, uint256 amount) external whenDepositsNotPaused nonReentrant {
        if (amount == 0) revert AmountZero();

        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        _sync(msg.sender, token);

        uint256 pre = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - pre;
        if (received == 0) revert AmountZero();

        balances[msg.sender][token] += received;
        idleBalances[msg.sender][token] += received;

        emit Deposited(msg.sender, token, received);

        _maybeMoveToStrategy(msg.sender, token, received);
    }

    function depositFor(address user, address token, uint256 amount)
        external
        onlyMarginEngine
        whenDepositsNotPaused
        nonReentrant
    {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();

        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        _sync(user, token);

        uint256 pre = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(user, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - pre;
        if (received == 0) revert AmountZero();

        balances[user][token] += received;
        idleBalances[user][token] += received;

        emit Deposited(user, token, received);

        _maybeMoveToStrategy(user, token, received);
    }

    function withdraw(address token, uint256 amount) external whenWithdrawalsNotPaused nonReentrant {
        _withdrawInternal(msg.sender, msg.sender, token, amount);
    }

    function withdrawFor(address user, address token, uint256 amount)
        external
        onlyMarginEngine
        whenWithdrawalsNotPaused
        nonReentrant
    {
        if (user == address(0)) revert ZeroAddress();
        _withdrawInternal(user, user, token, amount);
    }

    function moveToStrategy(address token, uint256 amount) external whenYieldOpsNotPaused nonReentrant {
        _sync(msg.sender, token);
        _moveToStrategy(msg.sender, token, amount);
        _sync(msg.sender, token);
    }

    function moveToIdle(address token, uint256 amount) external whenYieldOpsNotPaused nonReentrant {
        if (amount == 0) revert AmountZero();

        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        _sync(msg.sender, token);

        address adapter = tokenStrategy[token];
        if (adapter == address(0)) revert StrategyNotSet();

        uint256 sharesNeeded = _previewWithdraw(adapter, amount);

        uint256 userShares = strategyShares[msg.sender][token];
        if (userShares < sharesNeeded) revert InsufficientStrategyShares();

        strategyShares[msg.sender][token] = userShares - sharesNeeded;

        uint256 sharesBurned = IYieldAdapter(adapter).withdraw(amount, address(this));
        if (sharesBurned != sharesNeeded) revert AdapterReturnedUnexpectedShares();

        tokenTotalStrategyShares[token] -= sharesBurned;
        idleBalances[msg.sender][token] += amount;

        emit MovedToIdle(msg.sender, token, amount, sharesBurned);

        _sync(msg.sender, token);
    }

    /*//////////////////////////////////////////////////////////////
                        AUTHORIZED ENGINE HOOKS
    //////////////////////////////////////////////////////////////*/

    function transferBetweenAccounts(address token, address from, address to, uint256 amount)
        external
        onlyMarginEngine
        whenInternalTransfersNotPaused
        nonReentrant
    {
        if (from == to) revert SameAccountTransfer();
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();

        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        _sync(from, token);
        _sync(to, token);

        uint256 fromBal = balances[from][token];
        if (fromBal < amount) revert InsufficientBalance();

        balances[from][token] = fromBal - amount;
        balances[to][token] += amount;

        uint256 idleFrom = idleBalances[from][token];
        uint256 idleMove = idleFrom >= amount ? amount : idleFrom;

        if (idleMove > 0) {
            idleBalances[from][token] = idleFrom - idleMove;
            idleBalances[to][token] += idleMove;
        }

        uint256 remaining = amount - idleMove;
        if (remaining > 0) {
            address adapter = tokenStrategy[token];
            if (adapter == address(0)) revert NotEnoughIdle();

            uint256 sharesNeeded = _previewWithdraw(adapter, remaining);

            uint256 sharesFrom = strategyShares[from][token];
            if (sharesFrom < sharesNeeded) revert InsufficientStrategyShares();

            strategyShares[from][token] = sharesFrom - sharesNeeded;

            uint256 sharesBurned = IYieldAdapter(adapter).withdraw(remaining, address(this));
            if (sharesBurned != sharesNeeded) revert AdapterReturnedUnexpectedShares();

            tokenTotalStrategyShares[token] -= sharesBurned;

            idleBalances[to][token] += remaining;

            _maybeMoveToStrategy(to, token, remaining);
        } else {
            _maybeMoveToStrategy(to, token, idleMove);
        }

        emit InternalTransfer(token, from, to, amount);

        _sync(from, token);
        _sync(to, token);
    }
}