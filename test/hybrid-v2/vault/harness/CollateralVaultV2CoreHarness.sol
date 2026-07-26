// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {CollateralVaultV2Core} from "../../../../src/hybrid-v2/vault/CollateralVaultV2Core.sol";

/// @title CollateralVaultV2CoreHarness
/// @notice Test-only concrete of the abstract V2-A custody core. Adds nothing beyond
///         the constructor so tests may deploy and exercise the abstract in isolation.
contract CollateralVaultV2CoreHarness is CollateralVaultV2Core {
    constructor(address registry_, address governance_, address guardian_)
        CollateralVaultV2Core(registry_, governance_, guardian_)
    {}
}
