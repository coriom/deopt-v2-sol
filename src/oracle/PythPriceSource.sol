// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPriceSource.sol";

/// @dev Interface minimale de Pyth sur EVM.
/// @notice On utilise getPriceUnsafe et on laisse le Router gérer la "staleness".
interface IPyth {
    struct Price {
        int64 price;        // prix brut (mantissa)
        uint64 conf;        // intervalle de confiance (ignoré ici)
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

    error InvalidPrice();
    error ExpoOutOfRange();
    error ScaleOverflow();

    constructor(address _pyth, bytes32 _priceId) {
        require(_pyth != address(0), "ZERO_PYTH");
        require(_priceId != bytes32(0), "ZERO_ID");
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

        // Mantissa doit être positive pour un prix valide
        if (p.price <= 0) revert InvalidPrice();

        // On veut normaliser en 1e8 :
        // valeur réelle = p.price * 10^expo
        // target = valeur réelle * 1e8 = p.price * 10^(expo + 8)
        //
        // Si (expo + 8) < 0 => division
        // Si (expo + 8) > 0 => multiplication
        int32 expo = p.expo;

        // Borne défensive (tu peux élargir si tu veux, mais ça protège des cas extrêmes)
        if (expo < -30 || expo > 30) revert ExpoOutOfRange();

        int32 expTo1e8 = expo + 8;

        uint256 mantissa = uint64(p.price); // safe car p.price > 0 et int64 -> uint64 ok

        if (expTo1e8 == 0) {
            price = mantissa;
        } else if (expTo1e8 < 0) {
            uint256 diff = uint32(-expTo1e8);
            // 10**diff doit rester raisonnable, diff borné par ExpoOutOfRange
            uint256 factor = 10 ** diff;
            price = mantissa / factor;
        } else {
            uint256 diff = uint32(expTo1e8);

            // Check overflow très simple (facultatif mais solide)
            // Si mantissa * 10**diff overflow => revert
            uint256 factor = 10 ** diff;
            if (mantissa != 0 && factor > type(uint256).max / mantissa) revert ScaleOverflow();

            price = mantissa * factor;
        }

        if (price == 0) revert InvalidPrice();

        updatedAt = p.publishTime;
    }
}
