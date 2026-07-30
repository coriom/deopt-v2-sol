// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

/// @title EventTopicSnapshotV1Test
/// @notice Locks the canonical Hybrid V2 event topic hashes recorded in
///         `deployment-manifest/event-topics-v1.json`. If any canonical event
///         signature changes upstream, one of these `keccak256`s ceases to
///         match its hard-coded snapshot, and this test fails — surfacing
///         unreviewed ABI drift.
///
///  Regeneration: update the JSON file AND the corresponding line here after
///  intentionally changing an event signature. Never edit only one side.
contract EventTopicSnapshotV1Test is Test {
    function test_snapshot_registryEvents() external pure {
        _assert(
            "SubaccountCreated(address,uint32,bytes32,uint256,uint16)",
            0x8a4452859e48c40ee605ebd412f3f41b7e31d06e79a555f6ecfb9b20c712e499
        );
        _assert(
            "SubaccountLazyRegistered(address,uint32,bytes32,uint256,address,uint16)",
            0x73877816803f49c60a5d3cec46723b9b1071d38fabd08818c2cc9efd67956c65
        );
    }

    function test_snapshot_vaultEvents() external pure {
        _assert(
            "Deposit(bytes32,address,uint32,address,uint256,address,uint16)",
            0x774b18d5c0a5d41384d85f57a6cb80146a2d07b438593f2a31d5984d31ca2588
        );
        _assert(
            "Withdraw(bytes32,address,uint32,address,uint256,address,uint16)",
            0x8a1b643fe55c1af823e441f3547c965154725bfa5f705c9563854c03f6905c62
        );
        _assert(
            "InternalTransfer(bytes32,bytes32,address,uint256,address,uint32,uint32,uint16)",
            0x32624e5751759c1a980b8f332fcaa0abdd6aabdbc1d0e95f75ff89f87bb31407
        );
        _assert(
            "CollateralLocked(bytes32,address,address,uint256,uint16)",
            0xb257f3ca707cbe1b79d4d385bbb6d7615658afed8a00fbd33d1516a88fc4b3c0
        );
        _assert(
            "CollateralUnlocked(bytes32,address,address,uint256,uint16)",
            0xd02c6a9b0ac6fd79e994a04c03b1cd268c1a5199733f8d8980b5b05dbc0d1b25
        );
        _assert(
            "EngineCapabilityChanged(address,uint256,uint256,uint16)",
            0x00b5fb0400bc62e078fe1a30911831bea11f2a129c8de6928c5dee777b11ed7b
        );
        _assert(
            "EngineGuardianRevoked(address,address,uint16)",
            0x231111d13e03d6b628cfc1b76167de74d2ee3795853f17c98990b1c12d0dee0d
        );
        _assert(
            "GuardianChanged(address,address,uint16)",
            0xe5981a96dcee521a9e755eaeab8c8d4844435c46489abe3a764730fd105ded60
        );
        _assert(
            "OrphanedLockReleased(bytes32,address,address,uint256,string,uint16)",
            0x5363d70c437a3c4d6a3245067c3c6d5a9344122c7d39532e231b79ec61487827
        );
        _assert(
            "SupportedTokenAdded(address,uint16)", 0x542bbac8ffbfa75b7935c7b77e757a22d548cd26ed83e8659ce332c0267e2abe
        );
        _assert(
            "SupportedTokenRemoved(address,uint16)", 0x4915d8bab7c4f6da1041eaf7792b1186794f8f387a88679117a1f59983e84e13
        );
        _assert(
            "CollateralTokenEnteredUniverse(address,uint256,uint16)",
            0x6bc46ba5fe2bba7da05311369d1a31316991feb74c5c32b9244d622e05414471
        );
        _assert(
            "OptionPremiumTransferred(bytes32,bytes32,address,uint256,address,uint16)",
            0x2af00d3662f61faae04420ad8fbd08dd2efd15c1f286c2f7af28f5c399893676
        );
        _assert(
            "OptionFeeCharged(bytes32,bytes32,address,uint256,address,uint16)",
            0x693ee9b6475a640e28b94f71fdc3d3588c523c6c6d464eab4181837d72252b18
        );
        _assert(
            "OptionRebatePaid(bytes32,bytes32,address,uint256,address,uint16)",
            0xf65e7293067ac7ca92cfee2632423d2a37c8d276bda04348563704df384b5f9b
        );
        _assert(
            "RecoveryFinalizationWithdrawn(bytes32,address,address,uint256,address,uint16)",
            0xecd608119704e10d37afc48dd8597b2a98d20d6c749b48f412872fa7bf43daa4
        );
        _assert(
            "PauseFlagChanged(bytes32,bool,address,uint16)",
            0x104e853a70614248dd9d5db302653788320a9ff75241a0f7530c7112b285b4f7
        );
        _assert(
            "BadDebtSocialized(bytes32,address,uint256,uint16)",
            0xbf5a4b0b49b3c727af1ee9fbd3dcb46bba0e55ab3cf5b2fce9c03ce1e3cb3eac
        );
        _assert(
            "ProtocolSubaccountsInitialized(bytes32,bytes32,bytes32,uint16)",
            0x01884fa7db04aab7156225a786e04d6af4c29c76307fd0b2f851844d2edd338b
        );
        _assert(
            "EscapeControllerInitialized(address,uint16)",
            0xb7187495435bb60109ec5b301d3b6e44ebad5b3f615a76c6034413364de2beb2
        );
        _assert(
            "RecoveryFinalizerInitialized(address,uint16)",
            0x3e79856244e45d113d0f94626aaf46100fc1bc74fd482cc4c609f2371cf11410
        );
    }

    function test_snapshot_ledgerEvents() external pure {
        _assert(
            "OptionPositionOpened(bytes32,uint256,uint8,uint128,uint128,address,address,uint32,uint16)",
            0x883f3ba81bf89b4b8440b5662a218a076dea8f0475d7fbb5ac73ad687848f566
        );
        _assert(
            "OptionPositionModified(bytes32,uint256,uint8,int128,uint128,address,address,uint32,uint16)",
            0xa29da332d2948ce8cd946d9496707d9341d0e99ea98ce59658c687145ab01a99
        );
        _assert(
            "OptionPositionClosed(bytes32,uint256,uint8,address,address,uint32,uint16)",
            0x9614fc5262919739afc0198492b6b4856aa14cfd9822655633fac090083e4915
        );
        _assert(
            "OptionExercised(bytes32,uint256,uint128,uint128,int256,address,uint32,uint16)",
            0xa18d04ca4d11d009d4db2f95c286dab19e9bec8ff5bb5938fda4be17e5aea01b
        );
        _assert(
            "OptionSettled(bytes32,uint256,uint128,int256,address,uint32,uint16)",
            0x8b81624db7bb8fa4d479d51909f23e3e846d91f1c5d11d59ba54230bd3e6aec2
        );
        _assert(
            "OptionPositionLiquidated(bytes32,uint256,uint128,uint128,bytes32,uint16)",
            0xa3ca0dc331ebaafd54be6e3de63f6bb42d6151273b8b84fe1e63cf00c64e61aa
        );
    }

    function test_snapshot_optionEngineEvents() external pure {
        _assert(
            "OptionOrderPairExecuted(bytes32,bytes32,bytes32,uint256,bytes32,bytes32,address,address,uint32,uint32,uint128,uint128,uint256,address,uint8,uint8,uint128,uint128,address,uint16)",
            0x5f1468e41f3dc2025f66566667670e60b71846f79df1f84a457bf6b3a8eefe75
        );
        _assert(
            "OptionOrderFilled(bytes32,bytes32,uint256,uint8,uint8,uint128,uint128,uint128,uint128,bool,uint8,address,uint16)",
            0xfcb24be7e88ddbe667d00e7cab6f148072ed803e28e88fdde36cd66b032f307d
        );
        _assert(
            "OptionOrderCancelled(bytes32,bytes32,address,address,uint16)",
            0x5f1da788a264c52c59e6bb9ff247b6bee5a5ff1eb711bc1c8c818ddaab76006f
        );
        _assert(
            "OptionSubaccountMinValidOrderNonceAdvanced(bytes32,address,uint256,uint256,address,uint16)",
            0x047ff718fb46155865411d4da6985a211e86524f977d21a35ef88ab27ba7ef8a
        );
    }

    function test_snapshot_recoveryEvents() external pure {
        _assert(
            "RecoveryRequested(bytes32,address,uint32,uint256,uint64,uint16)",
            0x99272b7b0936c1be21184e3b8303e95653f0b27fffeb821141f4709ee161764a
        );
        _assert(
            "RecoveryActivated(bytes32,address,uint32,uint256,uint16)",
            0x3b0e643751f917ed7143bfa4a093c94ce3974b7323936d1e9157be88f61c04c9
        );
        _assert(
            "RecoveryCancelled(bytes32,address,uint32,uint16)",
            0x28cb5de9a9e210d529153dcda10f91684b09ff392ed3767218878ef472863ac4
        );
        _assert(
            "RecoveryEpochIncremented(bytes32,address,uint8,uint256,uint16)",
            0x2c4274d2cd1ce327b679899225a385eede7d99e7077fea624e305ec5b120a0c2
        );
        _assert(
            "RecoveryPauseSet(bool,uint64,address,uint16)",
            0x660fb13c236ffc96f03d35730c19036d2ba11bc7fa424824ab74209ed7dccbc7
        );
        _assert(
            "RecoveryFinalized(bytes32,address,uint32,uint256,uint64,uint8,address,uint16)",
            0x5d8bf05ccd48556b2a1560dfb9a6b16238cd8b21e91ac6120f6a59de06a1e44a
        );
    }

    function test_snapshot_replayEvents() external pure {
        _assert(
            "IntentConsumed(bytes32,address,address,bytes32,uint16)",
            0x9c3a45f7859c37449925685b802d35970473d4c3a8382fadb445bec8ceddd121
        );
        _assert(
            "NonceCancelled(address,uint256,uint256,address,uint16)",
            0x180904c26fd4aa4a2a17cfa7b96092d3a951c13c6367b175f6a2865179c0d08f
        );
        _assert(
            "OwnerRecoveryEpochAdvanced(address,uint256,uint256,address,uint16)",
            0xa3cd3ecafc2b5057fcab67c408f2a97890fec7c6c0ae6b8db41de79980dd8b0f
        );
        _assert(
            "SubaccountRecoveryEpochAdvanced(bytes32,address,uint32,uint256,uint256,address,uint16)",
            0x6c7ce309e96fc02fca79f1d6ca2f961525a081588475bc1a226cfd2e13bafcc5
        );
    }

    function test_snapshot_riskModuleEvents() external pure {
        _assert(
            "RiskParamsSet(bytes32,bytes,uint16)", 0x51e6ef537abfa0113555b58f416e2901616e96f3c2a2c34a74555b4e5d36bd03
        );
        _assert(
            "RiskModuleActivated(uint16,uint16,uint16)",
            0x098813cdf332b96a958469f45ae58a0fa0207cb89d8486c359dda570abc81f80
        );
        _assert(
            "LiquidationTriggered(bytes32,uint8,uint16)",
            0x8d20b6e898ef2ca1feee7aa63235c785a54cfe6197e8467c97f950080eb8d74e
        );
    }

    function test_snapshot_manifestEvent() external pure {
        _assert(
            "DeploymentManifestDeclared(bytes32,uint256,address,bytes32,uint16,uint16,uint16,bytes32,bytes32,uint64,uint64,uint16)",
            0x0c7768f8f3d5c0493e4b4a4f84996f6f7da7402f439d0fe28494c8a5bf0367aa
        );
    }

    /*//////////////////////////////////////////////////////////////
                           MANIFEST ERRORS
    //////////////////////////////////////////////////////////////*/

    function test_snapshot_manifestErrorSelectors() external pure {
        _assertSelector("BaseMainnetForbidden(uint256)", 0xb6d69c7f);
        _assertSelector("ZeroAddress(uint8)", 0x620b9903);
        _assertSelector("NoCode(uint8,address)", 0xdf8ca899);
        _assertSelector("DuplicateModuleAddress(uint8,uint8,address)", 0xbffa5b80);
        _assertSelector("RegistryMismatch(address,address)", 0x0cb3ba69);
        _assertSelector("CapabilityAuthorityMismatch(address,address)", 0x32aabe0e);
        _assertSelector("ProtocolSubaccountsNotInitialized()", 0x18ab54a6);
        _assertSelector("EscapeControllerNotInitialized()", 0x0c05e5cb);
        _assertSelector("RecoveryFinalizerNotInitialized()", 0x88a13f9b);
        _assertSelector("DeploymentVersionZero()", 0x4698392b);
        _assertSelector("ChainIdMismatch(uint256,uint256)", 0x21967608);
        _assertSelector("ModuleIndexOutOfRange(uint8,uint8)", 0x4b7f80eb);
    }

    function _assert(string memory sig, bytes32 expected) internal pure {
        require(keccak256(bytes(sig)) == expected, string.concat("topic drift: ", sig));
    }

    function _assertSelector(string memory sig, bytes4 expected) internal pure {
        require(bytes4(keccak256(bytes(sig))) == expected, string.concat("selector drift: ", sig));
    }
}
