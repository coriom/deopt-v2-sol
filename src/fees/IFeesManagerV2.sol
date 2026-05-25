// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title IFeesManagerV2
/// @notice Signed-ppm fee interface for DeOpt v2 options, perps, and RFQ flows.
/// @dev This interface is intentionally standalone and does not replace V1.
interface IFeesManagerV2 {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    enum ProductKind {
        OPTION,
        PERP
    }

    enum FlowKind {
        ORDERBOOK,
        RFQ
    }

    enum FeeBasis {
        PREMIUM,
        NOTIONAL
    }

    struct ProductFeeProfilePpm {
        int32 makerPpm;
        int32 takerPpm;
    }

    struct RfqDiscountProfile {
        uint32 makerDiscountPpm;
        uint32 takerDiscountPpm;
    }

    struct ClaimedTier {
        uint8 tier;
        uint64 validUntil;
    }

    struct FeeQuote {
        int32 appliedPpm;
        uint256 basisAmount;
        uint256 feeAmount;
        bool isRebate;
        uint8 tier;
        ProductKind product;
        FlowKind flow;
        FeeBasis feeBasis;
        bool isMaker;
        address settlementAsset;
        address recipient;
        bool rebateFundable;
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function owner() external view returns (address);

    function feeRecipient() external view returns (address);

    function rebateFundingAccount() external view returns (address);

    function merkleRoot() external view returns (bytes32);

    function rootValidFrom() external view returns (uint64);

    function rootValidUntil() external view returns (uint64);

    function rebateBudget(address settlementAsset) external view returns (uint256);

    function isFeeConsumer(address consumer) external view returns (bool);

    function claimedTiers(address account) external view returns (ClaimedTier memory);

    function productFeeBasis(ProductKind product) external pure returns (FeeBasis);

    function currentTier(address account) external view returns (uint8);

    function getFeeProfile(uint8 tier, ProductKind product) external view returns (ProductFeeProfilePpm memory);

    function getRfqDiscountProfile(uint8 tier, ProductKind product) external view returns (RfqDiscountProfile memory);

    function hashTierLeaf(
        address account,
        uint8 tier,
        uint256 volume28d,
        uint32 volumeSharePpm,
        uint256 stakedDeopt,
        uint64 validFrom,
        uint64 validUntil
    ) external pure returns (bytes32);

    function quoteFees(
        address trader,
        ProductKind product,
        FlowKind flow,
        bool isMaker,
        address settlementAsset,
        uint256 basisAmount
    ) external view returns (FeeQuote memory quote);

    /*//////////////////////////////////////////////////////////////
                              STATE CHANGES
    //////////////////////////////////////////////////////////////*/

    function consumeFees(
        address trader,
        ProductKind product,
        FlowKind flow,
        bool isMaker,
        address settlementAsset,
        uint256 basisAmount
    ) external returns (FeeQuote memory quote);

    function claimTier(
        address account,
        uint8 tier,
        uint256 volume28d,
        uint32 volumeSharePpm,
        uint256 stakedDeopt,
        uint64 validFrom,
        uint64 validUntil,
        bytes32[] calldata proof
    ) external;

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event FeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);

    event RebateFundingAccountSet(address indexed oldAccount, address indexed newAccount);

    event FeeConsumerSet(address indexed consumer, bool allowed);

    event MerkleRootSet(bytes32 indexed root, uint64 validFrom, uint64 validUntil);

    event TierClaimed(address indexed account, uint8 tier, uint64 validUntil);

    event FeeProfileUpdated(uint8 indexed tier, uint8 indexed product, int32 makerPpm, int32 takerPpm);

    event RfqDiscountProfileUpdated(
        uint8 indexed tier, uint8 indexed product, uint32 makerDiscountPpm, uint32 takerDiscountPpm
    );

    event RebateBudgetFunded(address indexed settlementAsset, uint256 amount);

    event RebateBudgetWithdrawn(address indexed settlementAsset, address indexed to, uint256 amount);

    event RebateBudgetSpent(address indexed settlementAsset, uint256 amount);

    event FeeChargedV2(
        address indexed consumer,
        address indexed trader,
        address indexed recipient,
        address settlementAsset,
        uint8 productKind,
        uint8 flowKind,
        bool isMaker,
        int32 feePpm,
        uint256 basisAmount,
        uint256 feeAmount
    );

    event FeeRebatedV2(
        address indexed consumer,
        address indexed trader,
        address indexed recipient,
        address settlementAsset,
        uint8 productKind,
        uint8 flowKind,
        int32 rebatePpm,
        uint256 basisAmount,
        uint256 rebateAmount
    );
}
