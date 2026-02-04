// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "../CollateralVault.sol";
import "../oracle/IOracle.sol";

/// @notice Minimal view sur RiskModule impl (weightBps + enable + baseToken)
interface IRiskModuleConfigView {
    function baseCollateralToken() external view returns (address);

    // mapping(address => CollateralConfig) public collateralConfigs;
    // struct CollateralConfig { uint64 weightBps; bool isEnabled; }
    function collateralConfigs(address token) external view returns (uint64 weightBps, bool isEnabled);
}

/// @title CollateralSeizer
/// @notice Construit un plan de saisie multi-collat valorisé en base (USDC) avec haircuts+spread.
/// @dev
///  - Le vault garde l’autorité de mouvement (onlyMarginEngine).
///  - Ce contrat est un "planner": computeSeizurePlan() -> (tokens, amounts, baseCovered).
///  - Valorisation conservative:
///      * conversion token->base via oracle (1e8)
///      * décimales via CollateralVault configs
///      * haircut = RiskModule.weightBps
///      * spread = seizeConfig.spreadBps (dégrade la valeur => saisie + grande)
contract CollateralSeizer {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BPS = 10_000;
    uint256 internal constant PRICE_SCALE = 1e8;

    // 10**77 fits in uint256 (10**78 does not)
    uint256 internal constant MAX_POW10_EXP = 77;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error ZeroAddress();

    error BaseTokenNotSet();
    error OracleNotSet();
    error VaultNotSet();
    error RiskModuleNotSet();

    error TokenNotSupportedInVault(address token);
    error TokenDecimalsMissing(address token);
    error DecimalsOverflow(address token);

    error SpreadOutOfRange();
    error DelayOutOfRange();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event OracleSet(address indexed oldOracle, address indexed newOracle);
    event VaultSet(address indexed oldVault, address indexed newVault);
    event RiskModuleSet(address indexed oldRisk, address indexed newRisk);

    event TokenSeizeConfigSet(address indexed token, uint16 spreadBps, bool isEnabled);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;

    CollateralVault public collateralVault;
    IOracle public oracle;
    IRiskModuleConfigView public riskModule;

    struct SeizeTokenConfig {
        uint16 spreadBps; // degrade value by (BPS - spread)
        bool isEnabled;
    }

    mapping(address => SeizeTokenConfig) public seizeConfigs;

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

    constructor(address _owner, address _vault, address _oracle, address _riskModule) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);

        if (_vault != address(0)) {
            collateralVault = CollateralVault(_vault);
            emit VaultSet(address(0), _vault);
        }
        if (_oracle != address(0)) {
            oracle = IOracle(_oracle);
            emit OracleSet(address(0), _oracle);
        }
        if (_riskModule != address(0)) {
            riskModule = IRiskModuleConfigView(_riskModule);
            emit RiskModuleSet(address(0), _riskModule);
        }
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
        pendingOwner = address(0);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function setVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert ZeroAddress();
        address old = address(collateralVault);
        collateralVault = CollateralVault(_vault);
        emit VaultSet(old, _vault);
    }

    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert ZeroAddress();
        address old = address(oracle);
        oracle = IOracle(_oracle);
        emit OracleSet(old, _oracle);
    }

    function setRiskModule(address _riskModule) external onlyOwner {
        if (_riskModule == address(0)) revert ZeroAddress();
        address old = address(riskModule);
        riskModule = IRiskModuleConfigView(_riskModule);
        emit RiskModuleSet(old, _riskModule);
    }

    /// @notice Configure le spread (dégradation de valeur) pour un token.
    /// @dev spreadBps typique: USDC 0..5, WETH/WBTC 75..100.
    function setTokenSeizeConfig(address token, uint16 spreadBps, bool isEnabled) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (spreadBps > uint16(BPS)) revert SpreadOutOfRange();

        seizeConfigs[token] = SeizeTokenConfig({spreadBps: spreadBps, isEnabled: isEnabled});
        emit TokenSeizeConfigSet(token, spreadBps, isEnabled);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW: CORE HELPERS
    //////////////////////////////////////////////////////////////*/

    function _pow10(uint256 exp) internal pure returns (uint256) {
        if (exp > MAX_POW10_EXP) revert DecimalsOverflow(address(0));
        return 10 ** exp;
    }

    function _vaultCfg(address token) internal view returns (CollateralVault.CollateralTokenConfig memory cfg) {
        cfg = collateralVault.collateralConfigs(token);
    }

    function _requireVaultToken(address token) internal view returns (uint8 dec) {
        CollateralVault.CollateralTokenConfig memory cfg = _vaultCfg(token);
        if (!cfg.isSupported) revert TokenNotSupportedInVault(token);
        dec = cfg.decimals;
        if (dec == 0) revert TokenDecimalsMissing(token);
        if (uint256(dec) > MAX_POW10_EXP) revert DecimalsOverflow(token);
    }

    function _baseToken() internal view returns (address base) {
        base = riskModule.baseCollateralToken();
        if (base == address(0)) revert BaseTokenNotSet();
    }

    function _baseDecimals() internal view returns (uint8 baseDec) {
        address base = _baseToken();
        baseDec = _requireVaultToken(base);
    }

    function _discountBps(address token) internal view returns (uint256 discBps) {
        (uint64 weightBps, bool enabledWeight) = riskModule.collateralConfigs(token);
        if (!enabledWeight || weightBps == 0) return 0;

        SeizeTokenConfig memory scfg = seizeConfigs[token];
        if (!scfg.isEnabled) return 0;

        // disc = weight * (1 - spread)
        uint256 w = uint256(weightBps);
        uint256 s = uint256(scfg.spreadBps);
        uint256 wAfterSpread = Math.mulDiv(w, (BPS - s), BPS, Math.Rounding.Floor);
        return wAfterSpread; // in BPS
    }

    function tokenDiscountBps(address token) external view returns (uint256) {
        return _discountBps(token);
    }

    function _safeBalanceWithYield(address user, address token) internal view returns (uint256 bal) {
        // balanceWithYield peut revert si l’adapter revert en previewRedeem.
        // fallback: balances (potentiellement non-sync, mais évite un revert dur).
        try collateralVault.balanceWithYield(user, token) returns (uint256 b) {
            return b;
        } catch {
            return collateralVault.balances(user, token);
        }
    }

    function _tryPrice(address baseAsset, address quoteAsset) internal view returns (uint256 px, bool ok) {
        try oracle.getPrice(baseAsset, quoteAsset) returns (uint256 p, uint256 /*updatedAt*/) {
            if (p == 0) return (0, false);
            return (p, true);
        } catch {
            return (0, false);
        }
    }

    /// @notice Convertit amountToken -> valueBase (unités base token), floor, via oracle+decimals.
    function _valueBaseFloor(address token, uint256 amountToken) internal view returns (uint256 valueBase, bool ok) {
        if (amountToken == 0) return (0, true);

        address base = _baseToken();
        uint8 baseDec = _baseDecimals();
        uint8 tokenDec = _requireVaultToken(token);

        if (token == base) return (amountToken, true);

        (uint256 price, bool okPx) = _tryPrice(token, base);
        if (!okPx) return (0, false);

        // conservative sequencing to avoid overflow; may under-estimate slightly (OK).
        if (tokenDec == baseDec) {
            valueBase = Math.mulDiv(amountToken, price, PRICE_SCALE, Math.Rounding.Floor);
            return (valueBase, true);
        }

        if (tokenDec > baseDec) {
            uint256 factor = _pow10(uint256(tokenDec - baseDec));
            uint256 tmp = Math.mulDiv(amountToken, price, PRICE_SCALE, Math.Rounding.Floor);
            valueBase = tmp / factor; // floor
            return (valueBase, true);
        } else {
            uint256 factor = _pow10(uint256(baseDec - tokenDec));
            // amountToken * factor can overflow in theory; assume realistic balances, still harden:
            uint256 scaled = amountToken * factor;
            if (factor != 0 && scaled / factor != amountToken) revert DecimalsOverflow(token);
            valueBase = Math.mulDiv(scaled, price, PRICE_SCALE, Math.Rounding.Floor);
            return (valueBase, true);
        }
    }

    /// @notice Applique discount (weight + spread) à une valueBase, floor.
    function _effectiveBaseFloor(address token, uint256 valueBase) internal view returns (uint256 eff) {
        uint256 disc = _discountBps(token);
        if (disc == 0) return 0;
        eff = Math.mulDiv(valueBase, disc, BPS, Math.Rounding.Floor);
    }

    /// @notice Valeur effective (discounted) en base d’un amountToken, floor.
    function _effectiveBaseFromTokenFloor(address token, uint256 amountToken)
        internal
        view
        returns (uint256 effBase, bool ok)
    {
        (uint256 vb, bool okV) = _valueBaseFloor(token, amountToken);
        if (!okV) return (0, false);
        effBase = _effectiveBaseFloor(token, vb);
        return (effBase, true);
    }

    /// @notice Pour couvrir remainingEffBase, calcule le "valueBase" brut nécessaire (ceil).
    function _requiredValueBaseCeil(uint256 remainingEffBase, uint256 discountBps)
        internal
        pure
        returns (uint256 requiredValueBase)
    {
        // requiredValueBase = ceil(remaining * BPS / discount)
        requiredValueBase = Math.mulDiv(remainingEffBase, BPS, discountBps, Math.Rounding.Ceil);
    }

    /// @notice Convertit un valueBase (unités base) -> amountToken nécessaire, ceil.
    function _amountTokenForValueBaseCeil(address token, uint256 valueBase)
        internal
        view
        returns (uint256 amountToken, bool ok)
    {
        if (valueBase == 0) return (0, true);

        address base = _baseToken();
        uint8 baseDec = _baseDecimals();
        uint8 tokenDec = _requireVaultToken(token);

        if (token == base) return (valueBase, true);

        (uint256 price, bool okPx) = _tryPrice(token, base);
        if (!okPx) return (0, false);

        // temp = ceil(valueBase * 1e8 / price) in "base-decimals token units"
        uint256 temp = Math.mulDiv(valueBase, PRICE_SCALE, price, Math.Rounding.Ceil);

        if (tokenDec == baseDec) {
            return (temp, true);
        }

        if (tokenDec > baseDec) {
            uint256 factor = _pow10(uint256(tokenDec - baseDec));
            uint256 scaled = temp * factor;
            if (factor != 0 && scaled / factor != temp) revert DecimalsOverflow(token);
            return (scaled, true);
        } else {
            uint256 factor = _pow10(uint256(baseDec - tokenDec));
            // amountToken = ceil(temp / factor)
            amountToken = Math.mulDiv(temp, 1, factor, Math.Rounding.Ceil);
            return (amountToken, true);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC VIEW: PLAN BUILDER
    //////////////////////////////////////////////////////////////*/

    /// @notice Construit un plan de saisie pour couvrir `targetBaseAmount` (unités base token).
    /// @return tokensOut tokens saisis
    /// @return amountsOut montants saisis (unités natives token)
    /// @return baseCovered valeur effective couverte (unités base token), conservative floor
    function computeSeizurePlan(address trader, uint256 targetBaseAmount)
        external
        view
        returns (address[] memory tokensOut, uint256[] memory amountsOut, uint256 baseCovered)
    {
        if (trader == address(0)) revert ZeroAddress();
        if (targetBaseAmount == 0) {
            return (new address, new uint256, 0);
        }

        if (address(collateralVault) == address(0)) revert VaultNotSet();
        if (address(oracle) == address(0)) revert OracleNotSet();
        if (address(riskModule) == address(0)) revert RiskModuleNotSet();

        address base = _baseToken();

        address[] memory all = collateralVault.getCollateralTokens();
        uint256 maxOut = all.length + 1;

        tokensOut = new address[](maxOut);
        amountsOut = new uint256[](maxOut);

        uint256 remaining = targetBaseAmount;
        uint256 n;

        // 1) base token first
        {
            uint256 disc = _discountBps(base);
            if (disc != 0) {
                uint256 avail = _safeBalanceWithYield(trader, base);
                if (avail != 0) {
                    uint256 needValueBase = _requiredValueBaseCeil(remaining, disc);
                    // base => amount == valueBase
                    uint256 want = needValueBase;
                    uint256 seizeAmt = want <= avail ? want : avail;

                    (uint256 covered, bool okCov) = _effectiveBaseFromTokenFloor(base, seizeAmt);
                    if (okCov && covered != 0) {
                        tokensOut[n] = base;
                        amountsOut[n] = seizeAmt;
                        n++;
                        baseCovered += covered;
                        if (covered >= remaining) {
                            remaining = 0;
                        } else {
                            remaining -= covered;
                        }
                    }
                }
            }
        }

        // 2) then other tokens in vault list order
        if (remaining != 0) {
            for (uint256 i = 0; i < all.length; i++) {
                address token = all[i];
                if (token == address(0) || token == base) continue;

                uint256 disc = _discountBps(token);
                if (disc == 0) continue;

                uint256 avail = _safeBalanceWithYield(trader, token);
                if (avail == 0) continue;

                uint256 needValueBase = _requiredValueBaseCeil(remaining, disc);

                (uint256 wantAmt, bool okAmt) = _amountTokenForValueBaseCeil(token, needValueBase);
                if (!okAmt || wantAmt == 0) continue;

                uint256 seizeAmt = wantAmt <= avail ? wantAmt : avail;

                (uint256 covered, bool okCov) = _effectiveBaseFromTokenFloor(token, seizeAmt);
                if (!okCov || covered == 0) continue;

                tokensOut[n] = token;
                amountsOut[n] = seizeAmt;
                n++;

                baseCovered += covered;

                if (covered >= remaining) {
                    remaining = 0;
                    break;
                } else {
                    remaining -= covered;
                }
            }
        }

        // trim arrays
        assembly {
            mstore(tokensOut, n)
            mstore(amountsOut, n)
        }
    }

    /*//////////////////////////////////////////////////////////////
                        DEBUG VIEWS (optional)
    //////////////////////////////////////////////////////////////*/

    function previewEffectiveBaseValue(address token, uint256 amountToken)
        external
        view
        returns (uint256 valueBaseFloor, uint256 effectiveBaseFloor, bool ok)
    {
        (uint256 vb, bool okV) = _valueBaseFloor(token, amountToken);
        if (!okV) return (0, 0, false);
        uint256 eff = _effectiveBaseFloor(token, vb);
        return (vb, eff, true);
    }
}
