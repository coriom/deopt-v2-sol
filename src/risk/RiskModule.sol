// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "../CollateralVault.sol";
import "../OptionProductRegistry.sol";
import "../oracle/IOracle.sol";
import "./IRiskModule.sol";
import "./IMarginEngineState.sol";

/// @notice RiskModule DeOpt v2 (prod-hardened) — contractSize hard-locked to 1e8
/// @dev Key points:
///  - Strike/spot are in 1e8 (PRICE_SCALE).
///  - Per-series contract size MUST be 1e8 (OptionProductRegistry enforces; RiskModule re-checks defensively).
///  - Base collateral token is expected to be USDC-like (6 decimals) for this deployment target.
///  - Multi-collateral enabled: equity sums collateralValueBase * weightBps (haircut).
///  - Equity includes conservative short intrinsic liability; long options are ignored (conservative).
///  - Strict decimals + overflow hardening.
///  - Oracle-down fallback: apply configurable multiplier (bps) on base MM floor.
///  - Optional local staleness guard (maxOracleDelay), bounded.
contract RiskModule is IRiskModule {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BPS = 10_000;

    // 10**77 fits in uint256 (10**78 does not).
    uint256 internal constant MAX_POW10_EXP = 77;

    // deployment target (current system)
    uint8 internal constant EXPECTED_BASE_DECIMALS = 6;

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

    // decimals hardening
    error DecimalsOverflow(address token);     // decimals too large for 10**decimals
    error DecimalsDiffOverflow(address token); // |decimals(token)-decimals(base)| too large

    // USDC-only hardening (base token only)
    error BaseTokenDecimalsNotUSDC(address token, uint8 decimals);

    // contract size lock
    error InvalidContractSize(); // series.contractSize1e8 must be PRICE_SCALE

    // quantity hardening
    error QuantityInt128Min(); // quantity == type(int128).min (abs overflow)
    error QuantityAbsOverflow(); // should never happen, defensive

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;

    CollateralVault public collateralVault;
    OptionProductRegistry public optionRegistry;
    IMarginEngineState public marginEngine;
    IOracle public oracle;

    /// @notice Base collateral token (ex: USDC). Public getter satisfies IRiskModule.baseCollateralToken().
    address public baseCollateralToken;

    /// @dev Floor per contract (in base token units) for 1 contract (contractSize fixed to 1e8).
    uint256 public baseMaintenanceMarginPerContract;

    /// @dev initial margin factor in bps, must be >= 10000.
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

    /// @notice Token haircuts (weight) used for equity valuation and withdraw limits.
    /// @dev Public getter returns (uint64 weightBps, bool isEnabled) => compatible with CollateralSeizer view.
    mapping(address => CollateralConfig) public collateralConfigs;

    /// @dev Token universe used by RiskModule for equity aggregation.
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

    constructor(address _owner, address _vault, address _registry, address _marginEngine, address _oracle) {
        if (_owner == address(0) || _vault == address(0) || _registry == address(0) || _marginEngine == address(0) || _oracle == address(0)) {
            revert ZeroAddress();
        }

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
        // 0 = disabled
        if (_maxOracleDelay > 3600) revert InvalidParams();
        maxOracleDelay = _maxOracleDelay;
        emit MaxOracleDelaySet(_maxOracleDelay);
    }

    function setOracleDownMmMultiplier(uint256 _multiplierBps) external onlyOwner {
        // must be >= 1x and <= 10x
        if (_multiplierBps < BPS || _multiplierBps > 100_000) revert InvalidParams();
        oracleDownMmMultiplierBps = _multiplierBps;
        emit OracleDownMmMultiplierSet(_multiplierBps);
    }

    function setRiskParams(address _baseToken, uint256 _baseMMPerContract, uint256 _imFactorBps) external onlyOwner {
        if (_baseToken == address(0)) revert ZeroAddress();
        if (_imFactorBps < BPS) revert InvalidParams();

        // strict: base token must be configured in vault and must be 6 decimals (deployment target)
        CollateralVault.CollateralTokenConfig memory baseCfg = _vaultCfg(_baseToken);
        if (!baseCfg.isSupported) revert TokenNotSupportedInVault(_baseToken);
        if (baseCfg.decimals == 0) revert TokenDecimalsNotConfigured(_baseToken);
        if (uint256(baseCfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(_baseToken);
        if (baseCfg.decimals != EXPECTED_BASE_DECIMALS) revert BaseTokenDecimalsNotUSDC(_baseToken, baseCfg.decimals);

        baseCollateralToken = _baseToken;
        baseMaintenanceMarginPerContract = _baseMMPerContract;
        imFactorBps = _imFactorBps;

        emit RiskParamsSet(_baseToken, _baseMMPerContract, _imFactorBps);

        // auto-list base token with 100% weight, enabled
        _listTokenIfNeeded(_baseToken);
        collateralConfigs[_baseToken] = CollateralConfig({weightBps: uint64(BPS), isEnabled: true});
        emit CollateralConfigSet(_baseToken, uint64(BPS), true);
    }

    /// @notice Configure collateral haircut for a token.
    /// @dev Multi-collat: any supported vault token can be enabled here.
    function setCollateralConfig(address token, uint64 weightBps, bool isEnabled) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (weightBps > BPS) revert InvalidParams();

        // If enabling, require base configured + token configured in vault
        if (isEnabled) {
            _requireBaseConfigured();

            CollateralVault.CollateralTokenConfig memory vcfg = _vaultCfg(token);
            if (!vcfg.isSupported) revert TokenNotSupportedInVault(token);
            if (vcfg.decimals == 0) revert TokenDecimalsNotConfigured(token);
            if (uint256(vcfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(token);

            // ensure decimals diff won't overflow in conversions
            uint8 baseDec = _baseDecimals();
            uint8 tokenDec = vcfg.decimals;
            uint256 diff = tokenDec >= baseDec ? uint256(tokenDec - baseDec) : uint256(baseDec - tokenDec);
            if (diff > MAX_POW10_EXP) revert DecimalsDiffOverflow(token);

            // disallow "enabled but 0 weight" (it’s ambiguous and breaks seizure/equity assumptions)
            if (weightBps == 0) revert InvalidParams();
        }

        _listTokenIfNeeded(token);
        collateralConfigs[token] = CollateralConfig({weightBps: weightBps, isEnabled: isEnabled});
        emit CollateralConfigSet(token, weightBps, isEnabled);
    }

    /// @notice Optional helper: mirror vault collateral token list into risk token universe.
    /// @dev Does not enable tokens or set weights; only ensures they are "listed".
    function syncCollateralTokensFromVault() external onlyOwner returns (uint256 added) {
        address[] memory all = collateralVault.getCollateralTokens();
        uint256 len = all.length;
        for (uint256 i = 0; i < len; i++) {
            address t = all[i];
            if (t == address(0)) continue;
            if (!isCollateralTokenListed[t]) {
                collateralTokens.push(t);
                isCollateralTokenListed[t] = true;
                added++;
            }
        }
        emit CollateralTokensSyncedFromVault(added);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return collateralTokens;
    }

    /*//////////////////////////////////////////////////////////////
                        IRiskModule OPTIONAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function baseDecimals() external view override returns (uint8) {
        address base = baseCollateralToken;
        if (base == address(0)) return 0;
        CollateralVault.CollateralTokenConfig memory cfg = _vaultCfg(base);
        return cfg.decimals;
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL: STRICT VAULT / REGISTRY HELPERS
    //////////////////////////////////////////////////////////////*/

    function _listTokenIfNeeded(address token) internal {
        if (!isCollateralTokenListed[token]) {
            collateralTokens.push(token);
            isCollateralTokenListed[token] = true;
        }
    }

    function _vaultCfg(address token) internal view returns (CollateralVault.CollateralTokenConfig memory cfg) {
        // CollateralVault exposes explicit struct getter; prefer that.
        cfg = collateralVault.getCollateralConfig(token);
    }

    function _pow10(uint256 exp) internal pure returns (uint256) {
        if (exp > MAX_POW10_EXP) revert InvalidParams();
        return 10 ** exp;
    }

    function _requireBaseConfigured() internal view {
        address base = baseCollateralToken;
        if (base == address(0)) revert BaseTokenNotConfigured();

        CollateralVault.CollateralTokenConfig memory baseCfg = _vaultCfg(base);
        if (!baseCfg.isSupported) revert TokenNotSupportedInVault(base);
        if (baseCfg.decimals == 0) revert TokenDecimalsNotConfigured(base);
        if (uint256(baseCfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(base);
        if (baseCfg.decimals != EXPECTED_BASE_DECIMALS) revert BaseTokenDecimalsNotUSDC(base, baseCfg.decimals);
    }

    function _baseDecimals() internal view returns (uint8) {
        CollateralVault.CollateralTokenConfig memory baseCfg = _vaultCfg(baseCollateralToken);
        return baseCfg.decimals;
    }

    function _requireTokenConfiguredIfEnabled(address token) internal view {
        CollateralConfig memory rcfg = collateralConfigs[token];
        if (!rcfg.isEnabled) return;

        CollateralVault.CollateralTokenConfig memory vcfg = _vaultCfg(token);
        if (!vcfg.isSupported) revert TokenNotSupportedInVault(token);
        if (vcfg.decimals == 0) revert TokenDecimalsNotConfigured(token);
        if (uint256(vcfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(token);

        uint8 baseDec = _baseDecimals();
        uint8 tokenDec = vcfg.decimals;
        uint256 diff = tokenDec >= baseDec ? uint256(tokenDec - baseDec) : uint256(baseDec - tokenDec);
        if (diff > MAX_POW10_EXP) revert DecimalsDiffOverflow(token);
    }

    function _getUnderlyingConfig(address underlying) internal view returns (OptionProductRegistry.UnderlyingConfig memory cfg) {
        (address o, uint64 spotDown, uint64 spotUp, uint64 volDown, uint64 volUp, bool enabled) = optionRegistry.underlyingConfigs(underlying);

        cfg = OptionProductRegistry.UnderlyingConfig({
            oracle: o,
            spotShockDownBps: spotDown,
            spotShockUpBps: spotUp,
            volShockDownBps: volDown,
            volShockUpBps: volUp,
            isEnabled: enabled
        });
    }

    function _requireStandardContractSize(OptionProductRegistry.OptionSeries memory s) internal pure {
        if (s.contractSize1e8 != uint128(PRICE_SCALE)) revert InvalidContractSize();
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL: BALANCE HELPERS
    //////////////////////////////////////////////////////////////*/

    function _principalBalanceOf(address user, address token) internal view returns (uint256) {
        return collateralVault.balances(user, token);
    }

    function _effectiveBalanceOf(address user, address token) internal view returns (uint256) {
        // best-effort: if yield view reverts, fall back to last synced claimable balance.
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
        if (updatedAt > block.timestamp) return false;
        return (block.timestamp - updatedAt) <= maxOracleDelay;
    }

    /// @dev OracleRouter can revert: wrap to (0,false).
    function _tryGetPrice(address base, address quote) internal view returns (uint256 price, bool ok) {
        try oracle.getPrice(base, quote) returns (uint256 p, uint256 updatedAt) {
            if (p == 0) return (0, false);
            if (!_isOracleDataFresh(updatedAt)) return (0, false);
            return (p, true);
        } catch {
            return (0, false);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL: QUANTITY HELPERS
    //////////////////////////////////////////////////////////////*/

    function _absQuantityU(int128 q) internal pure returns (uint256) {
        if (q >= 0) return uint256(int256(q));
        if (q == type(int128).min) revert QuantityInt128Min();
        int256 a = -int256(q);
        if (a < 0) revert QuantityAbsOverflow();
        return uint256(a);
    }

    /*//////////////////////////////////////////////////////////////
              INTERNAL: 1e8 (settlement AMOUNT) -> base token units
    //////////////////////////////////////////////////////////////*/

    function _convert1e8SettlementToBase(address settlementAsset, uint256 amount1e8)
        internal
        view
        returns (uint256 valueBase, bool ok)
    {
        if (amount1e8 == 0) return (0, true);

        _requireBaseConfigured();

        uint8 baseDec = _baseDecimals();
        uint256 baseScale = _pow10(uint256(baseDec));

        if (settlementAsset == baseCollateralToken) {
            // baseSmall = amount(1e8) * 10^baseDec / 1e8
            return (Math.mulDiv(amount1e8, baseScale, PRICE_SCALE, Math.Rounding.Floor), true);
        }

        (uint256 px, bool okPx) = _tryGetPrice(settlementAsset, baseCollateralToken);
        if (!okPx) return (0, false);

        // baseSmall = amount1e8 * px * 10^baseDec / 1e16
        uint256 v1e8 = Math.mulDiv(amount1e8, px, PRICE_SCALE, Math.Rounding.Floor); // base in 1e8 scale
        valueBase = Math.mulDiv(v1e8, baseScale, PRICE_SCALE, Math.Rounding.Floor);
        return (valueBase, true);
    }

    /*//////////////////////////////////////////////////////////////
              INTERNAL: MM floor per contract (base units)
    //////////////////////////////////////////////////////////////*/

    function _baseMmFloorPerContract(OptionProductRegistry.OptionSeries memory s) internal view returns (uint256 floorBase) {
        if (baseMaintenanceMarginPerContract == 0) return 0;
        _requireStandardContractSize(s);
        return baseMaintenanceMarginPerContract;
    }

    /*//////////////////////////////////////////////////////////////
              INTERNAL: conservative short liability (intrinsic)
    //////////////////////////////////////////////////////////////*/

    /// @dev With contractSize fixed to 1e8, per-contract intrinsic settlement amount in 1e8 == intrinsicPrice1e8.
    function _computePerContractIntrinsicAmount1e8(OptionProductRegistry.OptionSeries memory s, uint256 spot1e8)
        internal
        pure
        returns (uint256 intrinsicAmount1e8)
    {
        _requireStandardContractSize(s);

        uint256 intrinsicPrice1e8;
        if (s.isCall) {
            intrinsicPrice1e8 = spot1e8 > uint256(s.strike) ? (spot1e8 - uint256(s.strike)) : 0;
        } else {
            intrinsicPrice1e8 = uint256(s.strike) > spot1e8 ? (uint256(s.strike) - spot1e8) : 0;
        }

        intrinsicAmount1e8 = intrinsicPrice1e8;
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
        if (baseCollateralToken == address(0)) return 0;

        uint256 baseFloor = _baseMmFloorPerContract(s);
        if (baseFloor == 0) return 0;

        // If underlying is not enabled in registry, fall back to base floor.
        if (!cfg.isEnabled) return baseFloor;

        // If spot is missing, use strike as conservative anchor.
        uint256 spotLocal = hasSpot ? spot1e8 : uint256(s.strike);

        uint256 mmPrice1e8;

        if (s.isCall) {
            uint256 shockedSpot = Math.mulDiv(spotLocal, (BPS + uint256(cfg.spotShockUpBps)), BPS, Math.Rounding.Floor);

            uint256 intrinsicShock = shockedSpot > uint256(s.strike) ? (shockedSpot - uint256(s.strike)) : 0;

            // volShockUpBps = % of spotLocal
            uint256 floorPrice = Math.mulDiv(spotLocal, uint256(cfg.volShockUpBps), BPS, Math.Rounding.Floor);

            mmPrice1e8 = intrinsicShock > floorPrice ? intrinsicShock : floorPrice;
        } else {
            uint256 shockDownBps = uint256(cfg.spotShockDownBps);
            if (shockDownBps > BPS) shockDownBps = BPS;

            uint256 shockedSpot = Math.mulDiv(spotLocal, (BPS - shockDownBps), BPS, Math.Rounding.Floor);

            uint256 intrinsicShock = uint256(s.strike) > shockedSpot ? (uint256(s.strike) - shockedSpot) : 0;

            // volShockUpBps = % of strike (put anchor)
            uint256 floorPrice = Math.mulDiv(uint256(s.strike), uint256(cfg.volShockUpBps), BPS, Math.Rounding.Floor);

            mmPrice1e8 = intrinsicShock > floorPrice ? intrinsicShock : floorPrice;
        }

        // With contractSize fixed, per-contract settlement amount in 1e8 == mmPrice1e8.
        (uint256 converted, bool okConv) = _convert1e8SettlementToBase(s.settlementAsset, mmPrice1e8);

        if (!okConv || converted == 0) {
            // Oracle-down fallback: bump base floor by multiplier
            return Math.mulDiv(baseFloor, oracleDownMmMultiplierBps, BPS, Math.Rounding.Ceil);
        }

        if (converted < baseFloor) converted = baseFloor;
        return converted;
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL: TOKEN -> BASE VALUE
    //////////////////////////////////////////////////////////////*/

    /// @dev Converts `tokenAmount` (smallest units) into base collateral (smallest units),
    /// using `price1e8 = price(token in base)` per 1 whole token.
    function _tokenAmountToBaseValue(address token, uint256 tokenAmount, uint256 price1e8) internal view returns (uint256 baseValue) {
        // baseValue = tokenAmount * price * 10^baseDec / (10^tokenDec * 1e8)
        uint256 tmp = Math.mulDiv(tokenAmount, price1e8, PRICE_SCALE, Math.Rounding.Floor);

        uint8 baseDec = _baseDecimals();
        uint8 tokenDec = _vaultCfg(token).decimals;

        if (baseDec == tokenDec) return tmp;

        if (baseDec > tokenDec) {
            uint256 factor = _pow10(uint256(baseDec - tokenDec));
            return Math.mulDiv(tmp, factor, 1, Math.Rounding.Floor);
        } else {
            uint256 factor = _pow10(uint256(tokenDec - baseDec));
            return tmp / factor;
        }
    }

    /// @dev Inverse of _tokenAmountToBaseValue: converts `baseValue` (base smallest units)
    /// into `tokenAmount` (token smallest units), using `price1e8 = price(token in base)`.
    function _baseValueToTokenAmount(address token, uint256 baseValue, uint256 price1e8) internal view returns (uint256 tokenAmount) {
        // tokenAmount = baseValue * 1e8 / price * 10^(tokenDec - baseDec)
        uint256 tmp = Math.mulDiv(baseValue, PRICE_SCALE, price1e8, Math.Rounding.Floor);

        uint8 baseDec = _baseDecimals();
        uint8 tokenDec = _vaultCfg(token).decimals;

        if (baseDec == tokenDec) return tmp;

        if (tokenDec > baseDec) {
            uint256 factor = _pow10(uint256(tokenDec - baseDec));
            return Math.mulDiv(tmp, factor, 1, Math.Rounding.Floor);
        } else {
            uint256 factor = _pow10(uint256(baseDec - tokenDec));
            return tmp / factor;
        }
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL: MULTI-COLLATERAL EQUITY
    //////////////////////////////////////////////////////////////*/

    function _computeCollateralEquityBase(address trader) internal view returns (uint256 totalEquityBase) {
        _requireBaseConfigured();

        CollateralConfig memory baseRiskCfg = collateralConfigs[baseCollateralToken];
        if (!baseRiskCfg.isEnabled || baseRiskCfg.weightBps == 0) revert TokenNotConfigured(baseCollateralToken);

        // strict validation upfront for enabled tokens
        uint256 n = collateralTokens.length;
        for (uint256 i = 0; i < n; i++) {
            _requireTokenConfiguredIfEnabled(collateralTokens[i]);
        }

        for (uint256 i = 0; i < n; i++) {
            address token = collateralTokens[i];
            CollateralConfig memory rcfg = collateralConfigs[token];
            if (!rcfg.isEnabled || rcfg.weightBps == 0) continue;

            uint256 bal = _effectiveBalanceOf(trader, token);
            if (bal == 0) continue;

            uint256 valueBase;

            if (token == baseCollateralToken) {
                valueBase = bal;
            } else {
                (uint256 price, bool okPx) = _tryGetPrice(token, baseCollateralToken);
                if (!okPx) continue; // conservative: ignore this collateral if no price

                valueBase = _tokenAmountToBaseValue(token, bal, price);
            }

            uint256 adjusted = Math.mulDiv(valueBase, uint256(rcfg.weightBps), BPS, Math.Rounding.Floor);
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

            uint256 shortAbs = _absQuantityU(pos.quantity);

            OptionProductRegistry.OptionSeries memory s = optionRegistry.getSeries(optionId);
            _requireStandardContractSize(s);

            (uint256 spot, bool okSpot) = _tryGetPrice(s.underlying, s.settlementAsset);

            // If we cannot mark spot, be conservative: liability per contract = base floor * multiplier.
            if (!okSpot) {
                uint256 baseFloor = _baseMmFloorPerContract(s);
                uint256 liabPerContract = Math.mulDiv(baseFloor, oracleDownMmMultiplierBps, BPS, Math.Rounding.Ceil);
                liabilityBase += Math.mulDiv(shortAbs, liabPerContract, 1, Math.Rounding.Floor);
                continue;
            }

            uint256 intrinsicAmount1e8 = _computePerContractIntrinsicAmount1e8(s, spot);
            if (intrinsicAmount1e8 == 0) continue;

            (uint256 intrinsicBase, bool okConv) = _convert1e8SettlementToBase(s.settlementAsset, intrinsicAmount1e8);

            if (!okConv || intrinsicBase == 0) {
                uint256 baseFloor2 = _baseMmFloorPerContract(s);
                intrinsicBase = Math.mulDiv(baseFloor2, oracleDownMmMultiplierBps, BPS, Math.Rounding.Ceil);
            }

            liabilityBase += Math.mulDiv(shortAbs, intrinsicBase, 1, Math.Rounding.Floor);
        }

        return liabilityBase;
    }

    /*//////////////////////////////////////////////////////////////
                          RISK COMPUTATION
    //////////////////////////////////////////////////////////////*/

    function computeAccountRisk(address trader) public view override returns (AccountRisk memory risk) {
        if (baseCollateralToken == address(0)) return risk;

        uint256 collatEquityBase = _computeCollateralEquityBase(trader);
        uint256 shortLiabilityBase = _computeShortLiabilityBase(trader);

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
            if (pos.quantity >= 0) continue; // only shorts require margin

            uint256 shortAbs = _absQuantityU(pos.quantity);

            OptionProductRegistry.OptionSeries memory s = optionRegistry.getSeries(optionId);
            _requireStandardContractSize(s);

            OptionProductRegistry.UnderlyingConfig memory ucfg = _getUnderlyingConfig(s.underlying);

            (uint256 spot, bool okSpot) = _tryGetPrice(s.underlying, s.settlementAsset);

            uint256 mmPerContract = _computePerContractMM(s, spot, ucfg, okSpot);

            mm += Math.mulDiv(shortAbs, mmPerContract, 1, Math.Rounding.Floor);
        }

        risk.maintenanceMargin = mm;
        risk.initialMargin = (mm > 0 && imFactorBps > 0) ? Math.mulDiv(mm, imFactorBps, BPS, Math.Rounding.Ceil) : 0;
    }

    function computeFreeCollateral(address trader) public view override returns (int256 freeCollateral) {
        AccountRisk memory risk = computeAccountRisk(trader);
        if (risk.initialMargin == 0) return risk.equity;
        return risk.equity - int256(risk.initialMargin);
    }

    function getWithdrawableAmount(address trader, address token) public view override returns (uint256 withdrawable) {
        if (baseCollateralToken == address(0)) return 0;
        _requireBaseConfigured();

        uint256 avail = _effectiveBalanceOf(trader, token);
        if (avail == 0) return 0;

        CollateralConfig memory rcfg = collateralConfigs[token];

        // If token is not enabled as collateral (or has 0 weight), allow full withdraw (it doesn't support margin anyway).
        if (!rcfg.isEnabled || rcfg.weightBps == 0) return avail;

        _requireTokenConfiguredIfEnabled(token);

        AccountRisk memory risk = computeAccountRisk(trader);

        int256 free = (risk.initialMargin == 0) ? risk.equity : (risk.equity - int256(risk.initialMargin));
        if (free <= 0) return 0;

        // If no positions, allow full withdrawal.
        if (risk.maintenanceMargin == 0) return avail;

        uint256 freeBase = uint256(free);

        // deltaEquityBase = valueBase * weight / 1e4  <= freeBase
        // => valueBase <= freeBase * 1e4 / weight
        uint256 valueBaseMax = Math.mulDiv(freeBase, BPS, uint256(rcfg.weightBps), Math.Rounding.Floor);

        uint256 maxToken;
        if (token == baseCollateralToken) {
            maxToken = valueBaseMax;
        } else {
            (uint256 price, bool okPrice) = _tryGetPrice(token, baseCollateralToken);
            if (!okPrice) return 0;
            maxToken = _baseValueToTokenAmount(token, valueBaseMax, price);
        }

        withdrawable = maxToken < avail ? maxToken : avail;
    }

    function computeMarginRatioBps(address trader) external view override returns (uint256) {
        if (baseCollateralToken == address(0)) return type(uint256).max;

        AccountRisk memory risk = computeAccountRisk(trader);

        if (risk.maintenanceMargin == 0) return type(uint256).max;
        if (risk.equity <= 0) return 0;

        return (uint256(risk.equity) * BPS) / risk.maintenanceMargin;
    }

    function previewWithdrawImpact(address trader, address token, uint256 amount)
        external
        view
        override
        returns (IRiskModule.WithdrawPreview memory preview)
    {
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
        else mrBefore = (uint256(riskBefore.equity) * BPS) / riskBefore.maintenanceMargin;

        uint256 maxAllowed = getWithdrawableAmount(trader, token);
        preview.maxWithdrawable = maxAllowed;
        preview.marginRatioBeforeBps = mrBefore;

        // available (post-sync theoretical) — best effort
        uint256 avail = _effectiveBalanceOf(trader, token);
        uint256 cappedReq = amount > avail ? avail : amount;

        // simulate what ME will allow (it reverts if amount > maxAllowed)
        uint256 effectiveAmount = cappedReq > maxAllowed ? maxAllowed : cappedReq;

        uint256 deltaEquityBase;

        if (effectiveAmount > 0) {
            CollateralConfig memory rcfg = collateralConfigs[token];

            if (rcfg.isEnabled && rcfg.weightBps > 0) {
                _requireTokenConfiguredIfEnabled(token);

                if (token == baseCollateralToken) {
                    deltaEquityBase = Math.mulDiv(effectiveAmount, uint256(rcfg.weightBps), BPS, Math.Rounding.Floor);
                } else {
                    (uint256 price, bool ok) = _tryGetPrice(token, baseCollateralToken);
                    if (ok) {
                        uint256 valueBase = _tokenAmountToBaseValue(token, effectiveAmount, price);
                        deltaEquityBase = Math.mulDiv(valueBase, uint256(rcfg.weightBps), BPS, Math.Rounding.Floor);
                    } else {
                        // if we can't price enabled collateral, treat as hard-breach
                        deltaEquityBase = uint256(type(int256).max);
                    }
                }
            } else {
                deltaEquityBase = 0; // withdrawing non-collateral token doesn't affect equity
            }
        }

        int256 equityAfter = riskBefore.equity - int256(deltaEquityBase);

        uint256 mrAfter;
        if (riskBefore.maintenanceMargin == 0) mrAfter = type(uint256).max;
        else if (equityAfter <= 0) mrAfter = 0;
        else mrAfter = (uint256(equityAfter) * BPS) / riskBefore.maintenanceMargin;

        preview.marginRatioAfterBps = mrAfter;

        // primary breach signal: request > max allowed
        bool breach = (amount > maxAllowed);

        // secondary conservative signal: equityAfter below initial margin (should not happen if amount<=maxAllowed)
        if (!breach && riskBefore.initialMargin != 0) {
            if (equityAfter < int256(riskBefore.initialMargin)) breach = true;
        }

        preview.wouldBreachMargin = breach;
    }

    /*//////////////////////////////////////////////////////////////
                          DEBUG / ORACLE VIEW
    //////////////////////////////////////////////////////////////*/

    function getUnderlyingSpot(address underlying, address settlementAsset) external view returns (uint256 price, uint256 updatedAt) {
        return oracle.getPrice(underlying, settlementAsset);
    }
}
