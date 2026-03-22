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
        address old = guardian;
        guardian = newGuardian;
        emit GuardianSet(old, newGuardian);
    }

    function setRiskModuleTarget(address newTarget) external onlyOwner {
        if (newTarget == address(0)) revert ZeroAddress();
        address old = riskModule;
        riskModule = newTarget;
        emit RiskModuleSet(old, newTarget);
    }

    function setMarginEngineTarget(address newTarget) external onlyOwner {
        if (newTarget == address(0)) revert ZeroAddress();
        address old = marginEngine;
        marginEngine = newTarget;
        emit MarginEngineSet(old, newTarget);
    }

    function setOracleRouterTarget(address newTarget) external onlyOwner {
        if (newTarget == address(0)) revert ZeroAddress();
        address old = oracleRouter;
        oracleRouter = newTarget;
        emit OracleRouterSet(old, newTarget);
    }

    function setFeesManagerTarget(address newTarget) external onlyOwner {
        if (newTarget == address(0)) revert ZeroAddress();
        address old = feesManager;
        feesManager = newTarget;
        emit FeesManagerSet(old, newTarget);
    }

    function setOptionRegistryTarget(address newTarget) external onlyOwner {
        if (newTarget == address(0)) revert ZeroAddress();
        address old = optionRegistry;
        optionRegistry = newTarget;
        emit OptionRegistrySet(old, newTarget);
    }

    function setCollateralVaultTarget(address newTarget) external onlyOwner {
        if (newTarget == address(0)) revert ZeroAddress();
        address old = collateralVault;
        collateralVault = newTarget;
        emit CollateralVaultSet(old, newTarget);
    }

    function setInsuranceFundTarget(address newTarget) external onlyOwner {
        if (newTarget == address(0)) revert ZeroAddress();
        address old = insuranceFund;
        insuranceFund = newTarget;
        emit InsuranceFundSet(old, newTarget);
    }

    function setPerpMarketRegistryTarget(address newTarget) external onlyOwner {
        if (newTarget == address(0)) revert ZeroAddress();
        address old = perpMarketRegistry;
        perpMarketRegistry = newTarget;
        emit PerpMarketRegistrySet(old, newTarget);
    }

    function setPerpEngineTarget(address newTarget) external onlyOwner {
        if (newTarget == address(0)) revert ZeroAddress();
        address old = perpEngine;
        perpEngine = newTarget;
        emit PerpEngineSet(old, newTarget);
    }
}