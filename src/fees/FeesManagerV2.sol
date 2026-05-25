// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IFeesManagerV2} from "./IFeesManagerV2.sol";

/// @title FeesManagerV2
/// @notice Standalone signed-ppm fee manager for the V2 launch fee model.
/// @dev V2D-C is accounting-only for rebate budgets and does not move ERC20s.
contract FeesManagerV2 is IFeesManagerV2 {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    int32 public constant MAX_TAKER_FEE_PPM = 1000; // 0.10%
    int32 public constant MAX_MAKER_REBATE_PPM = -1000; // -0.10%
    uint32 public constant PPM_DENOMINATOR = 1_000_000;

    uint8 public constant TIER_COUNT = 5;

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOwner();
    error NotAccount();
    error NotFeeConsumer(address caller);
    error ZeroAddress();
    error InvalidTier();
    error InvalidFeeRate();
    error InvalidDiscount();
    error InvalidMerkleRootWindow();
    error NoMerkleRoot();
    error TierNotYetValid();
    error TierExpired();
    error ProofInvalid();
    error RebateFundingAccountUnset();
    error InsufficientRebateBudget(address settlementAsset, uint256 available, uint256 required);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public override owner;
    address public override feeRecipient;
    address public override rebateFundingAccount;

    bytes32 public override merkleRoot;
    uint64 public override rootValidFrom;
    uint64 public override rootValidUntil;

    mapping(address => bool) public override isFeeConsumer;
    mapping(address => uint256) public override rebateBudget;

    mapping(address => ClaimedTier) internal _claimedTiers;
    mapping(uint8 tier => mapping(ProductKind product => ProductFeeProfilePpm)) internal _profiles;
    mapping(uint8 tier => mapping(ProductKind product => RfqDiscountProfile)) internal _rfqDiscounts;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyFeeConsumer() {
        if (!isFeeConsumer[msg.sender]) revert NotFeeConsumer(msg.sender);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address owner_, address feeRecipient_) {
        if (owner_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();

        owner = owner_;
        feeRecipient = feeRecipient_;

        emit OwnershipTransferred(address(0), owner_);
        emit FeeRecipientSet(address(0), feeRecipient_);

        _installLaunchSchedules();
    }

    /*//////////////////////////////////////////////////////////////
                                OWNER
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();

        address oldOwner = owner;
        owner = newOwner;

        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert ZeroAddress();

        address oldRecipient = feeRecipient;
        feeRecipient = newFeeRecipient;

        emit FeeRecipientSet(oldRecipient, newFeeRecipient);
    }

    /// @notice Sets the account engines should use as the source of real rebate funds in V2D-D.
    /// @dev address(0) is allowed to intentionally disable non-zero rebate consumption.
    function setRebateFundingAccount(address newAccount) external onlyOwner {
        address oldAccount = rebateFundingAccount;
        rebateFundingAccount = newAccount;

        emit RebateFundingAccountSet(oldAccount, newAccount);
    }

    function setFeeConsumer(address consumer, bool allowed) external onlyOwner {
        if (consumer == address(0)) revert ZeroAddress();

        isFeeConsumer[consumer] = allowed;

        emit FeeConsumerSet(consumer, allowed);
    }

    function setMerkleRoot(bytes32 newRoot, uint64 validFrom, uint64 validUntil) external onlyOwner {
        if (validUntil != 0 && validFrom > validUntil) revert InvalidMerkleRootWindow();

        merkleRoot = newRoot;
        rootValidFrom = validFrom;
        rootValidUntil = validUntil;

        emit MerkleRootSet(newRoot, validFrom, validUntil);
    }

    function setFeeProfile(uint8 tier, ProductKind product, int32 makerPpm, int32 takerPpm) external onlyOwner {
        _setFeeProfile(tier, product, makerPpm, takerPpm);
    }

    function setRfqDiscountProfile(uint8 tier, ProductKind product, uint32 makerDiscountPpm, uint32 takerDiscountPpm)
        external
        onlyOwner
    {
        _setRfqDiscountProfile(tier, product, makerDiscountPpm, takerDiscountPpm);
    }

    /// @notice Accounting-only budget funding for V2D-C.
    function fundRebateBudget(address settlementAsset, uint256 amount) external onlyOwner {
        if (settlementAsset == address(0)) revert ZeroAddress();

        rebateBudget[settlementAsset] += amount;

        emit RebateBudgetFunded(settlementAsset, amount);
    }

    /// @notice Accounting-only budget withdrawal for V2D-C.
    function withdrawRebateBudget(address settlementAsset, uint256 amount, address to) external onlyOwner {
        if (settlementAsset == address(0) || to == address(0)) revert ZeroAddress();

        uint256 available = rebateBudget[settlementAsset];
        if (available < amount) revert InsufficientRebateBudget(settlementAsset, available, amount);

        unchecked {
            rebateBudget[settlementAsset] = available - amount;
        }

        emit RebateBudgetWithdrawn(settlementAsset, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  CLAIMS
    //////////////////////////////////////////////////////////////*/

    function claimTier(
        address account,
        uint8 tier,
        uint256 volume28d,
        uint32 volumeSharePpm,
        uint256 stakedDeopt,
        uint64 validFrom,
        uint64 validUntil,
        bytes32[] calldata proof
    ) external override {
        if (account == address(0)) revert ZeroAddress();
        if (msg.sender != account) revert NotAccount();
        _validateTier(tier);
        _validateClaimWindow(validFrom, validUntil);

        bytes32 root = merkleRoot;
        if (root == bytes32(0)) revert NoMerkleRoot();

        bytes32 leaf = hashTierLeaf(account, tier, volume28d, volumeSharePpm, stakedDeopt, validFrom, validUntil);
        if (!MerkleProof.verifyCalldata(proof, root, leaf)) revert ProofInvalid();

        _claimedTiers[account] = ClaimedTier({tier: tier, validUntil: validUntil});

        emit TierClaimed(account, tier, validUntil);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function claimedTiers(address account) external view override returns (ClaimedTier memory) {
        return _claimedTiers[account];
    }

    function productFeeBasis(ProductKind product) public pure override returns (FeeBasis) {
        if (product == ProductKind.OPTION) {
            return FeeBasis.PREMIUM;
        }

        return FeeBasis.NOTIONAL;
    }

    function currentTier(address account) public view override returns (uint8) {
        ClaimedTier memory tier = _claimedTiers[account];
        if (tier.validUntil != 0 && block.timestamp > tier.validUntil) {
            return 0;
        }

        return tier.tier;
    }

    function getFeeProfile(uint8 tier, ProductKind product)
        external
        view
        override
        returns (ProductFeeProfilePpm memory)
    {
        _validateTier(tier);
        return _profiles[tier][product];
    }

    function getRfqDiscountProfile(uint8 tier, ProductKind product)
        external
        view
        override
        returns (RfqDiscountProfile memory)
    {
        _validateTier(tier);
        return _rfqDiscounts[tier][product];
    }

    function hashTierLeaf(
        address account,
        uint8 tier,
        uint256 volume28d,
        uint32 volumeSharePpm,
        uint256 stakedDeopt,
        uint64 validFrom,
        uint64 validUntil
    ) public pure override returns (bytes32) {
        return keccak256(abi.encode(account, tier, volume28d, volumeSharePpm, stakedDeopt, validFrom, validUntil));
    }

    function quoteFees(
        address trader,
        ProductKind product,
        FlowKind flow,
        bool isMaker,
        address settlementAsset,
        uint256 basisAmount
    ) external view override returns (FeeQuote memory quote) {
        return _quoteFees(trader, product, flow, isMaker, settlementAsset, basisAmount);
    }

    function consumeFees(
        address trader,
        ProductKind product,
        FlowKind flow,
        bool isMaker,
        address settlementAsset,
        uint256 basisAmount
    ) external override onlyFeeConsumer returns (FeeQuote memory quote) {
        quote = _quoteFees(trader, product, flow, isMaker, settlementAsset, basisAmount);

        if (quote.isRebate) {
            if (quote.feeAmount == 0) {
                return quote;
            }
            if (rebateFundingAccount == address(0)) revert RebateFundingAccountUnset();

            uint256 available = rebateBudget[settlementAsset];
            if (available < quote.feeAmount) {
                revert InsufficientRebateBudget(settlementAsset, available, quote.feeAmount);
            }

            unchecked {
                rebateBudget[settlementAsset] = available - quote.feeAmount;
            }

            emit RebateBudgetSpent(settlementAsset, quote.feeAmount);
            emit FeeRebatedV2(
                msg.sender,
                trader,
                quote.recipient,
                settlementAsset,
                uint8(product),
                uint8(flow),
                quote.appliedPpm,
                basisAmount,
                quote.feeAmount
            );
            return quote;
        }

        if (quote.feeAmount != 0) {
            emit FeeChargedV2(
                msg.sender,
                trader,
                quote.recipient,
                settlementAsset,
                uint8(product),
                uint8(flow),
                isMaker,
                quote.appliedPpm,
                basisAmount,
                quote.feeAmount
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _quoteFees(
        address trader,
        ProductKind product,
        FlowKind flow,
        bool isMaker,
        address settlementAsset,
        uint256 basisAmount
    ) internal view returns (FeeQuote memory quote) {
        if (trader == address(0) || settlementAsset == address(0)) revert ZeroAddress();

        uint8 tier = currentTier(trader);
        int32 appliedPpm = _effectiveRatePpm(tier, product, flow, isMaker);
        bool isRebate = appliedPpm < 0;
        uint256 feeAmount = _amountFromRate(basisAmount, appliedPpm);

        quote = FeeQuote({
            appliedPpm: appliedPpm,
            basisAmount: basisAmount,
            feeAmount: feeAmount,
            isRebate: isRebate,
            tier: tier,
            product: product,
            flow: flow,
            feeBasis: productFeeBasis(product),
            isMaker: isMaker,
            settlementAsset: settlementAsset,
            recipient: _recipientForRate(trader, appliedPpm),
            rebateFundable: !isRebate || rebateBudget[settlementAsset] >= feeAmount
        });
    }

    function _recipientForRate(address trader, int32 ratePpm) internal view returns (address) {
        if (ratePpm > 0) {
            return feeRecipient;
        }
        if (ratePpm < 0) {
            return trader;
        }
        return address(0);
    }

    function _effectiveRatePpm(uint8 tier, ProductKind product, FlowKind flow, bool isMaker)
        internal
        view
        returns (int32)
    {
        ProductFeeProfilePpm memory profile = _profiles[tier][product];
        int32 ratePpm = isMaker ? profile.makerPpm : profile.takerPpm;

        if (flow != FlowKind.RFQ || ratePpm <= 0) {
            return ratePpm;
        }

        RfqDiscountProfile memory discountProfile = _rfqDiscounts[tier][product];
        uint32 discountPpm = isMaker ? discountProfile.makerDiscountPpm : discountProfile.takerDiscountPpm;
        if (discountPpm == 0) {
            return ratePpm;
        }
        if (discountPpm >= PPM_DENOMINATOR) {
            return 0;
        }

        uint256 remainingPpm = uint256(PPM_DENOMINATOR - discountPpm);
        uint256 discountedRate =
            Math.mulDiv(uint256(uint32(ratePpm)), remainingPpm, PPM_DENOMINATOR, Math.Rounding.Ceil);

        return int32(uint32(discountedRate));
    }

    function _amountFromRate(uint256 basisAmount, int32 ratePpm) internal pure returns (uint256) {
        if (basisAmount == 0 || ratePpm == 0) {
            return 0;
        }

        if (ratePpm > 0) {
            uint256 positiveRate = _positiveRateToUint256(ratePpm);
            return Math.mulDiv(basisAmount, positiveRate, PPM_DENOMINATOR, Math.Rounding.Ceil);
        }

        uint256 rebateRate = _rebateRateToUint256(ratePpm);
        return Math.mulDiv(basisAmount, rebateRate, PPM_DENOMINATOR, Math.Rounding.Floor);
    }

    function _positiveRateToUint256(int32 ratePpm) internal pure returns (uint256) {
        // casting is safe because callers pass a positive int32 bounded by MAX_TAKER_FEE_PPM.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(uint32(ratePpm));
    }

    function _rebateRateToUint256(int32 ratePpm) internal pure returns (uint256) {
        // casting is safe because callers pass a negative int32 bounded by MAX_MAKER_REBATE_PPM.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(uint32(-ratePpm));
    }

    function _validateClaimWindow(uint64 validFrom, uint64 validUntil) internal view {
        if (validUntil != 0 && validFrom > validUntil) revert InvalidMerkleRootWindow();

        if (block.timestamp < validFrom || (rootValidFrom != 0 && block.timestamp < rootValidFrom)) {
            revert TierNotYetValid();
        }

        if (
            (validUntil != 0 && block.timestamp > validUntil)
                || (rootValidUntil != 0 && block.timestamp > rootValidUntil)
        ) {
            revert TierExpired();
        }
    }

    function _installLaunchSchedules() internal {
        _setFeeProfile(0, ProductKind.OPTION, 50, 250);
        _setFeeProfile(1, ProductKind.OPTION, 0, 150);
        _setFeeProfile(2, ProductKind.OPTION, -10, 125);
        _setFeeProfile(3, ProductKind.OPTION, -25, 100);
        _setFeeProfile(4, ProductKind.OPTION, -50, 75);

        _setRfqDiscountProfile(0, ProductKind.OPTION, 0, 0);
        _setRfqDiscountProfile(1, ProductKind.OPTION, 250_000, 100_000);
        _setRfqDiscountProfile(2, ProductKind.OPTION, 500_000, 250_000);
        _setRfqDiscountProfile(3, ProductKind.OPTION, 750_000, 500_000);
        _setRfqDiscountProfile(4, ProductKind.OPTION, 1_000_000, 750_000);

        _setFeeProfile(0, ProductKind.PERP, 50, 300);
        _setFeeProfile(1, ProductKind.PERP, 0, 250);
        _setFeeProfile(2, ProductKind.PERP, -50, 200);
        _setFeeProfile(3, ProductKind.PERP, -75, 175);
        _setFeeProfile(4, ProductKind.PERP, -100, 150);

        for (uint8 tier; tier < TIER_COUNT; ++tier) {
            _setRfqDiscountProfile(tier, ProductKind.PERP, 0, 0);
        }
    }

    function _setFeeProfile(uint8 tier, ProductKind product, int32 makerPpm, int32 takerPpm) internal {
        _validateTier(tier);
        _validateProfile(makerPpm, takerPpm);

        _profiles[tier][product] = ProductFeeProfilePpm({makerPpm: makerPpm, takerPpm: takerPpm});

        emit FeeProfileUpdated(tier, uint8(product), makerPpm, takerPpm);
    }

    function _setRfqDiscountProfile(uint8 tier, ProductKind product, uint32 makerDiscountPpm, uint32 takerDiscountPpm)
        internal
    {
        _validateTier(tier);
        if (makerDiscountPpm > PPM_DENOMINATOR || takerDiscountPpm > PPM_DENOMINATOR) revert InvalidDiscount();

        _rfqDiscounts[tier][product] =
            RfqDiscountProfile({makerDiscountPpm: makerDiscountPpm, takerDiscountPpm: takerDiscountPpm});

        emit RfqDiscountProfileUpdated(tier, uint8(product), makerDiscountPpm, takerDiscountPpm);
    }

    function _validateProfile(int32 makerPpm, int32 takerPpm) internal pure {
        if (makerPpm < MAX_MAKER_REBATE_PPM || makerPpm > MAX_TAKER_FEE_PPM) revert InvalidFeeRate();
        if (takerPpm < 0 || takerPpm > MAX_TAKER_FEE_PPM) revert InvalidFeeRate();
    }

    function _validateTier(uint8 tier) internal pure {
        if (tier >= TIER_COUNT) revert InvalidTier();
    }
}
