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
import {ITheCompact} from "the-compact/src/interfaces/ITheCompact.sol";
import {IOnChainAllocation} from "the-compact/src/interfaces/IOnChainAllocation.sol";
import {BatchClaim as CompactBatchClaim} from "the-compact/src/types/BatchClaims.sol";
import {BatchClaimComponent, Component} from "the-compact/src/types/Components.sol";
import {ITribunalCallback} from "./interfaces/ITribunalCallback.sol";
import {ITribunal} from "./interfaces/ITribunal.sol";
import {
    Adjustment,
    Mandate,
    Fill,
    FillComponent,
    RecipientCallback,
    FillRecipient
} from "./types/TribunalStructs.sol";
import {DomainLib} from "./lib/DomainLib.sol";
import {IRecipientCallback} from "./interfaces/IRecipientCallback.sol";
import {
    MANDATE_TYPEHASH,
    MANDATE_FILL_TYPEHASH,
    MANDATE_FILL_COMPONENT_TYPEHASH,
    MANDATE_RECIPIENT_CALLBACK_TYPEHASH,
    MANDATE_BATCH_COMPACT_TYPEHASH,
    MANDATE_LOCK_TYPEHASH,
    COMPACT_TYPEHASH_WITH_MANDATE,
    ADJUSTMENT_TYPEHASH,
    WITNESS_TYPESTRING
} from "./types/TribunalTypeHashes.sol";

/**
 * @title Tribunal
 * @author 0age
 * @custom:security-contact security@uniswap.org
 * @notice Tribunal is a framework for processing cross-chain swap settlements against PGA (priority gas auction)
 * blockchains. It ensures that tokens are transferred according to the mandate specified by the originating sponsor
 * and enforces that a single party is able to perform the fill in the event of a dispute.
 * @dev This contract is under active development; contributions, reviews, and feedback are greatly appreciated.
 */
contract Tribunal is BlockNumberish, ITribunal {
    // ======== Libraries ========
    using ValidityLib for uint256;
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;
    using EfficiencyLib for bool;
    using PriceCurveLib for uint256[];
    using PriceCurveLib for uint256;
    using SignatureCheckerLib for address;
    using DomainLib for bytes32;

    // ======== Constants ========
    /// @notice keccak256("_REENTRANCY_GUARD_SLOT")
    bytes32 private constant _REENTRANCY_GUARD_SLOT =
        0x929eee149b4bd21268e1321c4622803b452e74fd69be78111fba0332fa0fd4c0;

    /// @notice Base scaling factor (1e18).
    uint256 public constant BASE_SCALING_FACTOR = 1e18;

    bytes32 private constant _EMPTY_HASH =
        0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    uint256 private constant _ADDRESS_BITS = 0xa0;

    /// @notice The Compact contract instance used for processing claims against resource locks.
    ITheCompactClaims public constant THE_COMPACT =
        ITheCompactClaims(0x00000000000000171ede64904551eeDF3C6C9788);

    // ======== Immutables ========

    // Chain ID at deployment, used for triggering EIP-712 domain separator updates.
    uint256 private immutable _INITIAL_CHAIN_ID;

    // Initial EIP-712 domain separator, computed at deployment time.
    bytes32 private immutable _INITIAL_DOMAIN_SEPARATOR;

    // ======== Storage ========
    /// @notice Mapping of used claim hashes to claimants.
    mapping(bytes32 => bytes32) private _dispositions;

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
     * @notice Constructor that initializes immutable variables,
     * capturing the initial chain ID and domain separator.
     */
    constructor() {
        _INITIAL_CHAIN_ID = block.chainid;
        _INITIAL_DOMAIN_SEPARATOR = DomainLib.toCurrentDomainSeparator();
    }

    /// Allow for receiving ETH.
    receive() external payable {}

    // ======== External Functions ========

    /// @inheritdoc ITribunal
    function fill(
        BatchClaim calldata claim,
        Fill calldata mandate,
        address adjuster,
        Adjustment calldata adjustment,
        bytes calldata adjustmentAuthorization,
        bytes32[] calldata fillHashes,
        bytes32 claimant,
        uint256 fillBlock
    )
        external
        payable
        nonReentrant
        returns (
            bytes32 claimHash,
            bytes32 mandateHash,
            uint256[] memory fillAmounts,
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
            fillHashes
        );
    }

    /// @inheritdoc ITribunal
    function settleOrRegister(
        bytes32 sourceClaimHash,
        BatchCompact calldata compact,
        bytes32 mandateHash,
        address recipient,
        bytes calldata context
    ) external payable nonReentrant returns (bytes32 registeredClaimHash) {
        if (compact.commitments.length != 1) {
            revert InvalidCommitmentsArray();
        }
        Lock calldata commitment = compact.commitments[0];

        bytes32 claimant = _dispositions[sourceClaimHash];

        // An available claimant indicates a fill, transfer all available tokens to the claimant
        if (claimant != bytes32(0)) {
            if (commitment.token == address(0)) {
                // Handle native token
                SafeTransferLib.safeTransferETH(
                    address(uint160(uint256(claimant))), address(this).balance
                );
            } else {
                // Handle ERC20 tokens
                commitment.token.safeTransferAll(address(uint160(uint256(claimant))));
            }

            return bytes32(0);
        }

        address sponsor = compact.sponsor;
        assembly ("memory-safe") {
            recipient := xor(recipient, mul(iszero(recipient), sponsor))
        }

        // An empty lockTag indicates a direct transfer
        if (commitment.lockTag == bytes12(0)) {
            if (commitment.token == address(0)) {
                // Handle native token (transfer full available balance)
                SafeTransferLib.safeTransferETH(recipient, address(this).balance);
            } else {
                // Handle ERC20 tokens (transfer full available balance)
                commitment.token.safeTransferAll(recipient);
            }
            return bytes32(0);
        }

        // Prepare the ids and amounts, dependent on the actual balance
        uint256[2][] memory idsAndAmounts = new uint256[2][](1);
        uint256 callValue = 0;
        idsAndAmounts[0][0] =
            uint256(bytes32(commitment.lockTag)) | uint256(uint160(commitment.token));
        if (compact.commitments[0].token == address(0)) {
            // Handle native token
            callValue = address(this).balance;
            idsAndAmounts[0][1] = callValue;
        } else {
            // Handle ERC20 tokens
            idsAndAmounts[0][1] = commitment.token.balanceOf(address(this));
            if (_checkCompactAllowance(commitment.token, address(this)) < idsAndAmounts[0][1]) {
                SafeTransferLib.safeApproveWithRetry(
                    commitment.token, address(THE_COMPACT), type(uint256).max
                );
            }
        }

        // An empty mandateHash indicates a deposit without a registration.
        if (mandateHash == bytes32(0)) {
            ITheCompact(address(THE_COMPACT))
            .batchDeposit{value: callValue}(idsAndAmounts, recipient);
            return bytes32(0);
        }

        // An empty nonce indicates an onchain allocator; wrap registration in prepare & execute hooks.
        if (compact.nonce == 0) {
            // Do an on chain allocation if no nonce is provided
            (, address allocator,,,) =
                ITheCompact(address(THE_COMPACT)).getLockDetails(idsAndAmounts[0][0]);

            // Prepare the allocation with the allocator
            (uint256 nonce) = IOnChainAllocation(allocator)
                .prepareAllocation(
                    compact.sponsor,
                    idsAndAmounts,
                    compact.arbiter,
                    compact.expires,
                    COMPACT_TYPEHASH_WITH_MANDATE,
                    mandateHash,
                    context
                );

            // deposit and register the tokens
            (registeredClaimHash,) = ITheCompact(address(THE_COMPACT))
            .batchDepositAndRegisterFor{
                value: callValue
            }(
                compact.sponsor,
                idsAndAmounts,
                compact.arbiter,
                nonce,
                compact.expires,
                COMPACT_TYPEHASH_WITH_MANDATE,
                mandateHash
            );

            // execute the allocation
            IOnChainAllocation(allocator)
                .executeAllocation(
                    compact.sponsor,
                    idsAndAmounts, // The allocator will retrieve the actual amounts from the balance change, so we don't need to update the amounts
                    compact.arbiter,
                    compact.expires,
                    COMPACT_TYPEHASH_WITH_MANDATE,
                    mandateHash,
                    context
                );
        } else {
            // deposit and register the tokens directly and skip an on chain allocation
            (registeredClaimHash,) = ITheCompact(address(THE_COMPACT))
            .batchDepositAndRegisterFor{
                value: callValue
            }(
                compact.sponsor,
                idsAndAmounts,
                compact.arbiter,
                compact.nonce,
                compact.expires,
                COMPACT_TYPEHASH_WITH_MANDATE,
                mandateHash
            );
        }
        return registeredClaimHash;
    }

    /// @inheritdoc ITribunal
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

    /// @inheritdoc ITribunal
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

    // ======== External View Functions ========

    /// @inheritdoc ITribunal
    function quote(
        BatchClaim calldata claim,
        Fill calldata mandate,
        address adjuster,
        Adjustment calldata adjustment,
        bytes32[] calldata fillHashes,
        bytes32 claimant,
        uint256 fillBlock
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
            fillHashes
        );
    }

    /// @inheritdoc ITribunal
    function filled(bytes32 claimHash) external view returns (bytes32) {
        return _dispositions[claimHash];
    }

    // ======== External Pure Functions ========

    /// @inheritdoc ITribunal
    function name() external pure returns (string memory) {
        return "Tribunal";
    }

    /// @inheritdoc ITribunal
    function getCompactWitnessDetails()
        external
        pure
        returns (string memory witnessTypeString, ArgDetail[] memory details)
    {
        witnessTypeString = string.concat("Mandate(", WITNESS_TYPESTRING, ")");

        details = new ArgDetail[](1);
        details[0] = ArgDetail({
            tokenPath: "fills[].components[].fillToken",
            argPath: "fills[].components[].minimumFillAmount",
            description: "Output token and minimum amount for each fill component in the Fills array"
        });
    }

    // ======== Public View Functions ========

    /// @inheritdoc ITribunal
    function deriveMandateHash(Mandate calldata mandate) public view returns (bytes32) {
        return
            keccak256(
                abi.encode(MANDATE_TYPEHASH, mandate.adjuster, deriveFillsHash(mandate.fills))
            );
    }

    /// @inheritdoc ITribunal
    function deriveFillsHash(Fill[] calldata fills) public view returns (bytes32) {
        bytes32[] memory fillHashes = new bytes32[](fills.length);
        for (uint256 i = 0; i < fills.length; ++i) {
            fillHashes[i] = deriveFillHash(fills[i]);
        }
        return keccak256(abi.encodePacked(fillHashes));
    }

    /// @inheritdoc ITribunal
    function deriveFillHash(Fill calldata targetFill) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                MANDATE_FILL_TYPEHASH,
                block.chainid,
                address(this),
                targetFill.expires,
                deriveFillComponentsHash(targetFill.components),
                targetFill.baselinePriorityFee,
                targetFill.scalingFactor,
                keccak256(abi.encodePacked(targetFill.priceCurve)),
                deriveRecipientCallbackHash(targetFill.recipientCallback),
                targetFill.salt
            )
        );
    }

    /// @notice Derives the hash of a single fill component.
    /// @param component The fill component.
    /// @return The hash of the fill component.
    function deriveFillComponentHash(FillComponent calldata component)
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                MANDATE_FILL_COMPONENT_TYPEHASH,
                component.fillToken,
                component.minimumFillAmount,
                component.recipient,
                component.applyScaling
            )
        );
    }

    /// @notice Derives the hash of the fill components array.
    /// @param components The fill components array.
    /// @return The hash of the fill components array.
    function deriveFillComponentsHash(FillComponent[] calldata components)
        public
        pure
        returns (bytes32)
    {
        bytes32[] memory componentHashes = new bytes32[](components.length);
        for (uint256 i = 0; i < components.length; ++i) {
            componentHashes[i] = deriveFillComponentHash(components[i]);
        }
        return keccak256(abi.encodePacked(componentHashes));
    }

    /// @inheritdoc ITribunal
    function deriveAmounts(
        Lock[] calldata maximumClaimAmounts,
        uint256[] memory priceCurve,
        uint256 targetBlock,
        uint256 fillBlock,
        uint256 minimumFillAmount,
        uint256 baselinePriorityFee,
        uint256 scalingFactor
    ) public view returns (uint256 fillAmount, uint256[] memory claimAmounts) {
        uint256 currentScalingFactor = BASE_SCALING_FACTOR;
        if (targetBlock != 0) {
            if (targetBlock > fillBlock) {
                revert InvalidTargetBlock(fillBlock, targetBlock);
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
        // When neutral (scalingFactor == 1e18), determine mode from currentScalingFactor.
        bool useExactIn = (scalingFactor > BASE_SCALING_FACTOR)
        .or(scalingFactor == BASE_SCALING_FACTOR && currentScalingFactor >= BASE_SCALING_FACTOR);

        if (useExactIn) {
            // For exact-in, increase fill amount and use maximum claim amounts.
            scalingMultiplier = currentScalingFactor
                + ((scalingFactor - BASE_SCALING_FACTOR) * priorityFeeAboveBaseline);
            fillAmount = minimumFillAmount.mulWadUp(scalingMultiplier);
            // Copy maximum claim amounts unchanged
            for (uint256 i = 0; i < claimAmounts.length; i++) {
                claimAmounts[i] = maximumClaimAmounts[i].amount;
            }
        } else {
            // For exact-out, decrease claim amount.
            scalingMultiplier = currentScalingFactor
                - ((BASE_SCALING_FACTOR - scalingFactor) * priorityFeeAboveBaseline);
            fillAmount = minimumFillAmount;
            // Apply scaling to maximum claim amounts
            for (uint256 i = 0; i < claimAmounts.length; i++) {
                claimAmounts[i] = maximumClaimAmounts[i].amount.mulWad(scalingMultiplier);
            }
        }

        return (fillAmount, claimAmounts);
    }

    /// @notice Derives fill amounts and claim amounts from fill components.
    /// @param maximumClaimAmounts The maximum amounts to claim.
    /// @param components The fill components.
    /// @param priceCurve The price curve to apply.
    /// @param targetBlock The target block number.
    /// @param fillBlock The fill block number.
    /// @param baselinePriorityFee The baseline priority fee.
    /// @param scalingFactor The scaling factor.
    /// @return fillAmounts The derived fill amounts for each component.
    /// @return claimAmounts The derived claim amounts.
    function deriveAmountsFromComponents(
        Lock[] calldata maximumClaimAmounts,
        FillComponent[] calldata components,
        uint256[] memory priceCurve,
        uint256 targetBlock,
        uint256 fillBlock,
        uint256 baselinePriorityFee,
        uint256 scalingFactor
    ) public view returns (uint256[] memory fillAmounts, uint256[] memory claimAmounts) {
        fillAmounts = new uint256[](components.length);

        // Calculate the common scaling values
        uint256 currentScalingFactor = BASE_SCALING_FACTOR;
        if (targetBlock != 0) {
            if (targetBlock > fillBlock) {
                revert InvalidTargetBlock(fillBlock, targetBlock);
            }
            uint256 blocksPassed;
            unchecked {
                blocksPassed = fillBlock - targetBlock;
            }
            currentScalingFactor = priceCurve.getCalculatedValues(blocksPassed);
        } else {
            if (priceCurve.length != 0) {
                revert InvalidTargetBlockDesignation();
            }
        }

        if (!scalingFactor.sharesScalingDirection(currentScalingFactor)) {
            revert PriceCurveLib.InvalidPriceCurveParameters();
        }

        uint256 priorityFeeAboveBaseline = _getPriorityFee(baselinePriorityFee);

        // Calculate the scaling multiplier
        uint256 scalingMultiplier;
        bool useExactIn = (scalingFactor > BASE_SCALING_FACTOR)
        .or(scalingFactor == BASE_SCALING_FACTOR && currentScalingFactor >= BASE_SCALING_FACTOR);

        if (useExactIn) {
            scalingMultiplier = currentScalingFactor
                + ((scalingFactor - BASE_SCALING_FACTOR) * priorityFeeAboveBaseline);
        } else {
            scalingMultiplier = currentScalingFactor
                - ((BASE_SCALING_FACTOR - scalingFactor) * priorityFeeAboveBaseline);
        }

        // Calculate fill amounts for each component
        for (uint256 i = 0; i < components.length; i++) {
            if (components[i].applyScaling) {
                if (useExactIn) {
                    fillAmounts[i] = components[i].minimumFillAmount.mulWadUp(scalingMultiplier);
                } else {
                    fillAmounts[i] = components[i].minimumFillAmount;
                }
            } else {
                // If not applying scaling, use the minimum amount as-is
                fillAmounts[i] = components[i].minimumFillAmount;
            }
        }

        // Calculate claim amounts
        claimAmounts = new uint256[](maximumClaimAmounts.length);
        if (useExactIn) {
            // For exact-in, use maximum claim amounts unchanged
            for (uint256 i = 0; i < claimAmounts.length; i++) {
                claimAmounts[i] = maximumClaimAmounts[i].amount;
            }
        } else {
            // For exact-out, apply scaling to claim amounts
            for (uint256 i = 0; i < claimAmounts.length; i++) {
                claimAmounts[i] = maximumClaimAmounts[i].amount.mulWad(scalingMultiplier);
            }
        }

        return (fillAmounts, claimAmounts);
    }

    // ======== Public Pure Functions ========

    /// @inheritdoc ITribunal
    function deriveRecipientCallbackHash(RecipientCallback[] calldata recipientCallback)
        public
        pure
        returns (bytes32)
    {
        if (recipientCallback.length == 0) {
            return _EMPTY_HASH;
        } else if (recipientCallback.length != 1) {
            revert InvalidRecipientCallbackLength();
        }

        RecipientCallback calldata callback = recipientCallback[0];

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

    /// @inheritdoc ITribunal
    function deriveClaimHash(BatchCompact calldata compact, bytes32 mandateHash)
        public
        pure
        returns (bytes32)
    {
        return _deriveClaimHash(compact, mandateHash, LOCK_TYPEHASH, COMPACT_TYPEHASH_WITH_MANDATE);
    }

    // ======== Internal State-changing Functions ========

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
     * @param fillHashes An array of the hashes of each fill.
     * @return claimHash The derived claim hash.
     * @return mandateHash The derived mandate hash.
     * @return fillAmounts The amounts of tokens to be filled for each component.
     * @return claimAmounts The amount of tokens to be claimed.
     */
    function _fill(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        Fill calldata mandate,
        address adjuster,
        Adjustment calldata adjustment,
        bytes calldata adjustmentAuthorization,
        bytes32 claimant,
        uint256 fillBlock,
        bytes32[] calldata fillHashes
    )
        internal
        returns (
            bytes32 claimHash,
            bytes32 mandateHash,
            uint256[] memory fillAmounts,
            uint256[] memory claimAmounts
        )
    {
        // Ensure that the mandate has not expired.
        mandate.expires.later();

        // Ensure correct chainId.
        if (mandate.chainId != block.chainid) {
            revert InvalidChainId();
        }

        address validFiller = address(uint160(uint256(adjustment.validityConditions)));

        assembly ("memory-safe") {
            validFiller := xor(validFiller, mul(iszero(validFiller), caller()))
        }

        uint256 validBlockWindow = uint256(adjustment.validityConditions) >> _ADDRESS_BITS;
        // A validBlockWindow of 0 means no window restriction (valid indefinitely)
        // A validBlockWindow of 1 means it must be filled on the target block
        if (((validBlockWindow != 0).and(adjustment.targetBlock + validBlockWindow <= fillBlock))
            .or(validFiller != msg.sender)) {
            revert ValidityConditionsNotMet();
        }

        // Derive fill and claim amounts.
        (fillAmounts, claimAmounts) = deriveAmountsFromComponents(
            compact.commitments,
            mandate.components,
            mandate.priceCurve.applySupplementalPriceCurve(adjustment.supplementalPriceCurve),
            adjustment.targetBlock,
            fillBlock,
            mandate.baselinePriorityFee,
            mandate.scalingFactor
        );

        // Derive mandate hash.
        mandateHash = _deriveMandateHash(mandate, adjuster, adjustment.fillIndex, fillHashes);

        claimHash = _processClaimOrDisposition(
            chainId,
            compact,
            mandate,
            sponsorSignature,
            allocatorSignature,
            mandateHash,
            fillAmounts,
            claimant,
            claimAmounts,
            adjustment
        );

        if (!adjuster.isValidSignatureNow(
                _toAdjustmentHash(adjustment, claimHash).withDomain(_domainSeparator()),
                adjustmentAuthorization
            )) {
            revert InvalidAdjustment();
        }

        // Send the tokens to the recipient.
        _processFill(mandate, fillAmounts);

        // Perform the callback to the recipient if one has been provided.
        performRecipientCallback(mandate, claimHash, mandateHash, fillAmounts);

        // Return any unused native tokens to the caller.
        uint256 remaining = address(this).balance;
        if (remaining > 0) {
            msg.sender.safeTransferETH(remaining);
        }
    }

    function _processClaimOrDisposition(
        uint256 chainId,
        BatchCompact calldata compact,
        Fill calldata mandate,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        uint256[] memory fillAmounts,
        bytes32 claimant,
        uint256[] memory claimAmounts,
        Adjustment calldata adjustment
    ) internal returns (bytes32 claimHash) {
        // Build FillRecipient array from components
        FillRecipient[] memory fillRecipients = new FillRecipient[](mandate.components.length);
        for (uint256 i = 0; i < mandate.components.length; i++) {
            fillRecipients[i] = FillRecipient({
                fillAmount: fillAmounts[i], recipient: mandate.components[i].recipient
            });
        }

        if (block.chainid == chainId && block.chainid == mandate.chainId) {
            claimHash = _singleChainFill(
                compact,
                mandate,
                sponsorSignature,
                allocatorSignature,
                mandateHash,
                fillAmounts,
                claimant,
                claimAmounts
            );

            // Emit the fill event.
            emit SingleChainFill(
                compact.sponsor,
                claimant,
                claimHash,
                fillRecipients,
                claimAmounts,
                adjustment.targetBlock
            );
        } else {
            // Derive and check claim hash.
            claimHash = deriveClaimHash(compact, mandateHash);
            if (_dispositions[claimHash] != bytes32(0)) {
                revert AlreadyClaimed();
            }

            // Set the disposition for the given claim hash.
            _dispositions[claimHash] = claimant;

            // Process the directive.
            _processDirective(
                chainId,
                compact,
                sponsorSignature,
                allocatorSignature,
                mandateHash,
                claimant,
                claimAmounts,
                adjustment.targetBlock
            );

            // Emit the fill event.
            emit CrossChainFill(
                chainId,
                compact.sponsor,
                claimant,
                claimHash,
                fillRecipients,
                claimAmounts,
                adjustment.targetBlock
            );
        }
    }

    function performRecipientCallback(
        Fill calldata mandate,
        bytes32 claimHash,
        bytes32 mandateHash,
        uint256[] memory fillAmounts
    ) internal {
        if (mandate.recipientCallback.length != 0 && mandate.components.length > 0) {
            RecipientCallback calldata callback = mandate.recipientCallback[0];
            // Use the first component for callback
            FillComponent calldata component = mandate.components[0];
            if (
                IRecipientCallback(component.recipient)
                        .tribunalCallback(
                            callback.chainId,
                            claimHash,
                            mandateHash,
                            component.fillToken,
                            fillAmounts[0],
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
        Fill calldata mandate,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        uint256[] memory fillAmounts,
        bytes32 claimant,
        uint256[] memory claimAmounts
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
            claimHash = THE_COMPACT.batchClaim(claim);
        }

        // Do a callback to the sender
        // Use first component for callback (if exists)
        if (mandate.components.length > 0) {
            ITribunalCallback(msg.sender)
                .tribunalCallback(
                    claimHash,
                    compact.commitments,
                    claimAmounts,
                    mandate.components[0].fillToken,
                    mandate.components[0].minimumFillAmount,
                    fillAmounts[0]
                );
        }

        return claimHash;
    }

    function _processFill(Fill calldata mandate, uint256[] memory fillAmounts) internal {
        // Process each fill component
        for (uint256 i = 0; i < mandate.components.length; i++) {
            FillComponent calldata component = mandate.components[i];
            uint256 componentAmount = fillAmounts[i];

            // Handle native token withdrawals directly.
            if (component.fillToken == address(0)) {
                component.recipient.safeTransferETH(componentAmount);
            } else {
                // NOTE: Settling fee-on-transfer tokens will result in fewer tokens
                // being received by the recipient. Be sure to acommodate for this when
                // providing the desired fill amount.
                component.fillToken
                    .safeTransferFrom(msg.sender, component.recipient, componentAmount);
            }
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
        if (_dispositions[claimHash] != bytes32(0)) {
            revert AlreadyClaimed();
        }
        _dispositions[claimHash] = bytes32(uint256(uint160(msg.sender)));

        // Emit the cancel event.
        emit Cancel(compact.sponsor, claimHash);

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

    // ======== Internal View Functions ========

    /**
     * @notice Derives the mandate hash from an adjuster, a target fill, an array of fill hashes,
     * and the index of the target fill in the array.
     * @param targetFill The fill being executed.
     * @param adjuster The adjuster address.
     * @param fillIndex The index of the target fill in the fillHashes array.
     * @param fillHashes The array of fill hashes.
     * @return The derived mandate hash.
     */
    function _deriveMandateHash(
        Fill calldata targetFill,
        address adjuster,
        uint256 fillIndex,
        bytes32[] calldata fillHashes
    ) internal view returns (bytes32) {
        if (fillIndex >= fillHashes.length || fillHashes[fillIndex] != deriveFillHash(targetFill)) {
            revert InvalidFillHashArguments();
        }

        return
            keccak256(
                abi.encode(MANDATE_TYPEHASH, adjuster, keccak256(abi.encodePacked(fillHashes)))
            );
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
        Fill calldata mandate,
        address adjuster,
        Adjustment calldata adjustment,
        uint256 fillBlock,
        bytes32 claimant,
        bytes32[] calldata fillHashes
    ) internal view returns (uint256 dispensation) {
        if (chainId == block.chainid) {
            revert QuoteInapplicableToSameChainFills();
        }

        // Ensure that the mandate has not expired.
        mandate.expires.later();

        // Derive mandate hash.
        bytes32 mandateHash =
            _deriveMandateHash(mandate, adjuster, adjustment.fillIndex, fillHashes);

        // Derive and check claim hash
        bytes32 claimHash = deriveClaimHash(compact, mandateHash);
        if (_dispositions[claimHash] != bytes32(0)) {
            revert AlreadyClaimed();
        }

        // Derive fill and claim amounts.
        uint256[] memory fillAmounts;
        uint256[] memory claimAmounts;
        (fillAmounts, claimAmounts) = deriveAmountsFromComponents(
            compact.commitments,
            mandate.components,
            mandate.priceCurve.applySupplementalPriceCurve(adjustment.supplementalPriceCurve),
            adjustment.targetBlock,
            fillBlock,
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

    function _checkCompactAllowance(address token, address owner)
        internal
        view
        returns (uint256 amount)
    {
        address compact = address(THE_COMPACT);
        assembly ("memory-safe") {
            mstore(0x14, owner) // Store the `owner` argument.
            mstore(0x34, compact)
            mstore(0x00, 0xdd62ed3e000000000000000000000000) // `allowance(address,address)`.
            amount := mul( // The arguments of `mul` are evaluated from right to left.
                mload(0x20),
                and( // The arguments of `and` are evaluated from right to left.
                    gt(returndatasize(), 0x1f), // At least 32 bytes returned.
                    staticcall(gas(), token, 0x10, 0x44, 0x20, 0x20)
                )
            )
            mstore(0x34, 0)
        }
    }

    /**
     * @notice Internal view function that returns the current EIP-712 domain separator,
     * updating it if the chain ID has changed since deployment.
     * @return The current domain separator.
     */
    function _domainSeparator() internal view virtual returns (bytes32) {
        return _INITIAL_DOMAIN_SEPARATOR.toLatest(_INITIAL_CHAIN_ID);
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

    // ======== Internal Pure Functions ========

    /**
     * @notice Derives the claim hash from compact and mandate hash based on a typehash.
     * @param compact The compact parameters.
     * @param mandateHash The derived mandate hash.
     * @param lockTypehash The lock typehash.
     * @param compactTypehash The compact typehash.
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

    function _toAdjustmentHash(Adjustment calldata adjustment, bytes32 claimHash)
        internal
        pure
        returns (bytes32 adjustmentHash)
    {
        return keccak256(
            abi.encode(
                ADJUSTMENT_TYPEHASH,
                claimHash,
                adjustment.fillIndex,
                adjustment.targetBlock,
                keccak256(abi.encodePacked(adjustment.supplementalPriceCurve)),
                adjustment.validityConditions
            )
        );
    }
}
