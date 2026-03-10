// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../CollateralVault.sol";
import "../OptionProductRegistry.sol";
import "../oracle/IOracle.sol";
import "./IRiskModule.sol";
import "./IMarginEngineState.sol";

abstract contract RiskModuleStorage is IRiskModule {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant PRICE_SCALE_U = IRiskModule.PRICE_SCALE;
    uint256 internal constant BPS_U = IRiskModule.BPS;
    uint256 internal constant MAX_POW10_EXP = 77;
    uint8 internal constant EXPECTED_BASE_DECIMALS = 6;
    uint256 internal constant SERIES_PAGE = 64;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event RiskParamsSet(address baseCollateralToken, uint256 baseMaintenanceMarginPerContract, uint256 imFactorBps);

    event OracleSet(address indexed newOracle);
    event MarginEngineSet(address indexed newMarginEngine);

    event CollateralConfigSet(address indexed token, uint64 weightBps, bool isEnabled);
    event CollateralTokensSyncedFromVault(uint256 added);

    event MaxOracleDelaySet(uint256 maxOracleDelay);

    event OracleDownMmMultiplierSet(uint256 multiplierBps);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error ZeroAddress();
    error InvalidParams();
    error MathOverflow();

    error BaseTokenNotConfigured();
    error TokenNotConfigured(address token);
    error TokenDecimalsNotConfigured(address token);
    error TokenNotSupportedInVault(address token);

    error DecimalsOverflow(address token);
    error DecimalsDiffOverflow(address token);

    error BaseTokenDecimalsNotUSDC(address token, uint8 decimals);

    error InvalidContractSize();

    error QuantityInt128Min();
    error QuantityAbsOverflow();

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;

    CollateralVault public collateralVault;
    OptionProductRegistry public optionRegistry;
    IMarginEngineState public marginEngine;
    IOracle public oracle;

    address public override baseCollateralToken;
    uint256 public override baseMaintenanceMarginPerContract;
    uint256 public override imFactorBps;

    uint256 public maxOracleDelay;
    uint256 public oracleDownMmMultiplierBps = 20_000;

    struct CollateralConfig {
        uint64 weightBps;
        bool isEnabled;
    }

    mapping(address => CollateralConfig) public collateralConfigs;

    address[] public collateralTokens;
    mapping(address => bool) internal isCollateralTokenListed;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }
}