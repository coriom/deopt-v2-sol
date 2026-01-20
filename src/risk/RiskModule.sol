// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "../CollateralVault.sol";
import "../OptionProductRegistry.sol";
import "../oracle/IOracle.sol";
import "./IRiskModule.sol";
import "./IMarginEngineState.sol";

/// @notice RiskModule DeOpt v2 (prod-hardened)
/// @dev Changes vs your version:
///  - Equity includes conservative short liability (intrinsic) => avoids "equity ignores positions" hole.
///  - Strict decimals: no silent fallback to 18 for configured/active tokens.
///  - Oracle-down MM conversion: apply multiplier (configurable) instead of weak fallback.
///  - Optional local staleness guard kept (maxOracleDelay), bounded.
contract RiskModule is IRiskModule {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event RiskParamsSet(
        address baseCollateralToken,
        uint256 baseMaintenanceMarginPerContract,
        uint256 imFactorBps
    );

    event OracleSet(address indexed newOracle);
    event MarginEngineSet(address indexed newMarginEngine);

    event CollateralConfigSet(address indexed token, uint64 weightBps, bool isEnabled);

    event MaxOracleDelaySet(uint256 maxOracleDelay);

    /// @notice Multiplier used when conversion settlement->base fails (oracle down), in bps (ex: 20000 = 2x).
    event OracleDownMmMultiplierSet(uint256 multiplierBps);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error ZeroAddress();
    error InvalidParams();

    // strict config
    error BaseTokenNotConfigured();
    error TokenNotConfigured(address token);
    error TokenDecimalsNotConfigured(address token);
    error TokenNotSupportedInVault(address token);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;

    CollateralVault public collateralVault;
    OptionProductRegistry public optionRegistry;
    IMarginEngineState public marginEngine;
    IOracle public oracle;

    address public baseCollateralToken;
    uint256 public baseMaintenanceMarginPerContract;
    uint256 public imFactorBps;

    /// @dev Optional local staleness guard. OracleRouter already enforces freshness.
    /// If you want to rely ONLY on OracleRouter, set this to 0.
    uint256 public maxOracleDelay;

    /// @dev When settlement->base conversion fails (oracle down), we apply:
    /// mmBase = baseMaintenanceMarginPerContract * oracleDownMmMultiplierBps / 10_000
    /// Default 20000 = 2x.
    uint256 public oracleDownMmMultiplierBps = 20_000;

    struct CollateralConfig {
        uint64 weightBps; // haircut: 10000 = 100%, 8000 = 80%
        bool isEnabled;
    }

    mapping(address => CollateralConfig) public collateralConfigs;
    address[] public collateralTokens;
    mapping(address => bool) private isCollateralTokenListed;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _owner,
        address _vault,
        address _registry,
        address _marginEngine,
        address _oracle
    ) {
        if (
            _owner == address(0) ||
            _vault == address(0) ||
            _registry == address(0) ||
            _marginEngine == address(0) ||
            _oracle == address(0)
        ) revert ZeroAddress();

        owner = _owner;
        collateralVault = CollateralVault(_vault);
        optionRegistry = OptionProductRegistry(_registry);
        marginEngine = IMarginEngineState(_marginEngine);
        oracle = IOracle(_oracle);

        emit OwnershipTransferred(address(0), _owner);
        emit MarginEngineSet(_marginEngine);
        emit OracleSet(_oracle);
        emit OracleDownMmMultiplierSet(oracleDownMmMultiplierBps);
    }

    /*//////////////////////////////////////////////////////////////
                          OWNERSHIP / CONFIG
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function renounceOwnership() external onlyOwner {
        address oldOwner = owner;
        owner = address(0);
        emit OwnershipTransferred(oldOwner, address(0));
    }

    function setMarginEngine(address _marginEngine) external onlyOwner {
        if (_marginEngine == address(0)) revert ZeroAddress();
        marginEngine = IMarginEngineState(_marginEngine);
        emit MarginEngineSet(_marginEngine);
    }

    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert ZeroAddress();
        oracle = IOracle(_oracle);
        emit OracleSet(_oracle);
    }

    function setMaxOracleDelay(uint256 _maxOracleDelay) external onlyOwner {
        // defensive bound (consistent with OracleRouter style)
        // 0 = disabled
        if (_maxOracleDelay > 3600) revert InvalidParams();
        maxOracleDelay = _maxOracleDelay;
        emit MaxOracleDelaySet(_maxOracleDelay);
    }

    function setOracleDownMmMultiplier(uint256 _multiplierBps) external onlyOwner {
        // must be >= 1x and <= 10x (tune if you want)
        if (_multiplierBps < 10_000 || _multiplierBps > 100_000) revert InvalidParams();
        oracleDownMmMultiplierBps = _multiplierBps;
        emit OracleDownMmMultiplierSet(_multiplierBps);
    }

    function setRiskParams(
        address _baseToken,
        uint256 _baseMMPerContract,
        uint256 _imFactorBps
    ) external onlyOwner {
        if (_baseToken == address(0)) revert ZeroAddress();
        if (_imFactorBps < 10_000) revert InvalidParams();

        baseCollateralToken = _baseToken;
        baseMaintenanceMarginPerContract = _baseMMPerContract;
        imFactorBps = _imFactorBps;

        emit RiskParamsSet(_baseToken, _baseMMPerContract, _imFactorBps);

        // auto-list base token with 100% weight
        if (!isCollateralTokenListed[_baseToken]) {
            collateralTokens.push(_baseToken);
            isCollateralTokenListed[_baseToken] = true;
        }
        collateralConfigs[_baseToken] = CollateralConfig({weightBps: 10_000, isEnabled: true});
        emit CollateralConfigSet(_baseToken, 10_000, true);
    }

    function setCollateralConfig(
        address token,
        uint64 weightBps,
        bool isEnabled
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (weightBps > 10_000) revert InvalidParams();

        if (!isCollateralTokenListed[token]) {
            collateralTokens.push(token);
            isCollateralTokenListed[token] = true;
        }

        collateralConfigs[token] = CollateralConfig({weightBps: weightBps, isEnabled: isEnabled});
        emit CollateralConfigSet(token, weightBps, isEnabled);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return collateralTokens;
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL: STRICT VAULT CONFIG HELPERS
    //////////////////////////////////////////////////////////////*/

    function _vaultCfg(address token)
        internal
        view
        returns (CollateralVault.CollateralTokenConfig memory cfg)
    {
        cfg = collateralVault.collateralConfigs(token);
    }

    function _requireBaseConfigured() internal view {
        if (baseCollateralToken == address(0)) revert BaseTokenNotConfigured();

        CollateralVault.CollateralTokenConfig memory baseCfg = _vaultCfg(baseCollateralToken);
        if (!baseCfg.isSupported) revert TokenNotSupportedInVault(baseCollateralToken);
        if (baseCfg.decimals == 0) revert TokenDecimalsNotConfigured(baseCollateralToken);
    }

    function _requireTokenConfiguredIfEnabled(address token) internal view {
        CollateralConfig memory rcfg = collateralConfigs[token];
        if (!rcfg.isEnabled) return;

        CollateralVault.CollateralTokenConfig memory vcfg = _vaultCfg(token);
        if (!vcfg.isSupported) revert TokenNotSupportedInVault(token);
        if (vcfg.decimals == 0) revert TokenDecimalsNotConfigured(token);
    }

    function _baseDecimals() internal view returns (uint8) {
        CollateralVault.CollateralTokenConfig memory baseCfg = _vaultCfg(baseCollateralToken);
        return baseCfg.decimals;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL: BALANCE HELPERS
    //////////////////////////////////////////////////////////////*/

    function _principalBalanceOf(address user, address token) internal view returns (uint256) {
        return collateralVault.balances(user, token);
    }

    function _effectiveBalanceOf(address user, address token) internal view returns (uint256) {
        try collateralVault.balanceWithYield(user, token) returns (uint256 b) {
            return b;
        } catch {
            return collateralVault.balances(user, token);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL: ORACLE SAFE HELPERS
    //////////////////////////////////////////////////////////////*/

    function _isOracleDataFresh(uint256 updatedAt) internal view returns (bool) {
        if (maxOracleDelay == 0) return true;
        if (updatedAt == 0) return false;
        if (updatedAt >= block.timestamp) return true;
        return (block.timestamp - updatedAt) <= maxOracleDelay;
    }

    /// @dev OracleRouter can revert: wrap to (0,false).
    function _tryGetPrice(address base, address quote)
        internal
        view
        returns (uint256 price, bool ok)
    {
        try oracle.getPrice(base, quote) returns (uint256 p, uint256 updatedAt) {
            if (p == 0) return (0, false);
            if (!_isOracleDataFresh(updatedAt)) return (0, false);
            return (p, true);
        } catch {
            return (0, false);
        }
    }

    /*//////////////////////////////////////////////////////////////
              INTERNAL: 1e8 (settlement units) -> base token units
    //////////////////////////////////////////////////////////////*/

    function _convert1e8SettlementToBase(
        address settlementAsset,
        uint256 value1e8
    ) internal view returns (uint256 valueBase, bool ok) {
        if (value1e8 == 0) return (0, true);

        _requireBaseConfigured();

        uint8 baseDec = _baseDecimals();
        uint256 baseScale = 10 ** uint256(baseDec);

        if (settlementAsset == baseCollateralToken) {
            // value1e8 * baseScale / 1e8 => base decimals
            return (Math.mulDiv(value1e8, baseScale, 1e8), true);
        }

        // We need settlementAsset->base price (1e8)
        (uint256 px, bool okPx) = _tryGetPrice(settlementAsset, baseCollateralToken);
        if (!okPx) return (0, false);

        // valueBase = value1e8 * px / 1e8 => 1e8, then * baseScale / 1e8 => base decimals
        uint256 v1e8 = Math.mulDiv(value1e8, px, 1e8);
        valueBase = Math.mulDiv(v1e8, baseScale, 1e8);
        return (valueBase, true);
    }

    /*//////////////////////////////////////////////////////////////
              INTERNAL: conservative short liability (intrinsic)
    //////////////////////////////////////////////////////////////*/

    function _computePerContractIntrinsic1e8(
        OptionProductRegistry.OptionSeries memory s,
        uint256 spot1e8,
        bool hasSpot
    ) internal pure returns (uint256 intrinsic1e8) {
        uint256 spotLocal = hasSpot ? spot1e8 : uint256(s.strike);

        if (s.isCall) {
            return spotLocal > uint256(s.strike) ? (spotLocal - uint256(s.strike)) : 0;
        } else {
            return uint256(s.strike) > spotLocal ? (uint256(s.strike) - spotLocal) : 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL: PER-CONTRACT MM LOGIC
    //////////////////////////////////////////////////////////////*/

    function _computePerContractMM(
        OptionProductRegistry.OptionSeries memory s,
        uint256 spot1e8,
        OptionProductRegistry.UnderlyingConfig memory cfg,
        bool hasSpot
    ) internal view returns (uint256 mmBase) {
        if (baseMaintenanceMarginPerContract == 0) return 0;
        if (baseCollateralToken == address(0)) return 0;

        // If underlying is not enabled => fallback to base MM (simple / conservative).
        if (!cfg.isEnabled) {
            return baseMaintenanceMarginPerContract;
        }

        uint256 spotLocal = hasSpot ? spot1e8 : uint256(s.strike);
        uint256 mmPrice1e8;

        if (s.isCall) {
            uint256 shockedSpot =
                Math.mulDiv(spotLocal, (10_000 + uint256(cfg.spotShockUpBps)), 10_000);
            uint256 intrinsicShock =
                shockedSpot > uint256(s.strike) ? (shockedSpot - uint256(s.strike)) : 0;
            uint256 floorPrice =
                Math.mulDiv(spotLocal, uint256(cfg.volShockUpBps), 10_000);
            mmPrice1e8 = intrinsicShock > floorPrice ? intrinsicShock : floorPrice;
        } else {
            uint256 shockDownBps = uint256(cfg.spotShockDownBps);
            if (shockDownBps > 10_000) shockDownBps = 10_000;
            uint256 shockedSpot =
                Math.mulDiv(spotLocal, (10_000 - shockDownBps), 10_000);
            uint256 intrinsicShock =
                uint256(s.strike) > shockedSpot ? (uint256(s.strike) - shockedSpot) : 0;
            uint256 floorPrice =
                Math.mulDiv(uint256(s.strike), uint256(cfg.volShockUpBps), 10_000);
            mmPrice1e8 = intrinsicShock > floorPrice ? intrinsicShock : floorPrice;
        }

        (uint256 converted, bool okConv) = _convert1e8SettlementToBase(s.settlementAsset, mmPrice1e8);

        if (!okConv || converted == 0) {
            // Oracle down or conversion failed => apply conservative multiplier
            uint256 bumped =
                Math.mulDiv(baseMaintenanceMarginPerContract, oracleDownMmMultiplierBps, 10_000);
            return bumped;
        }

        // Ensure minimum MM floor
        if (converted < baseMaintenanceMarginPerContract) {
            converted = baseMaintenanceMarginPerContract;
        }

        // NOTE: TTE scaling removed for prod safety (gamma risk near expiry, etc.).
        // If you really want it back, we can re-add as configurable params.

        return converted;
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL: MULTI-COLLATERAL EQUITY
    //////////////////////////////////////////////////////////////*/

    function _computeCollateralEquityBase(address trader) internal view returns (uint256 totalEquityBase) {
        _requireBaseConfigured();

        uint8 baseDec = _baseDecimals();

        // strict: base token must also be enabled in risk module config to contribute
        // (it is auto-enabled in setRiskParams, but this makes failure explicit)
        CollateralConfig memory baseRiskCfg = collateralConfigs[baseCollateralToken];
        if (!baseRiskCfg.isEnabled) revert TokenNotConfigured(baseCollateralToken);

        // Validate enabled collateral tokens are configured in vault
        // (prevents silent decimals fallbacks)
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            _requireTokenConfiguredIfEnabled(collateralTokens[i]);
        }

        for (uint256 i = 0; i < collateralTokens.length; i++) {
            address token = collateralTokens[i];
            CollateralConfig memory rcfg = collateralConfigs[token];
            if (!rcfg.isEnabled) continue;

            uint256 bal = _effectiveBalanceOf(trader, token);
            if (bal == 0) continue;

            uint256 valueBase;

            if (token == baseCollateralToken) {
                // already in base units
                valueBase = bal;
            } else {
                CollateralVault.CollateralTokenConfig memory tCfg = _vaultCfg(token);
                uint8 tokenDec = tCfg.decimals;

                (uint256 price, bool okPx) = _tryGetPrice(token, baseCollateralToken);
                if (!okPx) continue; // conservative: ignore this collateral if no price

                if (tokenDec == baseDec) {
                    valueBase = Math.mulDiv(bal, price, 1e8);
                } else if (tokenDec > baseDec) {
                    uint256 factor = 10 ** (tokenDec - baseDec);
                    valueBase = Math.mulDiv(bal, price, 1e8 * factor);
                } else {
                    uint256 factor = 10 ** (baseDec - tokenDec);
                    valueBase = Math.mulDiv(bal * factor, price, 1e8);
                }
            }

            // Haircut applied
            uint256 adjusted = Math.mulDiv(valueBase, uint256(rcfg.weightBps), 10_000);
            totalEquityBase += adjusted;
        }

        return totalEquityBase;
    }

    function _computeShortLiabilityBase(address trader) internal view returns (uint256 liabilityBase) {
        if (baseCollateralToken == address(0)) return 0;
        _requireBaseConfigured();

        uint256[] memory seriesIds = marginEngine.getTraderSeries(trader);

        for (uint256 i = 0; i < seriesIds.length; i++) {
            uint256 optionId = seriesIds[i];

            IMarginEngineState.Position memory pos = marginEngine.positions(trader, optionId);
            if (pos.quantity >= 0) continue;

            uint256 shortAbs = uint256(int256(-pos.quantity));

            OptionProductRegistry.OptionSeries memory s = optionRegistry.getSeries(optionId);

            // spot in settlement units (1e8)
            (uint256 spot, bool okSpot) = _tryGetPrice(s.underlying, s.settlementAsset);

            uint256 intrinsic1e8 = _computePerContractIntrinsic1e8(s, spot, okSpot);
            if (intrinsic1e8 == 0) continue;

            (uint256 intrinsicBase, bool okConv) =
                _convert1e8SettlementToBase(s.settlementAsset, intrinsic1e8);

            if (!okConv || intrinsicBase == 0) {
                // If we can't convert, be conservative:
                // treat intrinsic liability as 0 would be unsafe.
                // Here we approximate by using baseMaintenanceMarginPerContract as a floor per contract.
                uint256 floor =
                    Math.mulDiv(baseMaintenanceMarginPerContract, oracleDownMmMultiplierBps, 10_000);
                intrinsicBase = floor;
            }

            liabilityBase += shortAbs * intrinsicBase;
        }

        return liabilityBase;
    }

    /*//////////////////////////////////////////////////////////////
                          RISK COMPUTATION
    //////////////////////////////////////////////////////////////*/

    function computeAccountRisk(address trader)
        public
        view
        override
        returns (AccountRisk memory risk)
    {
        if (baseCollateralToken == address(0)) return risk;

        uint256 collatEquityBase = _computeCollateralEquityBase(trader);
        uint256 shortLiabilityBase = _computeShortLiabilityBase(trader);

        // equity can be negative
        if (shortLiabilityBase >= collatEquityBase) {
            risk.equity = -int256(shortLiabilityBase - collatEquityBase);
        } else {
            risk.equity = int256(collatEquityBase - shortLiabilityBase);
        }

        uint256 mm;
        uint256[] memory seriesIds = marginEngine.getTraderSeries(trader);

        for (uint256 i = 0; i < seriesIds.length; i++) {
            uint256 optionId = seriesIds[i];

            IMarginEngineState.Position memory pos = marginEngine.positions(trader, optionId);
            if (pos.quantity >= 0) continue;

            uint256 shortAbs = uint256(int256(-pos.quantity));

            OptionProductRegistry.OptionSeries memory s = optionRegistry.getSeries(optionId);
            OptionProductRegistry.UnderlyingConfig memory ucfg =
                optionRegistry.underlyingConfigs(s.underlying);

            (uint256 spot, bool okSpot) = _tryGetPrice(s.underlying, s.settlementAsset);

            uint256 mmPerContract = _computePerContractMM(s, spot, ucfg, okSpot);
            mm += shortAbs * mmPerContract;
        }

        risk.maintenanceMargin = mm;
        risk.initialMargin =
            (mm > 0 && imFactorBps > 0) ? Math.mulDiv(mm, imFactorBps, 10_000) : 0;
    }

    function computeFreeCollateral(address trader)
        public
        view
        override
        returns (int256 freeCollateral)
    {
        AccountRisk memory risk = computeAccountRisk(trader);
        if (risk.initialMargin == 0) return risk.equity;
        return risk.equity - int256(risk.initialMargin);
    }

    function getWithdrawableAmount(address trader, address token)
        public
        view
        override
        returns (uint256 withdrawable)
    {
        if (baseCollateralToken == address(0)) return 0;
        _requireBaseConfigured();

        uint256 principalBal = _principalBalanceOf(trader, token);
        if (principalBal == 0) return 0;

        CollateralConfig memory rcfg = collateralConfigs[token];

        // If token doesn't contribute to equity (disabled or weight=0), withdrawing it doesn't affect margin => allow full.
        if (!rcfg.isEnabled || rcfg.weightBps == 0) return principalBal;

        // strict: if enabled in risk module, must be configured in vault (decimals + supported)
        _requireTokenConfiguredIfEnabled(token);

        AccountRisk memory risk = computeAccountRisk(trader);
        int256 free = (risk.initialMargin == 0) ? risk.equity : (risk.equity - int256(risk.initialMargin));

        // oracle down protection (token contributor): if we can't price this token to base, block withdraw (unless no MM).
        if (token != baseCollateralToken) {
            (uint256 p, bool okP) = _tryGetPrice(token, baseCollateralToken);
            if (!okP) {
                if (risk.maintenanceMargin == 0) return principalBal;
                return 0;
            }
        }

        if (free <= 0) return 0;

        uint256 freeBase = uint256(free);

        if (token == baseCollateralToken) {
            return freeBase >= principalBal ? principalBal : freeBase;
        }

        (uint256 price, bool okPrice) = _tryGetPrice(token, baseCollateralToken);
        if (!okPrice) return (risk.maintenanceMargin == 0) ? principalBal : 0;

        uint8 baseDec = _baseDecimals();
        CollateralVault.CollateralTokenConfig memory tCfg = _vaultCfg(token);
        uint8 tokenDec = tCfg.decimals;

        uint256 numerator = freeBase * 10_000;
        uint256 denominator = uint256(rcfg.weightBps);

        uint256 maxToken;

        if (tokenDec == baseDec) {
            maxToken = Math.mulDiv(numerator, 1e8, price * denominator);
        } else if (tokenDec > baseDec) {
            uint256 factor = 10 ** (tokenDec - baseDec);
            maxToken = Math.mulDiv(numerator, 1e8 * factor, price * denominator);
        } else {
            uint256 factor = 10 ** (baseDec - tokenDec);
            maxToken = Math.mulDiv(numerator, 1e8, price * denominator * factor);
        }

        withdrawable = maxToken < principalBal ? maxToken : principalBal;
    }

    function computeMarginRatioBps(address trader) external view returns (uint256) {
        if (baseCollateralToken == address(0)) return type(uint256).max;

        AccountRisk memory risk = computeAccountRisk(trader);

        if (risk.maintenanceMargin == 0) return type(uint256).max;
        if (risk.equity <= 0) return 0;

        return (uint256(risk.equity) * 10_000) / risk.maintenanceMargin;
    }

    function previewWithdrawImpact(
        address trader,
        address token,
        uint256 amount
    ) external view override returns (IRiskModule.WithdrawPreview memory preview) {
        preview.requestedAmount = amount;

        if (baseCollateralToken == address(0)) {
            preview.maxWithdrawable = 0;
            preview.marginRatioBeforeBps = 0;
            preview.marginRatioAfterBps = 0;
            preview.wouldBreachMargin = (amount > 0);
            return preview;
        }

        AccountRisk memory riskBefore = computeAccountRisk(trader);

        uint256 mrBefore;
        if (riskBefore.maintenanceMargin == 0) mrBefore = type(uint256).max;
        else if (riskBefore.equity <= 0) mrBefore = 0;
        else mrBefore = uint256(riskBefore.equity) * 10_000 / riskBefore.maintenanceMargin;

        uint256 maxAllowed = getWithdrawableAmount(trader, token);
        preview.maxWithdrawable = maxAllowed;
        preview.marginRatioBeforeBps = mrBefore;

        uint256 principalBal = _principalBalanceOf(trader, token);
        uint256 capped = amount > principalBal ? principalBal : amount;
        uint256 effectiveAmount = capped > maxAllowed ? maxAllowed : capped;

        uint256 deltaEquityBase;

        if (effectiveAmount > 0) {
            CollateralConfig memory rcfg = collateralConfigs[token];

            if (rcfg.isEnabled && rcfg.weightBps > 0) {
                if (token == baseCollateralToken) {
                    deltaEquityBase = Math.mulDiv(effectiveAmount, uint256(rcfg.weightBps), 10_000);
                } else {
                    (uint256 price, bool ok) = _tryGetPrice(token, baseCollateralToken);
                    if (ok) {
                        uint8 baseDec = _baseDecimals();
                        CollateralVault.CollateralTokenConfig memory tCfg = _vaultCfg(token);
                        uint8 tokenDec = tCfg.decimals;

                        uint256 valueBase;
                        if (tokenDec == baseDec) {
                            valueBase = Math.mulDiv(effectiveAmount, price, 1e8);
                        } else if (tokenDec > baseDec) {
                            uint256 factor = 10 ** (tokenDec - baseDec);
                            valueBase = Math.mulDiv(effectiveAmount, price, 1e8 * factor);
                        } else {
                            uint256 factor = 10 ** (baseDec - tokenDec);
                            valueBase = Math.mulDiv(effectiveAmount * factor, price, 1e8);
                        }

                        deltaEquityBase = Math.mulDiv(valueBase, uint256(rcfg.weightBps), 10_000);
                    }
                }
            }
        }

        int256 equityAfter = riskBefore.equity - int256(deltaEquityBase);

        uint256 mrAfter;
        if (riskBefore.maintenanceMargin == 0) mrAfter = type(uint256).max;
        else if (equityAfter <= 0) mrAfter = 0;
        else mrAfter = uint256(equityAfter) * 10_000 / riskBefore.maintenanceMargin;

        preview.marginRatioAfterBps = mrAfter;

        bool breachFromOvershoot = (amount > maxAllowed);

        bool breachFromMM = false;
        if (riskBefore.maintenanceMargin > 0) {
            if (equityAfter <= 0) breachFromMM = true;
            else {
                uint256 ratioAfter = uint256(equityAfter) * 10_000 / riskBefore.maintenanceMargin;
                if (ratioAfter < 10_000) breachFromMM = true;
            }
        }

        preview.wouldBreachMargin = (breachFromOvershoot || breachFromMM);
    }

    function getUnderlyingSpot(address underlying, address settlementAsset)
        external
        view
        returns (uint256 price, uint256 updatedAt)
    {
        return oracle.getPrice(underlying, settlementAsset);
    }
}
