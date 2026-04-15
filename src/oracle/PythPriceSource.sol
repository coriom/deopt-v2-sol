// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "./IPriceSource.sol";

/// @dev Interface minimale de Pyth sur EVM.
/// @notice On utilise getPriceUnsafe et on laisse le Router gérer la staleness.
interface IPyth {
    struct Price {
        int64 price; // mantissa
        uint64 conf; // ignoré
        int32 expo; // exponent (ex: -8 => 1e-8)
        uint256 publishTime;
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory);
}

/// @title PythPriceSource
/// @notice Adapte un feed Pyth vers IPriceSource (prix normalisé en 1e8).
/// @dev
///  - Revert sur données invalides: OracleRouter catch et fallback.
///  - Normalisation:
///      valeur réelle = mantissa * 10^expo
///      target(1e8)  = valeur réelle * 1e8 = mantissa * 10^(expo+8)
contract PythPriceSource is IPriceSource {
    uint256 internal constant MAX_POW10_EXP = 77;
    int32 internal constant MAX_POW10_EXP_I32 = 77;

    IPyth public immutable pyth;
    bytes32 public immutable priceId;

    error ZeroPyth();
    error ZeroId();
    error InvalidPrice();
    error ScaleOverflow();
    error InvalidTimestamp();
    error Pow10Overflow();
    error ExpoOutOfRange();

    constructor(address _pyth, bytes32 _priceId) {
        if (_pyth == address(0)) revert ZeroPyth();
        if (_priceId == bytes32(0)) revert ZeroId();
        pyth = IPyth(_pyth);
        priceId = _priceId;
    }

    function _pow10(uint256 exp) internal pure returns (uint256) {
        if (exp > MAX_POW10_EXP) revert Pow10Overflow();
        return 10 ** exp;
    }

    /// @inheritdoc IPriceSource
    function getLatestPrice() external view override returns (uint256 price, uint256 updatedAt) {
        IPyth.Price memory p = pyth.getPriceUnsafe(priceId);

        if (p.publishTime == 0) revert InvalidTimestamp();
        if (p.publishTime > block.timestamp) revert InvalidTimestamp();
        if (p.price <= 0) revert InvalidPrice();

        int32 expTo1e8 = p.expo + 8;

        if (expTo1e8 > MAX_POW10_EXP_I32 || expTo1e8 < -MAX_POW10_EXP_I32) {
            revert ExpoOutOfRange();
        }

        uint256 mantissa = SafeCast.toUint256(int256(p.price));

        if (expTo1e8 == 0) {
            price = mantissa;
        } else if (expTo1e8 < 0) {
            uint256 diff = SafeCast.toUint256(int256(-expTo1e8));
            uint256 factor = _pow10(diff);
            price = mantissa / factor;
        } else {
            uint256 diff = SafeCast.toUint256(int256(expTo1e8));
            uint256 factor = _pow10(diff);
            if (mantissa != 0 && factor > type(uint256).max / mantissa) revert ScaleOverflow();
            price = mantissa * factor;
        }

        if (price == 0) revert InvalidPrice();
        updatedAt = p.publishTime;
    }
}
