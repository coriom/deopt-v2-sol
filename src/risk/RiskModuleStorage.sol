// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../collateral/CollateralVault.sol";
import "../OptionProductRegistry.sol";
import "../oracle/IOracle.sol";
import "./IRiskModule.sol";
import "./IMarginEngineState.sol";

/// @notice Storage root for RiskModule.
/// @dev
///  - Centralizes all state / shared constants / shared events / shared errors.
///  - Includes an emergency layer compatible with a future Safe multisig:
///      * owner = governance / timelock / Safe
///      * guardian = operational emergency actor
///  - Granular pauses are defined here, then enforced in child layers where relevant.
abstract contract RiskModuleStorage is IRiskModule {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant PRICE_SCALE_U = IRiskModule.PRICE_SCALE;
    uint256 internal constant BPS_U = IRiskModule.BPS;

    // defensive: 10**77 fits in uint256, 10**78 does not
    uint256 internal constant MAX_POW10_EXP = 77;

    // current deployment target: USDC-like base collateral
    uint8 internal constant EXPECTED_BASE_DECIMALS = 6;

    // pagination for margin-engine open series scanning
    uint256 internal constant SERIES_PAGE = 64;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Emergency guardian updated.
    /// @dev address(0) is allowed to disable guardian mode.
    event GuardianSet(address indexed newGuardian);

    event RiskParamsSet(address baseCollateralToken, uint256 baseMaintenanceMarginPerContract, uint256 imFactorBps);

    event OracleSet(address indexed newOracle);
    event MarginEngineSet(address indexed newMarginEngine);

    event CollateralConfigSet(address indexed token, uint64 weightBps, bool isEnabled);
    event CollateralTokensSyncedFromVault(uint256 added);

    event MaxOracleDelaySet(uint256 maxOracleDelay);

    /// @notice Multiplier used when settlement->base conversion fails.
    /// @dev Example: 20_000 = 2x.
    event OracleDownMmMultiplierSet(uint256 multiplierBps);

    /*//////////////////////////////////////////////////////////////
                            EMERGENCY EVENTS
    //////////////////////////////////////////////////////////////*/

    event Paused(address indexed account);
    event Unpaused(address indexed account);

    /// @notice Legacy global pause.
    /// @dev Coexists with granular pause flags for incident management.
    event GlobalPauseSet(bool isPaused);

    /// @notice Freeze of risk computation paths.
    /// @dev Intended for severe oracle / valuation incidents.
    event RiskChecksPauseSet(bool isPaused);

    /// @notice Freeze of collateral valuation dependent paths.
    event CollateralValuationPauseSet(bool isPaused);

    /// @notice Freeze of withdraw preview / withdrawability related paths.
    event WithdrawPreviewPauseSet(bool isPaused);

    /// @notice Snapshot event for the full emergency mode state.
    event EmergencyModeUpdated(bool riskChecksPaused, bool collateralValuationPaused, bool withdrawPreviewPaused);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error GuardianNotAuthorized();
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
                            EMERGENCY ERRORS
    //////////////////////////////////////////////////////////////*/

    error PausedError();
    error RiskChecksPaused();
    error CollateralValuationPaused();
    error WithdrawPreviewPaused();

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Governance owner, expected to be timelock / Safe in production.
    address public owner;

    /// @notice Operational emergency actor.
    /// @dev Can trigger protective pauses but should not be the long-term governance authority.
    address public guardian;

    CollateralVault public collateralVault;
    OptionProductRegistry public optionRegistry;
    IMarginEngineState public marginEngine;
    IOracle public oracle;

    address public override baseCollateralToken;
    uint256 public override baseMaintenanceMarginPerContract;
    uint256 public override imFactorBps;

    /// @notice Optional local oracle staleness guard. 0 = disabled.
    uint256 public maxOracleDelay;

    /// @notice Oracle-down fallback MM multiplier in bps.
    uint256 public oracleDownMmMultiplierBps = 20_000;

    struct CollateralConfig {
        uint64 weightBps;
        bool isEnabled;
    }

    mapping(address => CollateralConfig) public collateralConfigs;

    address[] public collateralTokens;
    mapping(address => bool) internal isCollateralTokenListed;

    /*//////////////////////////////////////////////////////////////
                            EMERGENCY STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Legacy global pause.
    bool public paused;

    /// @notice Granular pause for core risk checks.
    bool public riskChecksPaused;

    /// @notice Granular pause for collateral valuation dependent paths.
    bool public collateralValuationPaused;

    /// @notice Granular pause for withdraw preview / withdrawability views.
    bool public withdrawPreviewPaused;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != owner && msg.sender != guardian) revert GuardianNotAuthorized();
        _;
    }

    modifier whenNotPaused() {
        if (_isGloballyPaused()) revert PausedError();
        _;
    }

    modifier whenRiskChecksNotPaused() {
        if (_isRiskChecksPaused()) revert RiskChecksPaused();
        _;
    }

    modifier whenCollateralValuationNotPaused() {
        if (_isCollateralValuationPaused()) revert CollateralValuationPaused();
        _;
    }

    modifier whenWithdrawPreviewNotPaused() {
        if (_isWithdrawPreviewPaused()) revert WithdrawPreviewPaused();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL INIT / EMERGENCY HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Optional initializer helper for the concrete RiskModule constructor.
    function _initRiskModuleStorage(
        address owner_,
        address vault_,
        address registry_,
        address marginEngine_,
        address oracle_
    ) internal {
        if (owner != address(0)) revert NotAuthorized();
        if (
            owner_ == address(0) || vault_ == address(0) || registry_ == address(0) || marginEngine_ == address(0)
                || oracle_ == address(0)
        ) {
            revert ZeroAddress();
        }

        owner = owner_;
        collateralVault = CollateralVault(vault_);
        optionRegistry = OptionProductRegistry(registry_);
        marginEngine = IMarginEngineState(marginEngine_);
        oracle = IOracle(oracle_);

        paused = false;
        riskChecksPaused = false;
        collateralValuationPaused = false;
        withdrawPreviewPaused = false;

        emit OwnershipTransferred(address(0), owner_);
        emit MarginEngineSet(marginEngine_);
        emit OracleSet(oracle_);
        emit OracleDownMmMultiplierSet(oracleDownMmMultiplierBps);
        emit EmergencyModeUpdated(false, false, false);
    }

    function _isGloballyPaused() internal view returns (bool) {
        return paused;
    }

    function _isRiskChecksPaused() internal view returns (bool) {
        return paused || riskChecksPaused;
    }

    function _isCollateralValuationPaused() internal view returns (bool) {
        return paused || collateralValuationPaused;
    }

    function _isWithdrawPreviewPaused() internal view returns (bool) {
        return paused || withdrawPreviewPaused;
    }

    function _setGuardian(address guardian_) internal {
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    function _setEmergencyModes(bool riskChecksPaused_, bool collateralValuationPaused_, bool withdrawPreviewPaused_)
        internal
    {
        if (riskChecksPaused != riskChecksPaused_) {
            riskChecksPaused = riskChecksPaused_;
            emit RiskChecksPauseSet(riskChecksPaused_);
        }

        if (collateralValuationPaused != collateralValuationPaused_) {
            collateralValuationPaused = collateralValuationPaused_;
            emit CollateralValuationPauseSet(collateralValuationPaused_);
        }

        if (withdrawPreviewPaused != withdrawPreviewPaused_) {
            withdrawPreviewPaused = withdrawPreviewPaused_;
            emit WithdrawPreviewPauseSet(withdrawPreviewPaused_);
        }

        emit EmergencyModeUpdated(riskChecksPaused_, collateralValuationPaused_, withdrawPreviewPaused_);
    }
}