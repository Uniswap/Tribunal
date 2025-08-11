// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibBytes} from "solady/utils/LibBytes.sol";
import {ValidityLib} from "the-compact/src/lib/ValidityLib.sol";
import {EfficiencyLib} from "the-compact/src/lib/EfficiencyLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {BlockNumberish} from "./BlockNumberish.sol";
import {PriceCurveLib} from "./lib/PriceCurveLib.sol";
import {BatchCompact, Lock, LOCK_TYPEHASH} from "the-compact/src/types/EIP712Types.sol";
import {ITheCompactClaims} from "the-compact/src/interfaces/ITheCompactClaims.sol";
import {BatchClaim as CompactBatchClaim} from "the-compact/src/types/BatchClaims.sol";
import {BatchClaimComponent, Component} from "the-compact/src/types/Components.sol";
import {ITribunalCallback} from "./Interfaces/ITribunalCallback.sol";
import {
    Adjustment,
    Mandate,
    Mandate_Fill,
    Mandate_RecipientCallback
} from "./types/TribunalStructs.sol";
import {DomainLib} from "./lib/DomainLib.sol";
import {IRecipientCallback} from "./interfaces/IRecipientCallback.sol";

/**
 * @title Tribunal
 * @author 0age
 * @notice Tribunal is a framework for processing cross-chain swap settlements against PGA (priority gas auction)
 * blockchains. It ensures that tokens are transferred according to the mandate specified by the originating sponsor
 * and enforces that a single party is able to perform the fill in the event of a dispute.
 * @dev This contract is under active development; contributions, reviews, and feedback are greatly appreciated.
 */
contract Tribunal is BlockNumberish {
    // ======== Libraries ========
    using ValidityLib for uint256;
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;
    using EfficiencyLib for bool;
    using EfficiencyLib for uint256;
    using PriceCurveLib for uint256[];
    using PriceCurveLib for uint256;
    using SignatureCheckerLib for address;
    using DomainLib for uint256;
    using DomainLib for bytes32;

    // ======== Events ========
    event Fill(
        address indexed sponsor,
        address indexed claimant,
        bytes32 claimHash,
        uint256 fillAmount,
        uint256[] claimAmounts,
        uint256 targetBlock
    );

    // ======== Custom Errors ========
    error InvalidGasPrice();
    error AlreadyClaimed();
    error InvalidTargetBlockDesignation();
    error InvalidTargetBlock(uint256 blockNumber, uint256 targetBlockNumber);
    error NotSponsor();
    error ReentrancyGuard();
    error InvalidRecipientCallbackLength();
    error ValidityConditionsNotMet();
    error QuoteInapplicableToSameChainFills();
    error InvalidFillBlock();
    error InvalidAdjustment();
    error InvalidFillHashArguments();
    error InvalidRecipientCallback();

    // ======== Type Declarations ========
    struct BatchClaim {
        uint256 chainId; // Claim processing chain ID
        BatchCompact compact;
        bytes sponsorSignature; // Authorization from the sponsor
        bytes allocatorSignature; // Authorization from the allocator
    }

    // ======== Constants ========
    /// @notice keccak256("_REENTRANCY_GUARD_SLOT")
    bytes32 private constant _REENTRANCY_GUARD_SLOT =
        0x929eee149b4bd21268e1321c4622803b452e74fd69be78111fba0332fa0fd4c0;

    /// @notice Base scaling factor (1e18).
    uint256 public constant BASE_SCALING_FACTOR = 1e18;

    /// @notice keccak256("Mandate(address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,address fillToken,uint256 minimumFillAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,address recipient,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)")
    bytes32 internal constant MANDATE_TYPEHASH =
        0x78eb489c4f76cd1d9bc735e1f4e8369b94ed75b11b35b0d5882f9c4c856a7a90;

    /// @notice keccak256("Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,address fillToken,uint256 minimumFillAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,address recipient,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate(address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)")
    bytes32 internal constant MANDATE_FILL_TYPEHASH =
        0x02ccd0f55bde7e5174b479837dce09e4f95101b3b6dfc43be8d6d42a9bd66590;

    /// @notice keccak256("Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)Mandate(address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,address fillToken,uint256 minimumFillAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,address recipient,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)")
    bytes32 internal constant MANDATE_RECIPIENT_CALLBACK_TYPEHASH =
        0x4fc45936139e9bc61053b9f1f238d4205ccd3dddaf02907ca21557ffd35160ae;

    /// @notice keccak256("Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate(address adjuster,Mandate_Fill[] fills)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,address fillToken,uint256 minimumFillAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,address recipient,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)")
    bytes32 internal constant MANDATE_BATCH_COMPACT_TYPEHASH =
        0xd1b7b490818c27a08c0bf3264fa04437fb7d4e669ade6acb8e5dde31e2d0b1c2;

    /// @notice keccak256("Mandate_Lock(bytes12 lockTag,address token,uint256 amount)")
    bytes32 internal constant MANDATE_LOCK_TYPEHASH =
        0xce4f0854d9091f37d9dfb64592eee0de534c6680a5444fd55739b61228a6e0b0;

    /// @notice keccak256("BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Lock[] commitments,Mandate mandate)Lock(bytes12 lockTag,address token,uint256 amount)Mandate(address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,address fillToken,uint256 minimumFillAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,address recipient,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)")
    bytes32 internal constant COMPACT_TYPEHASH_WITH_MANDATE =
        0xab0a4c35b998b2b78c7b8f899e1423371e4fbed77d7c8e4fc3b03816cea512a5;

    /// @notice keccak256("Adjustment(bytes32 claimHash,uint256 fillStageIndex,uint256 targetBlock,uint256[] supplementalPriceCurve,bytes32 validityConditions)")
    bytes32 internal constant ADJUSTMENT_TYPEHASH =
        0xf36c40ab215a4d17ea0a74a0db9cdb759275f8b4a6b8bfd0fb5aee1c37010d0b;

    string constant WITNESS_TYPESTRING =
        "address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,address fillToken,uint256 minimumFillAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,address recipient,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context";

    // ======== Immutables ========
    ITheCompactClaims public immutable theCompact;

    // Chain ID at deployment, used for triggering EIP-712 domain separator updates.
    uint256 private immutable _INITIAL_CHAIN_ID;

    // Initial EIP-712 domain separator, computed at deployment time.
    bytes32 private immutable _INITIAL_DOMAIN_SEPARATOR;

    // ======== Storage ========
    /// @notice Mapping of used claim hashes to claimants.
    mapping(bytes32 => address) private _dispositions;

    // ======== Modifiers ========
    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(_REENTRANCY_GUARD_SLOT) {
                // revert ReentrancyGuard();
                mstore(0, 0x8beb9d16)
                revert(0x1c, 0x04)
            }
            tstore(_REENTRANCY_GUARD_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(_REENTRANCY_GUARD_SLOT, 0)
        }
    }

    /**
     * @notice Constructor that assigns the address of The Compact and initializes immutable variables,
     * capturing the initial chain ID and domain separator.
     */
    constructor(address theCompact_) {
        theCompact = ITheCompactClaims(theCompact_);

        _INITIAL_CHAIN_ID = block.chainid;
        _INITIAL_DOMAIN_SEPARATOR = DomainLib.toCurrentDomainSeparator();
    }

    /// Allow for receiving ETH.
    receive() external payable {}

    // ======== External Functions ========

    /**
     * @notice Returns the name of the contract.
     * @return The name of the contract.
     */
    function name() external pure returns (string memory) {
        return "Tribunal";
    }

    /**
     * @notice Attempt to perform a fill.
     * @param claim The claim parameters and constraints.
     * @param mandate The fill conditions and amount derivation parameters.
     * @param adjuster The assigned adjuster for the fill.
     * @param adjustment The adjustment provided by the adjuster for the fill.
     * @param adjustmentAuthorization The authorization for the adjustment provided by the adjuster.
     * @param fillBlock The block number to target for the fill (0 allows any block).
     * @param fillIndex The index of the target fill in the fills array.
     * @param fillHashes An array of the hashes of each fill.
     * @param claimant The recipient of claimed tokens on the claim chain.
     * @return claimHash The derived claim hash.
     * @return mandateHash The derived mandate hash.
     * @return fillAmount The amount of tokens to be filled.
     * @return claimAmounts The amount of tokens to be claimed.
     */
    function fill(
        BatchClaim calldata claim,
        Mandate_Fill calldata mandate,
        address adjuster,
        Adjustment calldata adjustment,
        bytes calldata adjustmentAuthorization,
        uint256 fillBlock,
        uint256 fillIndex,
        bytes32[] calldata fillHashes,
        bytes32 claimant
    )
        external
        payable
        nonReentrant
        returns (
            bytes32 claimHash,
            bytes32 mandateHash,
            uint256 fillAmount,
            uint256[] memory claimAmounts
        )
    {
        uint256 currentBlock = _getBlockNumberish();

        assembly ("memory-safe") {
            fillBlock := xor(fillBlock, mul(iszero(fillBlock), currentBlock))
        }

        if (fillBlock != currentBlock) {
            revert InvalidFillBlock();
        }

        return _fill(
            claim.chainId,
            claim.compact,
            claim.sponsorSignature,
            claim.allocatorSignature,
            mandate,
            adjuster,
            adjustment,
            adjustmentAuthorization,
            claimant,
            fillBlock,
            fillIndex,
            fillHashes
        );
    }

    function settleOrRegister(
        bytes32 sourceClaimHash,
        BatchCompact calldata compact,
        bytes32 mandateHash
    ) external returns (bytes32 claimHash) {
        if (_dispositions[sourceClaimHash] != address(0)) {
            // TODO: iterate over all items in the provided compact and send the full balance to the claimant.
        }

        // TODO: populate the nonce and request an onchain allocation if the nonce is 0

        // TODO: call depositAndRegister on The Compact and get the claim hash
    }

    function cancel(BatchClaim calldata claim, bytes32 mandateHash)
        external
        payable
        nonReentrant
        returns (bytes32 claimHash)
    {
        return _cancel(
            claim.chainId,
            claim.compact,
            claim.sponsorSignature,
            claim.allocatorSignature,
            mandateHash,
            true
        );
    }

    function cancelChainExclusive(BatchCompact calldata compact, bytes32 mandateHash)
        external
        nonReentrant
        returns (bytes32 claimHash)
    {
        return _cancel(
            uint256(0),
            compact,
            LibBytes.emptyCalldata(), // sponsorSignature
            LibBytes.emptyCalldata(), // allocatorSignature
            mandateHash,
            false
        );
    }

    /**
     * @notice Get a quote for any native tokens supplied to pay for dispensation (i.e. cost to trigger settlement).
     * @param claim The claim parameters and constraints.
     * @param mandate The fill conditions and amount derivation parameters.
     * @param adjuster The assigned adjuster for the fill.
     * @param adjustment The adjustment provided by the adjuster for the fill.
     * @param adjustmentAuthorization The authorization for the adjustment provided by the adjuster.
     * @param fillBlock The block number to target for the fill (0 allows any block).
     * @param fillIndex The index of the target fill in the fills array.
     * @param fillHashes An array of the hashes of each fill.
     * @param claimant The recipient of claimed tokens on the claim chain.
     * @return dispensation The amount quoted to perform the dispensation.
     */
    function quote(
        BatchClaim calldata claim,
        Mandate_Fill calldata mandate,
        address adjuster,
        Adjustment calldata adjustment,
        bytes calldata adjustmentAuthorization,
        uint256 fillBlock,
        uint256 fillIndex,
        bytes32[] calldata fillHashes,
        bytes32 claimant
    ) external view returns (uint256 dispensation) {
        return _quote(
            claim.chainId,
            claim.compact,
            claim.sponsorSignature,
            claim.allocatorSignature,
            mandate,
            adjuster,
            adjustment,
            fillBlock,
            claimant,
            fillIndex,
            fillHashes
        );
    }

    /**
     * @notice Get details about the expected compact witness.
     * @return witnessTypeString The EIP-712 type string for the mandate.
     * @return tokenArg The position of the token argument.
     * @return amountArg The position of the amount argument.
     */
    function getCompactWitnessDetails()
        external
        pure
        returns (string memory witnessTypeString, uint256 tokenArg, uint256 amountArg)
    {
        return (string.concat("Mandate(", WITNESS_TYPESTRING, ")"), 4, 5);
    }

    /**
     * @notice Check if a claim has been filled.
     * @param claimHash The hash of the claim to check.
     * @return The claimant account provided by the filler if the claim has been filled, or the sponsor if it is cancelled.
     */
    function filled(bytes32 claimHash) external view returns (address) {
        return _dispositions[claimHash];
    }

    /**
     * @notice Derives the mandate hash using EIP-712 typed data.
     * @param mandate The mandate containing all hash parameters.
     * @return The derived mandate hash.
     */
    function deriveMandateHash(Mandate calldata mandate) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                MANDATE_TYPEHASH,
                block.chainid,
                address(this),
                mandate.adjuster,
                deriveFillsHash(mandate.fills)
            )
        );
    }

    // Note: consider shortening this array by one word like on The Compact with exogenous claims
    function _deriveMandateHash(
        Mandate_Fill calldata targetFill,
        address adjuster,
        uint256 fillIndex,
        bytes32[] calldata fillHashes
    ) internal view returns (bytes32) {
        if (fillIndex > fillHashes.length || fillHashes[fillIndex] != deriveFillHash(targetFill)) {
            revert InvalidFillHashArguments();
        }

        return keccak256(
            abi.encode(
                MANDATE_TYPEHASH,
                block.chainid,
                address(this),
                adjuster,
                keccak256(abi.encodePacked(fillHashes))
            )
        );
    }

    /**
     * @notice Derives hash of an array of fills using EIP-712 typed data.
     * @param fills The array of fills containing all hash parameters.
     * @return The derived fills array hash.
     */
    function deriveFillsHash(Mandate_Fill[] calldata fills) public view returns (bytes32) {
        bytes32[] memory fillHashes = new bytes32[](fills.length);
        for (uint256 i = 0; i < fills.length; ++i) {
            fillHashes[i] = deriveFillHash(fills[i]);
        }
        return keccak256(abi.encodePacked(fillHashes));
    }

    /**
     * @notice Derives a fill hash using EIP-712 typed data.
     * @param targetFill The fill containing all hash parameters.
     * @return The derived fill hash.
     */
    function deriveFillHash(Mandate_Fill calldata targetFill) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                MANDATE_FILL_TYPEHASH,
                block.chainid,
                address(this),
                targetFill.fillToken,
                targetFill.expires,
                targetFill.minimumFillAmount,
                targetFill.baselinePriorityFee,
                targetFill.scalingFactor,
                keccak256(abi.encodePacked(targetFill.priceCurve)),
                targetFill.recipient,
                deriveRecipientCallbackHash(targetFill.recipientCallback),
                targetFill.salt
            )
        );
    }

    /**
     * @notice Derives a recipient callback hash using EIP-712 typed data.
     * @param recipientCallback The recipient callback array containing all hash parameters.
     * @return The derived recipient callback hash.
     */
    function deriveRecipientCallbackHash(Mandate_RecipientCallback[] calldata recipientCallback)
        public
        view
        returns (bytes32)
    {
        if (recipientCallback.length == 0) {
            // empty hash
            return 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        } else if (recipientCallback.length != 1) {
            revert InvalidRecipientCallbackLength();
        }

        Mandate_RecipientCallback calldata callback = recipientCallback[0];

        return keccak256(
            abi.encodePacked(
                keccak256(
                    abi.encode(
                        MANDATE_RECIPIENT_CALLBACK_TYPEHASH,
                        callback.chainId,
                        _deriveClaimHash(
                            callback.compact,
                            callback.mandateHash,
                            MANDATE_LOCK_TYPEHASH,
                            MANDATE_BATCH_COMPACT_TYPEHASH
                        ),
                        callback.context
                    )
                )
            )
        );
    }

    /**
     * @notice Derives the claim hash from compact and mandate hash based on a typehash.
     * @param compact The compact parameters.
     * @param mandateHash The derived mandate hash.
     * @return The claim hash.
     */
    function _deriveClaimHash(
        BatchCompact calldata compact,
        bytes32 mandateHash,
        bytes32 lockTypehash,
        bytes32 compactTypehash
    ) internal pure returns (bytes32) {
        bytes32 commitmentsHash = _deriveCommitmentsHash(compact.commitments, lockTypehash);
        return keccak256(
            abi.encode(
                compactTypehash,
                compact.arbiter,
                compact.sponsor,
                compact.nonce,
                compact.expires,
                commitmentsHash,
                mandateHash
            )
        );
    }

    /**
     * @notice Derives the claim hash from compact and mandate hash.
     * @param compact The compact parameters.
     * @param mandateHash The derived mandate hash.
     * @return The claim hash.
     */
    function deriveClaimHash(BatchCompact calldata compact, bytes32 mandateHash)
        public
        pure
        returns (bytes32)
    {
        return _deriveClaimHash(compact, mandateHash, LOCK_TYPEHASH, COMPACT_TYPEHASH_WITH_MANDATE);
    }

    /**
     * @notice Derives fill and claim amounts based on mandate parameters and current conditions.
     * @param maximumClaimAmounts The minimum claim amounts for each commitment.
     * @param priceCurve The additional scaling factor to apply at each respective duration.
     * @param targetBlock The block where the fill can first be performed.
     * @param fillBlock The block where the fill is performed.
     * @param minimumFillAmount The minimum fill amount.
     * @param baselinePriorityFee The baseline priority fee in wei.
     * @param scalingFactor The scaling factor to apply per priority fee wei above baseline.
     * @return fillAmount The derived fill amount.
     * @return claimAmounts The derived claim amounts.
     */
    function deriveAmounts(
        Lock[] calldata maximumClaimAmounts,
        uint256[] memory priceCurve,
        uint256 targetBlock,
        uint256 fillBlock,
        uint256 minimumFillAmount,
        uint256 baselinePriorityFee,
        uint256 scalingFactor
    ) public view returns (uint256 fillAmount, uint256[] memory claimAmounts) {
        uint256 errorBuffer;
        uint256 currentScalingFactor = 1e18;
        if (targetBlock != 0) {
            if (targetBlock > fillBlock) {
                revert InvalidTargetBlock(targetBlock, fillBlock);
            }
            // Derive the total blocks passed since the target block.
            uint256 blocksPassed;
            unchecked {
                blocksPassed = fillBlock - targetBlock;
            }

            // Examine price curve and derive scaling factor modification.
            currentScalingFactor = priceCurve.getCalculatedValues(blocksPassed);
        } else {
            // Require that no price curve has been supplied.
            if (priceCurve.length != 0) {
                revert InvalidTargetBlockDesignation();
            }
        }

        if (!scalingFactor.sharesScalingDirection(currentScalingFactor)) {
            revert PriceCurveLib.InvalidPriceCurveParameters();
        }

        // Get the priority fee above baseline.
        uint256 priorityFeeAboveBaseline = _getPriorityFee(baselinePriorityFee);
        claimAmounts = new uint256[](maximumClaimAmounts.length);

        // Calculate the scaling multiplier based on priority fee.
        uint256 scalingMultiplier;
        if (scalingFactor > 1e18) {
            // For exact-in, increase fill amount.
            scalingMultiplier =
                currentScalingFactor + ((scalingFactor - 1e18) * priorityFeeAboveBaseline);
            fillAmount = minimumFillAmount.mulWadUp(scalingMultiplier);
        } else {
            // For exact-out, decrease claim amount.
            scalingMultiplier =
                currentScalingFactor - ((1e18 - scalingFactor) * priorityFeeAboveBaseline);
            fillAmount = minimumFillAmount;
            for (uint256 i = 0; i < claimAmounts.length; i++) {
                claimAmounts[i] = claimAmounts[i].mulWad(scalingMultiplier);
            }
        }

        return (fillAmount, claimAmounts);
    }

    /**
     * @notice Internal implementation of the fill function.
     * @param chainId The claim chain where the resource lock is held.
     * @param compact The compact parameters.
     * @param sponsorSignature The signature of the sponsor.
     * @param allocatorSignature The signature of the allocator.
     * @param mandate The fill conditions and amount derivation parameters.
     * @param adjuster The assigned adjuster for the fill.
     * @param adjustment The adjustment provided by the adjuster for the fill.
     * @param adjustmentAuthorization The authorization for the adjustment provided by the adjuster.
     * @param claimant The recipient of claimed tokens on the claim chain.
     * @param fillBlock The block number to target for the fill (0 allows any block).
     * @param fillIndex The index of the target fill in the fills array.
     * @param fillHashes An array of the hashes of each fill.
     * @return claimHash The derived claim hash.
     * @return mandateHash The derived mandate hash.
     * @return fillAmount The amount of tokens to be filled.
     * @return claimAmounts The amount of tokens to be claimed.
     */
    function _fill(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        Mandate_Fill calldata mandate,
        address adjuster,
        Adjustment calldata adjustment,
        bytes calldata adjustmentAuthorization,
        bytes32 claimant,
        uint256 fillBlock,
        uint256 fillIndex,
        bytes32[] calldata fillHashes
    )
        internal
        returns (
            bytes32 claimHash,
            bytes32 mandateHash,
            uint256 fillAmount,
            uint256[] memory claimAmounts
        )
    {
        // Ensure that the mandate has not expired.
        mandate.expires.later();

        address validFiller = address(uint160(uint256(adjustment.validityConditions)));

        assembly ("memory-safe") {
            validFiller := xor(validFiller, mul(iszero(validFiller), caller()))
        }

        uint256 validBlockWindow = uint256(adjustment.validityConditions) >> 160;
        if (adjustment.targetBlock + validBlockWindow > fillBlock || validFiller != msg.sender) {
            revert ValidityConditionsNotMet();
        }

        // Derive fill and claim amounts.
        (fillAmount, claimAmounts) = deriveAmounts(
            compact.commitments,
            mandate.priceCurve.applySupplementalPriceCurve(adjustment.supplementalPriceCurve),
            adjustment.targetBlock,
            fillBlock,
            mandate.minimumFillAmount,
            mandate.baselinePriorityFee,
            mandate.scalingFactor
        );

        // Derive mandate hash.
        mandateHash = _deriveMandateHash(mandate, adjuster, fillIndex, fillHashes);

        claimHash = _processClaimOrDisposition(
            compact,
            mandate,
            sponsorSignature,
            allocatorSignature,
            mandateHash,
            fillAmount,
            claimant,
            claimAmounts,
            adjustment
        );

        if (
            !adjuster.isValidSignatureNow(
                _toAdjustmentHash(adjustment, claimHash).withDomain(_domainSeparator()),
                adjustmentAuthorization
            )
        ) {
            revert InvalidAdjustment();
        }

        // Send the tokens to the recipient.
        _processFill(mandate, fillAmount);

        // Perform the callback to the recipient if one has been provided.
        performRecipientCallback(mandate, claimHash, mandateHash, fillAmount);

        // Emit the fill event.
        emit Fill(
            compact.sponsor,
            address(uint160(uint256(claimant))),
            claimHash,
            fillAmount,
            claimAmounts,
            adjustment.targetBlock
        );

        // Return any unused native tokens to the caller.
        uint256 remaining = address(this).balance;
        if (remaining > 0) {
            msg.sender.safeTransferETH(remaining);
        }
    }

    function _processClaimOrDisposition(
        BatchCompact calldata compact,
        Mandate_Fill calldata mandate,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        uint256 fillAmount,
        bytes32 claimant,
        uint256[] memory claimAmounts,
        Adjustment calldata adjustment
    ) internal returns (bytes32 claimHash) {
        if (block.chainid == mandate.chainId) {
            claimHash = _singleChainFill(
                compact,
                mandate,
                sponsorSignature,
                allocatorSignature,
                mandateHash,
                fillAmount,
                claimant,
                claimAmounts,
                adjustment
            );
        } else {
            // Derive and check claim hash.
            claimHash = deriveClaimHash(compact, mandateHash);
            if (_dispositions[claimHash] != address(0)) {
                revert AlreadyClaimed();
            }

            // Set the disposition for the given claim hash.
            _dispositions[claimHash] = address(uint160(uint256(claimant)));

            // Process the directive.
            _processDirective(
                mandate.chainId,
                compact,
                sponsorSignature,
                allocatorSignature,
                mandateHash,
                claimant,
                claimAmounts,
                adjustment.targetBlock
            );
        }
    }

    function performRecipientCallback(
        Mandate_Fill calldata mandate,
        bytes32 claimHash,
        bytes32 mandateHash,
        uint256 fillAmount
    ) internal {
        if (mandate.recipientCallback.length != 0) {
            Mandate_RecipientCallback calldata callback = mandate.recipientCallback[0];
            if (
                IRecipientCallback(mandate.recipient).tribunalCallback(
                    callback.chainId,
                    claimHash,
                    mandateHash,
                    mandate.fillToken,
                    fillAmount,
                    callback.compact,
                    callback.mandateHash,
                    callback.context
                ) != IRecipientCallback.tribunalCallback.selector
            ) {
                revert InvalidRecipientCallback();
            }
        }
    }

    function _singleChainFill(
        BatchCompact calldata compact,
        Mandate_Fill calldata mandate,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        uint256 fillAmount,
        bytes32 claimant,
        uint256[] memory claimAmounts,
        Adjustment calldata adjustment
    ) internal returns (bytes32 claimHash) {
        // Claim the tokens to the claimant.
        CompactBatchClaim memory claim;
        BatchClaimComponent memory component;
        {
            claim.allocatorData = allocatorSignature;
            claim.sponsorSignature = sponsorSignature;
            claim.sponsor = compact.sponsor;
            claim.nonce = compact.nonce;
            claim.expires = compact.expires;
            claim.witness = mandateHash;
            claim.witnessTypestring = WITNESS_TYPESTRING;
            claim.claims = new BatchClaimComponent[](claimAmounts.length);
            for (uint256 i = 0; i < claimAmounts.length; i++) {
                component.id = uint256(bytes32(compact.commitments[i].lockTag))
                    | uint256(uint160(compact.commitments[i].token));
                component.allocatedAmount = compact.commitments[i].amount;
                component.portions = new Component[](1);
                component.portions[0].claimant = uint256(claimant);
                component.portions[0].amount = claimAmounts[i];
                claim.claims[i] = component;
            }
            claimHash = theCompact.batchClaim(claim);
        }

        // Do a callback to the sender
        ITribunalCallback(msg.sender).tribunalCallback(
            claimHash,
            compact.commitments,
            claimAmounts,
            mandate.fillToken,
            mandate.minimumFillAmount,
            fillAmount
        );

        return claimHash;
    }

    function _processFill(Mandate_Fill calldata mandate, uint256 fillAmount) internal {
        // Handle native token withdrawals directly.
        if (mandate.fillToken == address(0)) {
            mandate.recipient.safeTransferETH(fillAmount);
        } else {
            // NOTE: Settling fee-on-transfer tokens will result in fewer tokens
            // being received by the recipient. Be sure to acommodate for this when
            // providing the desired fill amount.
            mandate.fillToken.safeTransferFrom(msg.sender, mandate.recipient, fillAmount);
        }
    }

    function _cancel(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        bool directive
    ) internal returns (bytes32 claimHash) {
        // Ensure the claim can only be canceled by the sponsor.
        if (msg.sender != compact.sponsor) {
            revert NotSponsor();
        }

        // Derive and check claim hash.
        claimHash = deriveClaimHash(compact, mandateHash);
        if (_dispositions[claimHash] != address(0)) {
            revert AlreadyClaimed();
        }
        _dispositions[claimHash] = msg.sender;

        // Emit the fill event even when cancelled.
        emit Fill(
            compact.sponsor,
            compact.sponsor, /*claimant*/
            claimHash,
            0, /*fillAmounts*/
            new uint256[](0), /*claimAmounts*/
            0 /*targetBlock*/
        );

        if (directive) {
            // Process the directive.
            _processDirective(
                chainId,
                compact,
                sponsorSignature,
                allocatorSignature,
                mandateHash,
                bytes32(uint256(uint160(compact.sponsor))), // claimant
                new uint256[](0), // claimAmounts
                0 // targetBlock
            );
        }

        // Return any unused native tokens to the caller.
        uint256 remaining = address(this).balance;
        if (remaining > 0) {
            msg.sender.safeTransferETH(remaining);
        }
    }

    /**
     * @notice Internal implementation of the quote function.
     * @param chainId The claim chain where the resource lock is held.
     * @param compact The compact parameters.
     * @param sponsorSignature The signature of the sponsor.
     * @param allocatorSignature The signature of the allocator.
     * @param mandate The fill conditions and amount derivation parameters.
     * @param fillBlock The block where the fill will be performed.
     * @param claimant The recipient of claimed tokens on the claim chain.
     * @return dispensation The suggested dispensation amount.
     */
    function _quote(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        Mandate_Fill calldata mandate,
        address adjuster,
        Adjustment calldata adjustment,
        uint256 fillBlock,
        bytes32 claimant,
        uint256 fillIndex,
        bytes32[] calldata fillHashes
    ) internal view returns (uint256 dispensation) {
        if (chainId == block.chainid) {
            revert QuoteInapplicableToSameChainFills();
        }

        // Ensure that the mandate has not expired.
        mandate.expires.later();

        // Derive mandate hash.
        bytes32 mandateHash = _deriveMandateHash(mandate, adjuster, fillIndex, fillHashes);

        // Derive and check claim hash
        bytes32 claimHash = deriveClaimHash(compact, mandateHash);
        if (_dispositions[claimHash] != address(0)) {
            revert AlreadyClaimed();
        }

        // Derive fill and claim amounts.
        uint256 fillAmount;
        uint256[] memory claimAmounts;
        (fillAmount, claimAmounts) = deriveAmounts(
            compact.commitments,
            mandate.priceCurve,
            adjustment.targetBlock,
            fillBlock,
            mandate.minimumFillAmount,
            mandate.baselinePriorityFee,
            mandate.scalingFactor
        );

        // Process the quote.
        dispensation = _quoteDirective(
            chainId,
            compact,
            sponsorSignature,
            allocatorSignature,
            mandateHash,
            claimant,
            claimAmounts,
            fillBlock
        );
    }

    /**
     * @notice Internal view function that returns the current EIP-712 domain separator,
     * updating it if the chain ID has changed since deployment.
     * @return The current domain separator.
     */
    function _domainSeparator() internal view virtual returns (bytes32) {
        return _INITIAL_DOMAIN_SEPARATOR.toLatest(_INITIAL_CHAIN_ID);
    }

    function _deriveCommitmentsHash(Lock[] calldata commitments, bytes32 typehash)
        internal
        pure
        returns (bytes32)
    {
        bytes32[] memory commitmentsHashes = new bytes32[](commitments.length);
        for (uint256 i = 0; i < commitments.length; i++) {
            commitmentsHashes[i] = keccak256(
                abi.encode(
                    typehash, commitments[i].lockTag, commitments[i].token, commitments[i].amount
                )
            );
        }
        return keccak256(abi.encodePacked(commitmentsHashes));
    }

    /**
     * @notice Calculates the priority fee above the baseline.
     * @param baselinePriorityFee The base fee threshold where scaling kicks in.
     * @return priorityFee The priority fee above baseline (or 0 if below).
     */
    function _getPriorityFee(uint256 baselinePriorityFee)
        internal
        view
        returns (uint256 priorityFee)
    {
        if (tx.gasprice < block.basefee) revert InvalidGasPrice();
        unchecked {
            priorityFee = tx.gasprice - block.basefee;
            if (priorityFee > baselinePriorityFee) {
                priorityFee -= baselinePriorityFee;
            } else {
                priorityFee = 0;
            }
        }
    }

    /**
     * @notice Process the mandated directive (i.e. trigger settlement).
     * @param chainId The claim chain where the resource lock is held.
     * @param compact The compact parameters.
     * @param sponsorSignature The signature of the sponsor.
     * @param allocatorSignature The signature of the allocator.
     * @param mandateHash The derived mandate hash.
     * @param claimant The recipient of claimed tokens on claim chain.
     * @param claimAmounts The amounts to claim.
     * @param targetBlock The targeted fill block, or 0 for no target block.
     */
    function _processDirective(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        bytes32 claimant,
        uint256[] memory claimAmounts,
        uint256 targetBlock
    ) internal virtual {
        // NOTE: Override & implement directive processing.
    }

    /**
     * @notice Derive the quote for any native tokens supplied to pay for dispensation (i.e. cost to trigger settlement).
     * @param chainId The claim chain where the resource lock is held.
     * @param compact The compact parameters.
     * @param sponsorSignature The signature of the sponsor.
     * @param allocatorSignature The signature of the allocator.
     * @param mandateHash The derived mandate hash.
     * @param claimant The address of the claimant.
     * @param claimAmounts The amounts to claim.
     * @return dispensation The quoted dispensation amount.
     * @param targetBlock The targeted fill block, or 0 for no target block.
     */
    function _quoteDirective(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        bytes32 claimant,
        uint256[] memory claimAmounts,
        uint256 targetBlock
    ) internal view virtual returns (uint256 dispensation) {
        chainId;
        compact;
        sponsorSignature;
        allocatorSignature;
        mandateHash;
        claimant;
        claimAmounts;
        targetBlock;

        // NOTE: Override & implement quote logic.
        return msg.sender.balance / 1000;
    }

    function _toAdjustmentHash(Adjustment calldata adjustment, bytes32 claimHash)
        internal
        pure
        returns (bytes32 adjustmentHash)
    {
        return keccak256(
            abi.encode(
                ADJUSTMENT_TYPEHASH,
                claimHash,
                adjustment.fillStageIndex,
                adjustment.targetBlock,
                keccak256(abi.encodePacked(adjustment.supplementalPriceCurve)),
                adjustment.validityConditions
            )
        );
    }
}
