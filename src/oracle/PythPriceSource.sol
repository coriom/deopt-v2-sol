// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPriceSource.sol";

/// @dev Interface minimale de Pyth sur EVM.
/// @notice On utilise getPriceUnsafe et on laisse le Router gérer la "staleness".
interface IPyth {
    struct Price {
        int64 price;        // mantissa
        uint64 conf;        // ignoré
        int32 expo;         // exponent (ex: -8 => 1e-8)
        uint256 publishTime;
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory);
}

/// @title PythPriceSource
/// @notice Adapte un feed Pyth vers IPriceSource (prix normalisé en 1e8).
contract PythPriceSource is IPriceSource {
    IPyth public immutable pyth;
    bytes32 public immutable priceId;

    error ZeroPyth();
    error ZeroId();
    error InvalidPrice();
    error ExpoOutOfRange();
    error ScaleOverflow();
    error InvalidTimestamp();

    constructor(address _pyth, bytes32 _priceId) {
        if (_pyth == address(0)) revert ZeroPyth();
        if (_priceId == bytes32(0)) revert ZeroId();
        pyth = IPyth(_pyth);
        priceId = _priceId;
    }

    /// @inheritdoc IPriceSource
    function getLatestPrice()
        external
        view
        override
        returns (uint256 price, uint256 updatedAt)
    {
        IPyth.Price memory p = pyth.getPriceUnsafe(priceId);

        if (p.publishTime == 0) revert InvalidTimestamp();

        // Mantissa doit être positive pour un prix valide
        if (p.price <= 0) revert InvalidPrice();

        // Normalisation en 1e8 :
        // valeur réelle = mantissa * 10^expo
        // target = valeur réelle * 1e8 = mantissa * 10^(expo + 8)
        int32 expo = p.expo;

        // Borne défensive
        if (expo < -30 || expo > 30) revert ExpoOutOfRange();

        int32 expTo1e8 = expo + 8;

        // p.price est int64 > 0, conversion safe vers uint256
        uint256 mantissa = uint256(uint64(p.price));

        if (expTo1e8 == 0) {
            price = mantissa;
        } else if (expTo1e8 < 0) {
            uint256 diff = uint256(uint32(-expTo1e8));
            uint256 factor = 10 ** diff;
            price = mantissa / factor;
        } else {
            uint256 diff = uint256(uint32(expTo1e8));
            uint256 factor = 10 ** diff;
            if (mantissa != 0 && factor > type(uint256).max / mantissa) revert ScaleOverflow();
            price = mantissa * factor;
        }

        if (price == 0) revert InvalidPrice();

        updatedAt = p.publishTime;
    }
}
