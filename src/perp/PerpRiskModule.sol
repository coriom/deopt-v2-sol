// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOracle} from "../oracle/IOracle.sol";

interface ICollateralVaultPerpRiskView {
    struct CollateralTokenConfig {
        bool isSupported;
        uint8 decimals;
        uint16 collateralFactorBps;
    }

    function getCollateralTokens() external view returns (address[] memory);
    function getCollateralConfig(address token) external view returns (CollateralTokenConfig memory cfg);
    function balances(address user, address token) external view returns (uint256);
    function balanceWithYield(address user, address token) external view returns (uint256);
}

interface IPerpEngineRiskView {
    struct RiskConfig {
        uint32 initialMarginBps;
        uint32 maintenanceMarginBps;
        uint32 liquidationPenaltyBps;
        uint128 maxPositionSize1e8;
        uint128 maxOpenInterest1e8;
        bool reduceOnlyDuringCloseOnly;
    }

    function getTraderMarketsLength(address trader) external view returns (uint256);
    function getTraderMarketsSlice(address trader, uint256 start, uint256 end) external view returns (uint256[] memory);
    function getPositionSize(address trader, uint256 marketId) external view returns (int256);
    function getMarkPrice(uint256 marketId) external view returns (uint256);
    function getRiskConfig(uint256 marketId) external view returns (RiskConfig memory cfg);
    function getUnrealizedPnl(address trader, uint256 marketId) external view returns (int256 pnl1e8);
    function getPositionFundingAccrued(address trader, uint256 marketId) external view returns (int256 funding1e8);
}

/// @dev Optional extension used via best-effort runtime calls.
///      If the engine does not expose this function yet, the risk module
///      falls back to assuming quote numeraire == base collateral token.
interface IPerpEngineSettlementAssetView {
    function getSettlementAsset(uint256 marketId) external view returns (address);
}

/// @dev Optional extension for explicit residual bad debt accounting.
///      If missing, residual bad debt is assumed to be zero for backward compatibility.
interface IPerpEngineBadDebtView {
    function getResidualBadDebt(address trader) external view returns (uint256);
}

/// @title PerpRiskModule
/// @notice Risk module dedicated to the perpetual engine.
/// @dev
///  Canonical conventions:
///   - prices normalized in 1e8
///   - quote notionals / funding from the engine are in normalized 1e8 quote units
///   - risk outputs are expressed in native units of the base collateral token
///   - collateral valuation uses CollateralVault.collateralFactorBps as haircut
///   - account equity = adjusted collateral + unrealized PnL - accrued funding - residual bad debt
///
///  Design:
///   - collateral universe is read directly from CollateralVault
///   - open markets are paginated through PerpEngine
///   - collateral valuation is conservative:
///       * unsupported token => ignored
///       * zero CF token => ignored for margin equity
///       * stale / unavailable oracle on non-base token => ignored
///   - perp quote amounts are converted to base token native units:
///       * directly if settlement asset == base collateral token
///       * otherwise through oracle best-effort if market settlement asset is exposed
///       * otherwise fallback assumes quote numeraire == base collateral token
///   - residual bad debt is consumed from PerpEngine when exposed
contract PerpRiskModule {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant PRICE_SCALE = 1e8;
    uint256 public constant BPS = 10_000;

    uint256 internal constant SERIES_PAGE = 64;
    uint256 internal constant MAX_POW10_EXP = 77;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Unified account risk in base-token native units.
    struct AccountRisk {
        int256 equityBase;
        uint256 maintenanceMarginBase;
        uint256 initialMarginBase;
    }

    /// @notice Withdrawal preview.
    /// @dev
    ///  - requestedAmount / maxWithdrawable are in token-native units
    ///  - margin ratios are in basis points
    struct WithdrawPreview {
        uint256 requestedAmount;
        uint256 maxWithdrawable;
        uint256 marginRatioBeforeBps;
        uint256 marginRatioAfterBps;
        bool wouldBreachMargin;
    }

    /// @notice Perp-only aggregate contribution in base-token native units.
    struct PerpAggregate {
        uint256 maintenanceMarginBase;
        uint256 initialMarginBase;
        int256 unrealizedPnlBase;
        int256 fundingAccruedBase;
        int256 netPerpPnlBase;
        uint256 residualBadDebtBase;
    }

    /// @notice Full account components in base-token native units.
    struct AccountComponents {
        uint256 collateralEquityBase;
        PerpAggregate perp;
        int256 equityBase;
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error ZeroAddress();
    error InvalidParams();
    error MathOverflow();

    error BaseTokenNotConfigured();
    error TokenNotSupported(address token);
    error TokenDecimalsMissing(address token);
    error TokenDecimalsOverflow(address token);

    error OwnershipTransferNotInitiated();

    error PausedError();
    error RiskComputationPaused();
    error WithdrawPreviewPaused();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);
    event GuardianSet(address indexed oldGuardian, address indexed newGuardian);

    event PerpEngineSet(address indexed oldEngine, address indexed newEngine);
    event OracleSet(address indexed oldOracle, address indexed newOracle);
    event VaultSet(address indexed oldVault, address indexed newVault);
    event BaseCollateralTokenSet(address indexed oldToken, address indexed newToken);
    event MaxOracleDelaySet(uint256 oldDelay, uint256 newDelay);

    event Paused(address indexed account);
    event Unpaused(address indexed account);

    event GlobalPauseSet(bool isPaused);
    event RiskComputationPauseSet(bool isPaused);
    event WithdrawPreviewPauseSet(bool isPaused);
    event EmergencyModeUpdated(bool globalPaused, bool riskComputationPaused, bool withdrawPreviewPaused);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;
    address public guardian;

    ICollateralVaultPerpRiskView public collateralVault;
    IPerpEngineRiskView public perpEngine;
    IOracle public oracle;

    address public baseCollateralToken;
    uint256 public maxOracleDelay;

    bool public paused;
    bool public riskComputationPaused;
    bool public withdrawPreviewPaused;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != owner && msg.sender != guardian) revert NotAuthorized();
        _;
    }

    modifier whenRiskComputationNotPaused() {
        if (paused) revert PausedError();
        if (riskComputationPaused) revert RiskComputationPaused();
        _;
    }

    modifier whenWithdrawPreviewNotPaused() {
        if (paused) revert PausedError();
        if (withdrawPreviewPaused) revert WithdrawPreviewPaused();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _owner,
        address _vault,
        address _perpEngine,
        address _oracle,
        address _baseCollateralToken
    ) {
        if (
            _owner == address(0) || _vault == address(0) || _perpEngine == address(0) || _oracle == address(0)
                || _baseCollateralToken == address(0)
        ) {
            revert ZeroAddress();
        }

        owner = _owner;
        collateralVault = ICollateralVaultPerpRiskView(_vault);
        perpEngine = IPerpEngineRiskView(_perpEngine);
        oracle = IOracle(_oracle);
        baseCollateralToken = _baseCollateralToken;

        emit OwnershipTransferred(address(0), _owner);
        emit VaultSet(address(0), _vault);
        emit PerpEngineSet(address(0), _perpEngine);
        emit OracleSet(address(0), _oracle);
        emit BaseCollateralTokenSet(address(0), _baseCollateralToken);
        emit EmergencyModeUpdated(false, false, false);
    }

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

    function setGuardian(address newGuardian) external onlyOwner {
        address old = guardian;
        guardian = newGuardian;
        emit GuardianSet(old, newGuardian);
    }

    function setPerpEngine(address newEngine) external onlyOwner {
        if (newEngine == address(0)) revert ZeroAddress();
        address old = address(perpEngine);
        perpEngine = IPerpEngineRiskView(newEngine);
        emit PerpEngineSet(old, newEngine);
    }

    function setOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert ZeroAddress();
        address old = address(oracle);
        oracle = IOracle(newOracle);
        emit OracleSet(old, newOracle);
    }

    function setVault(address newVault) external onlyOwner {
        if (newVault == address(0)) revert ZeroAddress();
        address old = address(collateralVault);
        collateralVault = ICollateralVaultPerpRiskView(newVault);
        emit VaultSet(old, newVault);
    }

    function setBaseCollateralToken(address newBaseToken) external onlyOwner {
        if (newBaseToken == address(0)) revert ZeroAddress();
        address old = baseCollateralToken;
        baseCollateralToken = newBaseToken;
        emit BaseCollateralTokenSet(old, newBaseToken);
    }

    function setMaxOracleDelay(uint256 newDelay) external onlyOwner {
        if (newDelay > 3600) revert InvalidParams();
        uint256 old = maxOracleDelay;
        maxOracleDelay = newDelay;
        emit MaxOracleDelaySet(old, newDelay);
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSES
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyGuardianOrOwner {
        if (!paused) {
            paused = true;
            emit Paused(msg.sender);
            emit GlobalPauseSet(true);
            emit EmergencyModeUpdated(paused, riskComputationPaused, withdrawPreviewPaused);
        }
    }

    function unpause() external onlyOwner {
        if (paused) {
            paused = false;
            emit Unpaused(msg.sender);
            emit GlobalPauseSet(false);
            emit EmergencyModeUpdated(paused, riskComputationPaused, withdrawPreviewPaused);
        }
    }

    function pauseRiskComputation() external onlyGuardianOrOwner {
        if (!riskComputationPaused) {
            riskComputationPaused = true;
            emit RiskComputationPauseSet(true);
            emit EmergencyModeUpdated(paused, riskComputationPaused, withdrawPreviewPaused);
        }
    }

    function unpauseRiskComputation() external onlyOwner {
        if (riskComputationPaused) {
            riskComputationPaused = false;
            emit RiskComputationPauseSet(false);
            emit EmergencyModeUpdated(paused, riskComputationPaused, withdrawPreviewPaused);
        }
    }

    function pauseWithdrawPreviews() external onlyGuardianOrOwner {
        if (!withdrawPreviewPaused) {
            withdrawPreviewPaused = true;
            emit WithdrawPreviewPauseSet(true);
            emit EmergencyModeUpdated(paused, riskComputationPaused, withdrawPreviewPaused);
        }
    }

    function unpauseWithdrawPreviews() external onlyOwner {
        if (withdrawPreviewPaused) {
            withdrawPreviewPaused = false;
            emit WithdrawPreviewPauseSet(false);
            emit EmergencyModeUpdated(paused, riskComputationPaused, withdrawPreviewPaused);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _pow10(uint256 exp) internal pure returns (uint256) {
        if (exp > MAX_POW10_EXP) revert MathOverflow();
        return 10 ** exp;
    }

    function _vaultCfg(address token)
        internal
        view
        returns (ICollateralVaultPerpRiskView.CollateralTokenConfig memory cfg)
    {
        cfg = collateralVault.getCollateralConfig(token);
    }

    function _loadBase() internal view returns (address base, uint8 baseDec, uint256 baseScale) {
        base = baseCollateralToken;
        if (base == address(0)) revert BaseTokenNotConfigured();

        ICollateralVaultPerpRiskView.CollateralTokenConfig memory cfg = _vaultCfg(base);
        if (!cfg.isSupported) revert TokenNotSupported(base);
        if (cfg.decimals == 0) revert TokenDecimalsMissing(base);
        if (uint256(cfg.decimals) > MAX_POW10_EXP) revert TokenDecimalsOverflow(base);

        baseDec = cfg.decimals;
        baseScale = _pow10(uint256(baseDec));
    }

    function _effectiveBalanceOf(address user, address token) internal view returns (uint256) {
        try collateralVault.balanceWithYield(user, token) returns (uint256 b) {
            return b;
        } catch {
            return collateralVault.balances(user, token);
        }
    }

    function _isOracleDataFresh(uint256 updatedAt) internal view returns (bool) {
        uint256 d = maxOracleDelay;
        if (d == 0) return true;
        if (updatedAt == 0) return false;
        if (updatedAt > block.timestamp) return false;
        return (block.timestamp - updatedAt) <= d;
    }

    function _tryGetPrice(address base, address quote) internal view returns (uint256 price, bool ok) {
        {
            (bool success, bytes memory data) =
                address(oracle).staticcall(abi.encodeWithSignature("getPriceSafe(address,address)", base, quote));

            if (success && data.length >= 96) {
                (uint256 p, uint256 updatedAt, bool okSafe) = abi.decode(data, (uint256, uint256, bool));
                if (!okSafe || p == 0) return (0, false);
                if (!_isOracleDataFresh(updatedAt)) return (0, false);
                return (p, true);
            }
        }

        try oracle.getPrice(base, quote) returns (uint256 p, uint256 updatedAt) {
            if (p == 0) return (0, false);
            if (!_isOracleDataFresh(updatedAt)) return (0, false);
            return (p, true);
        } catch {
            return (0, false);
        }
    }

    function _tokenAmountToBaseValue(address token, uint256 tokenAmountNative, uint256 price1e8)
        internal
        view
        returns (uint256 baseValue)
    {
        ICollateralVaultPerpRiskView.CollateralTokenConfig memory baseCfg = _vaultCfg(baseCollateralToken);
        ICollateralVaultPerpRiskView.CollateralTokenConfig memory tokCfg = _vaultCfg(token);

        uint8 baseDec = baseCfg.decimals;
        uint8 tokenDec = tokCfg.decimals;

        uint256 tmp = Math.mulDiv(tokenAmountNative, price1e8, PRICE_SCALE, Math.Rounding.Floor);

        if (baseDec == tokenDec) return tmp;

        if (baseDec > tokenDec) {
            uint256 factor = _pow10(uint256(baseDec - tokenDec));
            return Math.mulDiv(tmp, factor, 1, Math.Rounding.Floor);
        }

        uint256 factor2 = _pow10(uint256(tokenDec - baseDec));
        return tmp / factor2;
    }

    function _baseValueToTokenAmount(address token, uint256 baseValue, uint256 price1e8)
        internal
        view
        returns (uint256 tokenAmount)
    {
        ICollateralVaultPerpRiskView.CollateralTokenConfig memory baseCfg = _vaultCfg(baseCollateralToken);
        ICollateralVaultPerpRiskView.CollateralTokenConfig memory tokCfg = _vaultCfg(token);

        uint8 baseDec = baseCfg.decimals;
        uint8 tokenDec = tokCfg.decimals;

        uint256 tmp = Math.mulDiv(baseValue, PRICE_SCALE, price1e8, Math.Rounding.Floor);

        if (baseDec == tokenDec) return tmp;

        if (tokenDec > baseDec) {
            uint256 factor = _pow10(uint256(tokenDec - baseDec));
            return Math.mulDiv(tmp, factor, 1, Math.Rounding.Floor);
        }

        uint256 factor2 = _pow10(uint256(baseDec - tokenDec));
        return tmp / factor2;
    }

    function _quote1e8ToTokenNative(address token, uint256 amount1e8) internal view returns (uint256 amountNative) {
        ICollateralVaultPerpRiskView.CollateralTokenConfig memory cfg = _vaultCfg(token);
        if (!cfg.isSupported) revert TokenNotSupported(token);
        if (cfg.decimals == 0) revert TokenDecimalsMissing(token);
        if (uint256(cfg.decimals) > MAX_POW10_EXP) revert TokenDecimalsOverflow(token);

        uint256 scale = _pow10(uint256(cfg.decimals));
        amountNative = Math.mulDiv(amount1e8, scale, PRICE_SCALE, Math.Rounding.Down);
    }

    function _toInt256(uint256 x) internal pure returns (int256 y) {
        if (x > uint256(type(int256).max)) revert MathOverflow();
        y = int256(x);
    }

    function _checkedAddInt256(int256 a, int256 b) internal pure returns (int256 r) {
        unchecked {
            r = a + b;
        }
        if (b > 0 && r < a) revert MathOverflow();
        if (b < 0 && r > a) revert MathOverflow();
    }

    function _checkedSubInt256(int256 a, int256 b) internal pure returns (int256 r) {
        unchecked {
            r = a - b;
        }
        if (b > 0 && r > a) revert MathOverflow();
        if (b < 0 && r < a) revert MathOverflow();
    }

    function _marginRatioBps(int256 equityBase, uint256 maintenanceMarginBase) internal pure returns (uint256) {
        if (maintenanceMarginBase == 0) return type(uint256).max;
        if (equityBase <= 0) return 0;
        return (uint256(equityBase) * BPS) / maintenanceMarginBase;
    }

    function _tryGetSettlementAsset(uint256 marketId) internal view returns (address settlementAsset, bool ok) {
        try IPerpEngineSettlementAssetView(address(perpEngine)).getSettlementAsset(marketId) returns (address asset) {
            if (asset == address(0)) return (address(0), false);
            return (asset, true);
        } catch {
            return (address(0), false);
        }
    }

    function _tryGetResidualBadDebtBase(address trader) internal view returns (uint256 badDebtBase, bool ok) {
        try IPerpEngineBadDebtView(address(perpEngine)).getResidualBadDebt(trader) returns (uint256 debt) {
            return (debt, true);
        } catch {
            return (0, false);
        }
    }

    function _convertQuote1e8ToBaseWithSettlement(uint256 amount1e8, address settlementAsset)
        internal
        view
        returns (uint256 valueBase)
    {
        if (amount1e8 == 0) return 0;

        address base = baseCollateralToken;
        if (base == address(0)) revert BaseTokenNotConfigured();

        if (settlementAsset == address(0) || settlementAsset == base) {
            return _convertQuote1e8ToBase(amount1e8);
        }

        uint256 settlementAmountNative = _quote1e8ToTokenNative(settlementAsset, amount1e8);

        (uint256 px, bool okPx) = _tryGetPrice(settlementAsset, base);
        if (!okPx || px == 0) revert InvalidParams();

        valueBase = _tokenAmountToBaseValue(settlementAsset, settlementAmountNative, px);
    }

    function _convertSignedQuote1e8ToBaseWithSettlement(int256 amount1e8, address settlementAsset)
        internal
        view
        returns (int256 valueBase)
    {
        if (amount1e8 == 0) return 0;

        uint256 absAmt = amount1e8 >= 0 ? uint256(amount1e8) : uint256(-amount1e8);
        int256 absBase = _toInt256(_convertQuote1e8ToBaseWithSettlement(absAmt, settlementAsset));

        return amount1e8 >= 0 ? absBase : -absBase;
    }

    function _computeCollateralEquityBase(address trader) internal view returns (uint256 totalEquityBase) {
        _loadBase();
        address[] memory tokens = collateralVault.getCollateralTokens();

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (token == address(0)) continue;

            ICollateralVaultPerpRiskView.CollateralTokenConfig memory cfg = _vaultCfg(token);
            if (!cfg.isSupported || cfg.collateralFactorBps == 0) continue;
            if (cfg.decimals == 0) revert TokenDecimalsMissing(token);
            if (uint256(cfg.decimals) > MAX_POW10_EXP) revert TokenDecimalsOverflow(token);

            uint256 bal = _effectiveBalanceOf(trader, token);
            if (bal == 0) continue;

            uint256 valueBase;
            if (token == baseCollateralToken) {
                valueBase = bal;
            } else {
                (uint256 px, bool okPx) = _tryGetPrice(token, baseCollateralToken);
                if (!okPx || px == 0) continue;
                valueBase = _tokenAmountToBaseValue(token, bal, px);
            }

            uint256 adjusted =
                Math.mulDiv(valueBase, uint256(cfg.collateralFactorBps), BPS, Math.Rounding.Floor);

            totalEquityBase += adjusted;
        }
    }

    function _computePerpAggregate(address trader) internal view returns (PerpAggregate memory agg) {
        uint256 len = perpEngine.getTraderMarketsLength(trader);

        for (uint256 start = 0; start < len; start += SERIES_PAGE) {
            uint256 end = start + SERIES_PAGE;
            if (end > len) end = len;

            uint256[] memory marketIds = perpEngine.getTraderMarketsSlice(trader, start, end);

            for (uint256 i = 0; i < marketIds.length; i++) {
                uint256 marketId = marketIds[i];

                int256 size1e8 = perpEngine.getPositionSize(trader, marketId);
                if (size1e8 == 0) continue;

                uint256 markPrice1e8 = perpEngine.getMarkPrice(marketId);
                if (markPrice1e8 == 0) revert InvalidParams();

                uint256 absSize1e8 = size1e8 >= 0 ? uint256(size1e8) : uint256(-size1e8);
                uint256 notional1e8 = Math.mulDiv(absSize1e8, markPrice1e8, PRICE_SCALE, Math.Rounding.Down);

                IPerpEngineRiskView.RiskConfig memory rcfg = perpEngine.getRiskConfig(marketId);

                uint256 mm1e8 =
                    Math.mulDiv(notional1e8, uint256(rcfg.maintenanceMarginBps), BPS, Math.Rounding.Ceil);
                uint256 im1e8 =
                    Math.mulDiv(notional1e8, uint256(rcfg.initialMarginBps), BPS, Math.Rounding.Ceil);

                (address settlementAsset, bool hasSettlementAsset) = _tryGetSettlementAsset(marketId);
                address effectiveSettlement = hasSettlementAsset ? settlementAsset : baseCollateralToken;

                uint256 mmBase = _convertQuote1e8ToBaseWithSettlement(mm1e8, effectiveSettlement);
                uint256 imBase = _convertQuote1e8ToBaseWithSettlement(im1e8, effectiveSettlement);

                agg.maintenanceMarginBase += mmBase;
                agg.initialMarginBase += imBase;

                int256 upnl1e8 = perpEngine.getUnrealizedPnl(trader, marketId);
                int256 funding1e8 = perpEngine.getPositionFundingAccrued(trader, marketId);

                int256 upnlBase = _convertSignedQuote1e8ToBaseWithSettlement(upnl1e8, effectiveSettlement);
                int256 fundingBase = _convertSignedQuote1e8ToBaseWithSettlement(funding1e8, effectiveSettlement);

                agg.unrealizedPnlBase = _checkedAddInt256(agg.unrealizedPnlBase, upnlBase);
                agg.fundingAccruedBase = _checkedAddInt256(agg.fundingAccruedBase, fundingBase);
            }
        }

        agg.netPerpPnlBase = _checkedSubInt256(agg.unrealizedPnlBase, agg.fundingAccruedBase);

        (uint256 badDebtBase, bool okBadDebt) = _tryGetResidualBadDebtBase(trader);
        if (okBadDebt) {
            agg.residualBadDebtBase = badDebtBase;
        }
    }

    function _computeAccountComponents(address trader) internal view returns (AccountComponents memory comps) {
        comps.collateralEquityBase = _computeCollateralEquityBase(trader);
        comps.perp = _computePerpAggregate(trader);

        int256 equity = _checkedAddInt256(_toInt256(comps.collateralEquityBase), comps.perp.netPerpPnlBase);

        if (comps.perp.residualBadDebtBase != 0) {
            equity = _checkedSubInt256(equity, _toInt256(comps.perp.residualBadDebtBase));
        }

        comps.equityBase = equity;
    }

    function _convertQuote1e8ToBase(uint256 amount1e8) internal view returns (uint256 valueBase) {
        (, uint8 baseDec, uint256 baseScale) = _loadBase();
        baseDec;
        valueBase = Math.mulDiv(amount1e8, baseScale, PRICE_SCALE, Math.Rounding.Down);
    }

    function _convertSignedQuote1e8ToBase(int256 amount1e8) internal view returns (int256 valueBase) {
        if (amount1e8 == 0) return 0;

        uint256 absAmt = amount1e8 >= 0 ? uint256(amount1e8) : uint256(-amount1e8);
        int256 absBase = _toInt256(_convertQuote1e8ToBase(absAmt));

        return amount1e8 >= 0 ? absBase : -absBase;
    }

    function _withdrawDeltaEquityBase(address token, uint256 amountNative) internal view returns (uint256 deltaEquityBase) {
        if (amountNative == 0) return 0;

        ICollateralVaultPerpRiskView.CollateralTokenConfig memory cfg = _vaultCfg(token);
        if (!cfg.isSupported || cfg.collateralFactorBps == 0) return 0;
        if (cfg.decimals == 0) revert TokenDecimalsMissing(token);
        if (uint256(cfg.decimals) > MAX_POW10_EXP) revert TokenDecimalsOverflow(token);

        uint256 valueBase;
        if (token == baseCollateralToken) {
            valueBase = amountNative;
        } else {
            (uint256 px, bool okPx) = _tryGetPrice(token, baseCollateralToken);
            if (!okPx || px == 0) return type(uint256).max;
            valueBase = _tokenAmountToBaseValue(token, amountNative, px);
        }

        deltaEquityBase = Math.mulDiv(valueBase, uint256(cfg.collateralFactorBps), BPS, Math.Rounding.Floor);
    }

    /*//////////////////////////////////////////////////////////////
                                CORE VIEWS
    //////////////////////////////////////////////////////////////*/

    function computeAccountRisk(address trader)
        public
        view
        whenRiskComputationNotPaused
        returns (AccountRisk memory risk)
    {
        _loadBase();

        AccountComponents memory comps = _computeAccountComponents(trader);

        risk.equityBase = comps.equityBase;
        risk.maintenanceMarginBase = comps.perp.maintenanceMarginBase;
        risk.initialMarginBase = comps.perp.initialMarginBase;
    }

    function computeCollateralEquity(address trader) external view whenRiskComputationNotPaused returns (uint256) {
        _loadBase();
        return _computeCollateralEquityBase(trader);
    }

    function computePerpAggregate(address trader)
        external
        view
        whenRiskComputationNotPaused
        returns (PerpAggregate memory agg)
    {
        _loadBase();
        return _computePerpAggregate(trader);
    }

    function computeFreeCollateral(address trader)
        external
        view
        whenRiskComputationNotPaused
        returns (int256 freeCollateralBase)
    {
        AccountRisk memory risk = computeAccountRisk(trader);
        if (risk.initialMarginBase == 0) return risk.equityBase;
        return _checkedSubInt256(risk.equityBase, _toInt256(risk.initialMarginBase));
    }

    function computeMarginRatioBps(address trader)
        external
        view
        whenRiskComputationNotPaused
        returns (uint256)
    {
        AccountRisk memory risk = computeAccountRisk(trader);
        return _marginRatioBps(risk.equityBase, risk.maintenanceMarginBase);
    }

    /*//////////////////////////////////////////////////////////////
                            WITHDRAW PREVIEWS
    //////////////////////////////////////////////////////////////*/

    function getWithdrawableAmount(address trader, address token)
        public
        view
        whenWithdrawPreviewNotPaused
        returns (uint256 amount)
    {
        uint256 avail = _effectiveBalanceOf(trader, token);
        if (avail == 0) return 0;

        _loadBase();

        ICollateralVaultPerpRiskView.CollateralTokenConfig memory cfg = _vaultCfg(token);
        if (!cfg.isSupported) revert TokenNotSupported(token);

        if (cfg.collateralFactorBps == 0) return avail;
        if (cfg.decimals == 0) revert TokenDecimalsMissing(token);
        if (uint256(cfg.decimals) > MAX_POW10_EXP) revert TokenDecimalsOverflow(token);

        AccountRisk memory risk = computeAccountRisk(trader);

        int256 freeBase = risk.initialMarginBase == 0
            ? risk.equityBase
            : _checkedSubInt256(risk.equityBase, _toInt256(risk.initialMarginBase));

        if (freeBase <= 0) return 0;

        uint256 freeBaseU = uint256(freeBase);
        uint256 valueBaseMax =
            Math.mulDiv(freeBaseU, BPS, uint256(cfg.collateralFactorBps), Math.Rounding.Floor);

        uint256 maxToken;
        if (token == baseCollateralToken) {
            maxToken = valueBaseMax;
        } else {
            (uint256 px, bool okPx) = _tryGetPrice(token, baseCollateralToken);
            if (!okPx || px == 0) return 0;
            maxToken = _baseValueToTokenAmount(token, valueBaseMax, px);
        }

        amount = maxToken < avail ? maxToken : avail;
    }

    function previewWithdrawImpact(address trader, address token, uint256 amount)
        external
        view
        whenWithdrawPreviewNotPaused
        returns (WithdrawPreview memory preview)
    {
        preview.requestedAmount = amount;

        uint256 avail = _effectiveBalanceOf(trader, token);
        AccountRisk memory riskBefore = computeAccountRisk(trader);

        uint256 mrBefore = _marginRatioBps(riskBefore.equityBase, riskBefore.maintenanceMarginBase);
        uint256 maxAllowed = getWithdrawableAmount(trader, token);

        preview.maxWithdrawable = maxAllowed;
        preview.marginRatioBeforeBps = mrBefore;

        uint256 cappedReq = amount > avail ? avail : amount;
        uint256 effectiveAmount = cappedReq > maxAllowed ? maxAllowed : cappedReq;

        uint256 deltaEquityBase = _withdrawDeltaEquityBase(token, effectiveAmount);

        int256 equityAfterBase;
        if (deltaEquityBase == type(uint256).max) {
            equityAfterBase = type(int256).min;
        } else {
            equityAfterBase = _checkedSubInt256(riskBefore.equityBase, _toInt256(deltaEquityBase));
        }

        uint256 mrAfter = _marginRatioBps(equityAfterBase, riskBefore.maintenanceMarginBase);

        bool breach = amount > maxAllowed;
        if (!breach && riskBefore.initialMarginBase != 0) {
            if (equityAfterBase < _toInt256(riskBefore.initialMarginBase)) breach = true;
        }

        preview.marginRatioAfterBps = mrAfter;
        preview.wouldBreachMargin = breach;
    }
}