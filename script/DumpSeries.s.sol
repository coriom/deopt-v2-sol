// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/OptionProductRegistry.sol";

/// @title DumpSeries
/// @notice Script de debug pour afficher toutes les séries d'options enregistrées
///         dans OptionProductRegistry.
contract DumpSeries is Script {
    // 📌 À RENSEIGNER avant d'exécuter
    address constant OPTION_REGISTRY_ADDR = 0x0000000000000000000000000000000000000000;

    function run() external {
        OptionProductRegistry reg = OptionProductRegistry(OPTION_REGISTRY_ADDR);

        uint256 total = reg.totalSeries();
        console2.log("Total series:", total);

        for (uint256 i = 0; i < total; i++) {
            uint256 optionId = reg.seriesAt(i);
            OptionProductRegistry.OptionSeries memory s = reg.getSeries(optionId);

            console2.log("==================================");
            console2.log("Index      :", i);
            console2.log("optionId   :", optionId);
            console2.log("underlying :", s.underlying);
            console2.log("settlement :", s.settlementAsset);
            console2.log("expiry     :", uint256(s.expiry));
            console2.log("strike (1e8):", uint256(s.strike));
            console2.log("isCall     :", s.isCall);
            console2.log("isEuropean :", s.isEuropean);
            console2.log("isActive   :", s.isActive);
        }

        console2.log("==================================");
        console2.log("Dump terminé ✅");
    }
}
