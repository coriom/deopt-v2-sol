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

/// @title PerpRiskModule
/// @notice Risk module dedicated to the perpetual engine.
/// @dev
///  Conventions:
///   - prices normalized in 1e8
///   - equity / IM / MM expressed in base collateral token native units
///   - collateral valuation uses CollateralVault.collateralFactorBps as haircut
///   - account equity = adjusted collateral + unrealized PnL - accrued funding
///
///  Design:
///   - collateral universe is read directly from CollateralVault
///   - open markets are paginated through PerpEngine
///   - best-effort oracle reads for collateral conversions
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

    struct AccountRisk {
        int256 equity1e8;
        uint256 maintenanceMargin1e8;
        uint256 initialMargin1e8;
    }

    struct WithdrawPreview {
        uint256 requestedAmount;
        uint256 maxWithdrawable;
        uint256 marginRatioBeforeBps;
        uint256 marginRatioAfterBps;
        bool wouldBreachMargin;
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

    function _tokenAmountToBaseValue(address token, uint256 tokenAmount, uint256 price1e8)
        internal
        view
        returns (uint256 baseValue)
    {
        ICollateralVaultPerpRiskView.CollateralTokenConfig memory baseCfg = _vaultCfg(baseCollateralToken);
        ICollateralVaultPerpRiskView.CollateralTokenConfig memory tokCfg = _vaultCfg(token);

        uint8 baseDec = baseCfg.decimals;
        uint8 tokenDec = tokCfg.decimals;

        uint256 tmp = Math.mulDiv(tokenAmount, price1e8, PRICE_SCALE, Math.Rounding.Floor);

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

    function _computeCollateralEquityBase(address trader) internal view returns (uint256 totalEquityBase) {
        (, uint8 baseDec,) = _loadBase();
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
                if (!okPx) continue;
                valueBase = _tokenAmountToBaseValue(token, bal, px);
            }

            uint256 adjusted =
                Math.mulDiv(valueBase, uint256(cfg.collateralFactorBps), BPS, Math.Rounding.Floor);

            totalEquityBase += adjusted;
        }

        baseDec; // silence possible future ref usage
    }

    function _computePerpMargins(address trader)
        internal
        view
        returns (uint256 maintenanceMarginBase, uint256 initialMarginBase, int256 pnlBase)
    {
        uint256 len = perpEngine.getTraderMarketsLength(trader);
        address base = baseCollateralToken;

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

                uint256 absSize = size1e8 >= 0 ? uint256(size1e8) : uint256(-size1e8);
                uint256 notional1e8 = Math.mulDiv(absSize, markPrice1e8, PRICE_SCALE, Math.Rounding.Down);

                IPerpEngineRiskView.RiskConfig memory rcfg = perpEngine.getRiskConfig(marketId);

                uint256 mm1e8 =
                    Math.mulDiv(notional1e8, uint256(rcfg.maintenanceMarginBps), BPS, Math.Rounding.Ceil);
                uint256 im1e8 =
                    Math.mulDiv(notional1e8, uint256(rcfg.initialMarginBps), BPS, Math.Rounding.Ceil);

                uint256 mmBase;
                uint256 imBase;

                if (base == address(0)) revert BaseTokenNotConfigured();

                if (base == baseCollateralToken) {
                    // noop for readability
                }

                if (base == baseCollateralToken) {
                    // convert from quote 1e8 to base native units
                    // assumes perpEngine mark price is underlying/settlement and risk/pnl are quote 1e8 units.
                    // base collateral should be same as quote settlement economic unit through oracle if needed.
                }

                mmBase = _convertQuote1e8ToBase(mm1e8);
                imBase = _convertQuote1e8ToBase(im1e8);

                maintenanceMarginBase += mmBase;
                initialMarginBase += imBase;

                int256 upnl1e8 = perpEngine.getUnrealizedPnl(trader, marketId);
                int256 funding1e8 = perpEngine.getPositionFundingAccrued(trader, marketId);

                int256 net1e8 = _checkedSubInt256(upnl1e8, funding1e8);
                int256 netBase = _convertSignedQuote1e8ToBase(net1e8);

                pnlBase = _checkedAddInt256(pnlBase, netBase);
            }
        }
    }

    function _convertQuote1e8ToBase(uint256 amount1e8) internal view returns (uint256 valueBase) {
        (address base,, uint256 baseScale) = _loadBase();

        // If base collateral is economically the quote numeraire, this is direct scaling.
        // If not, governance should choose the quote-like base collateral token for the perp module.
        base;
        valueBase = Math.mulDiv(amount1e8, baseScale, PRICE_SCALE, Math.Rounding.Down);
    }

    function _convertSignedQuote1e8ToBase(int256 amount1e8) internal view returns (int256 valueBase) {
        if (amount1e8 == 0) return 0;

        uint256 absAmt = amount1e8 >= 0 ? uint256(amount1e8) : uint256(-amount1e8);
        int256 absBase = _toInt256(_convertQuote1e8ToBase(absAmt));

        return amount1e8 >= 0 ? absBase : -absBase;
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

        uint256 collateralEquityBase = _computeCollateralEquityBase(trader);
        (uint256 mmBase, uint256 imBase, int256 pnlBase) = _computePerpMargins(trader);

        int256 equity = _checkedAddInt256(_toInt256(collateralEquityBase), pnlBase);

        risk.equity1e8 = equity;
        risk.maintenanceMargin1e8 = mmBase;
        risk.initialMargin1e8 = imBase;
    }

    function computeFreeCollateral(address trader)
        external
        view
        whenRiskComputationNotPaused
        returns (int256 freeCollateral)
    {
        AccountRisk memory risk = computeAccountRisk(trader);
        if (risk.initialMargin1e8 == 0) return risk.equity1e8;
        return _checkedSubInt256(risk.equity1e8, _toInt256(risk.initialMargin1e8));
    }

    function computeMarginRatioBps(address trader)
        external
        view
        whenRiskComputationNotPaused
        returns (uint256)
    {
        AccountRisk memory risk = computeAccountRisk(trader);
        return _marginRatioBps(risk.equity1e8, risk.maintenanceMargin1e8);
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

        // Non-margin token => unrestricted
        if (cfg.collateralFactorBps == 0) return avail;

        if (cfg.decimals == 0) revert TokenDecimalsMissing(token);
        if (uint256(cfg.decimals) > MAX_POW10_EXP) revert TokenDecimalsOverflow(token);

        AccountRisk memory risk = computeAccountRisk(trader);

        int256 free = risk.initialMargin1e8 == 0
            ? risk.equity1e8
            : _checkedSubInt256(risk.equity1e8, _toInt256(risk.initialMargin1e8));

        if (free <= 0) return 0;
        if (risk.maintenanceMargin1e8 == 0) return avail;

        uint256 freeBase = uint256(free);
        uint256 valueBaseMax =
            Math.mulDiv(freeBase, BPS, uint256(cfg.collateralFactorBps), Math.Rounding.Floor);

        uint256 maxToken;
        if (token == baseCollateralToken) {
            maxToken = valueBaseMax;
        } else {
            (uint256 px, bool okPx) = _tryGetPrice(token, baseCollateralToken);
            if (!okPx) return 0;
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

        uint256 mrBefore = _marginRatioBps(riskBefore.equity1e8, riskBefore.maintenanceMargin1e8);
        uint256 maxAllowed = getWithdrawableAmount(trader, token);

        preview.maxWithdrawable = maxAllowed;
        preview.marginRatioBeforeBps = mrBefore;

        uint256 cappedReq = amount > avail ? avail : amount;
        uint256 effectiveAmount = cappedReq > maxAllowed ? maxAllowed : cappedReq;

        uint256 deltaEquityBase = 0;

        if (effectiveAmount > 0) {
            ICollateralVaultPerpRiskView.CollateralTokenConfig memory cfg = _vaultCfg(token);
            if (cfg.isSupported && cfg.collateralFactorBps > 0) {
                uint256 valueBase;
                if (token == baseCollateralToken) {
                    valueBase = effectiveAmount;
                } else {
                    (uint256 px, bool okPx) = _tryGetPrice(token, baseCollateralToken);
                    if (!okPx) {
                        deltaEquityBase = uint256(type(int256).max);
                    } else {
                        valueBase = _tokenAmountToBaseValue(token, effectiveAmount, px);
                    }
                }

                if (deltaEquityBase == 0) {
                    deltaEquityBase =
                        Math.mulDiv(valueBase, uint256(cfg.collateralFactorBps), BPS, Math.Rounding.Floor);
                }
            }
        }

        int256 equityAfter = _checkedSubInt256(riskBefore.equity1e8, _toInt256(deltaEquityBase));
        uint256 mrAfter = _marginRatioBps(equityAfter, riskBefore.maintenanceMargin1e8);

        bool breach = amount > maxAllowed;
        if (!breach && riskBefore.initialMargin1e8 != 0) {
            if (equityAfter < _toInt256(riskBefore.initialMargin1e8)) breach = true;
        }

        preview.marginRatioAfterBps = mrAfter;
        preview.wouldBreachMargin = breach;
    }
}