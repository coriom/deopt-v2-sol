// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./RiskGovernorStorage.sol";

abstract contract RiskGovernorAdmin is RiskGovernorStorage {
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

    /// @dev address(0) allowed to disable guardian.
    function setGuardian(address newGuardian) external onlyOwner {
        _setGuardian(newGuardian);
    }

    function setRiskModuleTarget(address newTarget) external onlyOwner {
        _validateTarget(newTarget);
        _setRiskModule(newTarget);
    }

    function setMarginEngineTarget(address newTarget) external onlyOwner {
        _validateTarget(newTarget);
        _setMarginEngine(newTarget);
    }

    function setOracleRouterTarget(address newTarget) external onlyOwner {
        _validateTarget(newTarget);
        _setOracleRouter(newTarget);
    }

    function setFeesManagerTarget(address newTarget) external onlyOwner {
        _validateTarget(newTarget);
        _setFeesManager(newTarget);
    }

    function setOptionRegistryTarget(address newTarget) external onlyOwner {
        _validateTarget(newTarget);
        _setOptionRegistry(newTarget);
    }

    function setCollateralVaultTarget(address newTarget) external onlyOwner {
        _validateTarget(newTarget);
        _setCollateralVault(newTarget);
    }

    function setInsuranceFundTarget(address newTarget) external onlyOwner {
        _validateTarget(newTarget);
        _setInsuranceFund(newTarget);
    }

    function setPerpMarketRegistryTarget(address newTarget) external onlyOwner {
        _validateTarget(newTarget);
        _setPerpMarketRegistry(newTarget);
    }

    function setPerpEngineTarget(address newTarget) external onlyOwner {
        _validateTarget(newTarget);
        _setPerpEngine(newTarget);
    }
}