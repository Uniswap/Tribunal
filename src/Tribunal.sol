// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibBytes} from "solady/utils/LibBytes.sol";
import {ValidityLib} from "the-compact/src/lib/ValidityLib.sol";
import {EfficiencyLib} from "the-compact/src/lib/EfficiencyLib.sol";
import {FixedPointMathLib} from "the-compact/lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "the-compact/lib/solady/src/utils/SafeTransferLib.sol";
import {BlockNumberish} from "./BlockNumberish.sol";
import {DecayParameterLib} from "./lib/DecayParameterLib.sol";
import {BatchCompact, Lock, LOCK_TYPEHASH} from "the-compact/src/types/EIP712Types.sol";
import {ITheCompactClaims} from "the-compact/src/interfaces/ITheCompactClaims.sol";
import {BatchClaim as CompactBatchClaim} from "the-compact/src/types/BatchClaims.sol";
import {BatchClaimComponent, Component} from "the-compact/src/types/Components.sol";
import {ITribunalCallback} from "./Interfaces/ITribunalCallback.sol";

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
    using DecayParameterLib for uint256[];

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

    // ======== Type Declarations ========

    struct BatchClaim {
        uint256 chainId; // Claim processing chain ID
        BatchCompact compact;
        bytes sponsorSignature; // Authorization from the sponsor
        bytes allocatorSignature; // Authorization from the allocator
    }

    struct Mandate {
        // uint256 chainId (implicit arg, included in EIP712 payload).
        // address tribunal (implicit arg, included in EIP712 payload).
        address recipient; // Recipient of filled tokens.
        uint256 expires; // Mandate expiration timestamp.
        address token; // Fill token (address(0) for native).
        uint256 minimumAmount; // Minimum fill amount.
        uint256 baselinePriorityFee; // Base fee threshold where scaling kicks in.
        uint256 scalingFactor; // Fee scaling multiplier (1e18 baseline).
        uint256[] decayCurve; // Block durations, fill increases, & claim decreases.
        bytes32 salt; // Replay protection parameter.
    }

    // ======== Constants ========

    /// @notice keccak256("_REENTRANCY_GUARD_SLOT")
    bytes32 private constant _REENTRANCY_GUARD_SLOT =
        0x929eee149b4bd21268e1321c4622803b452e74fd69be78111fba0332fa0fd4c0;

    /// @notice Base scaling factor (1e18).
    uint256 public constant BASE_SCALING_FACTOR = 1e18;

    /// @notice keccak256("Mandate(uint256 chainId,address tribunal,address recipient,uint256 expires,address token,uint256 minimumAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] decayCurve,bytes32 salt)")
    bytes32 internal constant MANDATE_TYPEHASH =
        0x74d9c10530859952346f3e046aa2981a24bb7524b8394eb45a9deddced9d6501;

    /// @notice keccak256("Compact(address arbiter,address sponsor,uint256 nonce,uint256 expires,uint256 id,uint256 amount,Mandate mandate)Mandate(uint256 chainId,address tribunal,address recipient,uint256 expires,address token,uint256 minimumAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] decayCurve,bytes32 salt)")
    bytes32 internal constant COMPACT_TYPEHASH_WITH_MANDATE =
        0xfd9cda0e5e31a3a3476cb5b57b07e2a4d6a12815506f69c880696448cd9897a5;

    string constant WITNESS_TYPESTRING =
        "uint256 chainId,address tribunal,address recipient,uint256 expires,address token,uint256 minimumAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] decayCurve,bytes32 salt";

    ITheCompactClaims public immutable theCompact;

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

    // ======== Constructor ========

    constructor(address theCompact_) {
        theCompact = ITheCompactClaims(theCompact_);
    }

    // ======== External Functions ========

    /**
     * @notice Returns the name of the contract.
     * @return The name of the contract.
     */
    function name() external pure returns (string memory) {
        return "Tribunal";
    }

    /**
     * @notice Attempt to fill a cross-chain swap.
     * @param claim The claim parameters and constraints.
     * @param mandate The fill conditions and amount derivation parameters.
     * @param claimant The recipient of claimed tokens on the claim chain, combined with a lockTag indicating the fillers intent.
     * @return mandateHash The derived mandate hash.
     * @return fillAmount The amount of tokens to be filled.
     * @return claimAmounts The amount of tokens to be claimed.
     */
    function fill(BatchClaim calldata claim, Mandate calldata mandate, bytes32 claimant)
        external
        payable
        nonReentrant
        returns (bytes32 mandateHash, uint256 fillAmount, uint256[] memory claimAmounts)
    {
        return _fill(
            claim.chainId,
            claim.compact,
            claim.sponsorSignature,
            claim.allocatorSignature,
            mandate,
            claimant,
            uint256(0),
            uint256(0)
        );
    }

    /**
     * @notice Attempt to fill a cross-chain swap at a specific block number.
     * @param claim The claim parameters and constraints.
     * @param mandate The fill conditions and amount derivation parameters.
     * @param claimant The recipient of claimed tokens on the claim chain.
     * @param targetBlock The block number to target for the fill.
     * @param maximumBlocksAfterTarget Blocks after target that are still fillable.
     * @return mandateHash The derived mandate hash.
     * @return fillAmount The amount of tokens to be filled.
     * @return claimAmounts The amount of tokens to be claimed.
     */
    function fill(
        BatchClaim calldata claim,
        Mandate calldata mandate,
        bytes32 claimant,
        uint256 targetBlock,
        uint256 maximumBlocksAfterTarget
    )
        external
        payable
        nonReentrant
        returns (bytes32 mandateHash, uint256 fillAmount, uint256[] memory claimAmounts)
    {
        return _fill(
            claim.chainId,
            claim.compact,
            claim.sponsorSignature,
            claim.allocatorSignature,
            mandate,
            claimant,
            targetBlock,
            maximumBlocksAfterTarget
        );
    }

    function cancel(BatchClaim calldata claim, Mandate calldata mandate)
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
            mandate,
            true
        );
    }

    function cancelChainExclusive(BatchCompact calldata compact, Mandate calldata mandate)
        external
        nonReentrant
        returns (bytes32 claimHash)
    {
        return _cancel(
            uint256(0),
            compact,
            LibBytes.emptyCalldata(), // sponsorSignature
            LibBytes.emptyCalldata(), // allocatorSignature
            mandate,
            false
        );
    }

    /**
     * @notice Get a quote for any native tokens supplied to pay for dispensation (i.e. cost to trigger settlement).
     * @param claim The claim parameters and constraints.
     * @param mandate The fill conditions and amount derivation parameters.
     * @param claimant The address of the claimant.
     * @return dispensation The suggested dispensation amount.
     */
    function quote(BatchClaim calldata claim, Mandate calldata mandate, bytes32 claimant)
        external
        view
        returns (uint256 dispensation)
    {
        return _quote(
            claim.chainId,
            claim.compact,
            claim.sponsorSignature,
            claim.allocatorSignature,
            mandate,
            claimant
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
        return (
            "Mandate mandate)Mandate(uint256 chainId,address tribunal,address recipient,uint256 expires,address token,uint256 minimumAmount,uint256 baselinePriorityFee,uint256 scalingFactor,bytes32 salt)",
            4,
            5
        );
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
                mandate.recipient,
                mandate.expires,
                mandate.token,
                mandate.minimumAmount,
                mandate.baselinePriorityFee,
                mandate.scalingFactor,
                keccak256(abi.encodePacked(mandate.decayCurve)),
                mandate.salt
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
        bytes32 commitmentsHash = _deriveCommitmentsHash(compact.commitments);
        return keccak256(
            abi.encode(
                COMPACT_TYPEHASH_WITH_MANDATE,
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
     * @notice Derives fill and claim amounts based on mandate parameters and current conditions.
     * @param maximumClaimAmounts The minimum claim amounts for each commitment.
     * @param claimDecreaseBPS The claim decrease in basis points.
     * @param minimumFillAmount The minimum fill amount.
     * @param fillIncreaseBPS The fill increase in basis points.
     * @param baselinePriorityFee The baseline priority fee in wei.
     * @param scalingFactor The scaling factor to apply per priority fee wei above baseline.
     * @return fillAmount The derived fill amount.
     * @return claimAmounts The derived claim amounts.
     */
    function deriveAmounts(
        Lock[] calldata maximumClaimAmounts,
        uint256 claimDecreaseBPS,
        uint256 minimumFillAmount,
        uint256 fillIncreaseBPS,
        uint256 baselinePriorityFee,
        uint256 scalingFactor
    ) public view returns (uint256 fillAmount, uint256[] memory claimAmounts) {
        // Get the priority fee above baseline.
        uint256 priorityFeeAboveBaseline = _getPriorityFee(baselinePriorityFee);
        claimAmounts = new uint256[](maximumClaimAmounts.length);
        // Decrease the provided claim amounts by the claim decrease BPS.
        for (uint256 i = 0; i < maximumClaimAmounts.length; i++) {
            claimAmounts[i] = maximumClaimAmounts[i].amount
                - maximumClaimAmounts[i].amount.fullMulDiv(claimDecreaseBPS, 10_000);
        }
        // Increase the fill amount by the fill increase BPS.
        fillAmount = minimumFillAmount + minimumFillAmount.fullMulDivUp(fillIncreaseBPS, 10_000);

        // If no fee above baseline or no scaling factor, return original amounts.
        if ((priorityFeeAboveBaseline == 0).or(scalingFactor == 1e18)) {
            return (minimumFillAmount, claimAmounts);
        }

        // Calculate the scaling multiplier based on priority fee.
        uint256 scalingMultiplier;
        if (scalingFactor > 1e18) {
            // For exact-in, increase fill amount.
            scalingMultiplier = 1e18 + ((scalingFactor - 1e18) * priorityFeeAboveBaseline);
            fillAmount = minimumFillAmount.mulWadUp(scalingMultiplier);
        } else {
            // For exact-out, decrease claim amount.
            scalingMultiplier = 1e18 - ((1e18 - scalingFactor) * priorityFeeAboveBaseline);
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
     * @param claimant The recipient of claimed tokens on the claim chain.
     * @param targetBlock The block number to target for the fill.
     * @param maximumBlocksAfterTarget Blocks after target that are still fillable.
     * @return mandateHash The derived mandate hash.
     * @return fillAmount The amount of tokens to be filled.
     * @return claimAmounts The amount of tokens to be claimed.
     */
    function _fill(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        Mandate calldata mandate,
        bytes32 claimant,
        uint256 targetBlock,
        uint256 maximumBlocksAfterTarget
    ) internal returns (bytes32 mandateHash, uint256 fillAmount, uint256[] memory claimAmounts) {
        // Ensure that the mandate has not expired.
        mandate.expires.later();

        uint256 errorBuffer;
        uint256 currentFillIncreaseBPS;
        uint256 currentClaimDecreasesBPS;
        if (targetBlock != 0) {
            if (targetBlock > _getBlockNumberish()) {
                revert InvalidTargetBlock(targetBlock, _getBlockNumberish());
            }
            // Derive the total blocks passed since the target block.
            uint256 blocksPassed = _getBlockNumberish() - targetBlock;

            // Require that total blocks passed does not exceed maximum.
            errorBuffer |= (blocksPassed > maximumBlocksAfterTarget).asUint256();

            // Examine decay curve and derive fill & claim modifications.
            (currentFillIncreaseBPS, currentClaimDecreasesBPS) =
                mandate.decayCurve.getCalculatedValues(blocksPassed);
        } else {
            // Require that no decay curve has been supplied.
            errorBuffer |= (mandate.decayCurve.length != 0).asUint256();
        }

        // Require that target block & decay curve were correctly designated.
        if (errorBuffer == 1) {
            revert InvalidTargetBlockDesignation();
        }

        // Derive mandate hash.
        mandateHash = deriveMandateHash(mandate);

        // Derive and check claim hash.
        bytes32 claimHash = deriveClaimHash(compact, mandateHash);
        if (_dispositions[claimHash] != address(0)) {
            revert AlreadyClaimed();
        }
        _dispositions[claimHash] = address(uint160(uint256(claimant)));

        // Derive fill and claim amounts.
        (fillAmount, claimAmounts) = deriveAmounts(
            compact.commitments,
            currentClaimDecreasesBPS,
            mandate.minimumAmount,
            currentFillIncreaseBPS,
            mandate.baselinePriorityFee,
            mandate.scalingFactor
        );

        // Process single chain claims.
        if (chainId == block.chainid) {
            _processSingleChainClaim(
                compact,
                mandate,
                sponsorSignature,
                allocatorSignature,
                mandateHash,
                fillAmount,
                claimant,
                claimAmounts,
                targetBlock,
                maximumBlocksAfterTarget
            );
            return (mandateHash, fillAmount, claimAmounts);
        }

        // Send the tokens to the recipient.
        _processFill(mandate, fillAmount);

        // Emit the fill event.
        emit Fill(
            compact.sponsor,
            address(uint160(uint256(claimant))),
            claimHash,
            fillAmount,
            claimAmounts,
            targetBlock
        );

        // Process the directive.
        _processDirective(
            chainId,
            compact,
            sponsorSignature,
            allocatorSignature,
            mandateHash,
            claimant,
            claimAmounts,
            targetBlock,
            maximumBlocksAfterTarget
        );

        // Return any unused native tokens to the caller.
        uint256 remaining = address(this).balance;
        if (remaining > 0) {
            msg.sender.safeTransferETH(remaining);
        }
    }

    function _cancel(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        Mandate calldata mandate,
        bool directive
    ) internal returns (bytes32 claimHash) {
        // Ensure the claim can only be canceled by the sponsor.
        if (msg.sender != compact.sponsor) {
            revert NotSponsor();
        }

        // Ensure that the mandate has not expired.
        mandate.expires.later();

        // Derive mandate hash.
        bytes32 mandateHash = deriveMandateHash(mandate);

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
                0, // targetBlock,
                0 // maximumBlocksAfterTarget
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
     * @param claimant The recipient of claimed tokens on the claim chain.
     * @return dispensation The suggested dispensation amount.
     */
    function _quote(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        Mandate calldata mandate,
        bytes32 claimant
    ) internal view returns (uint256 dispensation) {
        // Ensure that the mandate has not expired.
        mandate.expires.later();

        // Derive mandate hash.
        bytes32 mandateHash = deriveMandateHash(mandate);

        // Derive and check claim hash
        bytes32 claimHash = deriveClaimHash(compact, mandateHash);
        if (_dispositions[claimHash] != address(0)) {
            revert AlreadyClaimed();
        }

        // Derive fill and claim amounts.
        (, uint256[] memory claimAmounts) = deriveAmounts(
            compact.commitments,
            0, // claimDecreaseBPS
            mandate.minimumAmount,
            0, // fillIncreaseBPS
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
            _getBlockNumberish(),
            255
        );
    }

    function _processSingleChainClaim(
        BatchCompact calldata compact,
        Mandate calldata mandate,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        uint256 fillAmount,
        bytes32 claimant,
        uint256[] memory claimAmounts,
        uint256 targetBlock,
        uint256 maximumBlocksAfterTarget
    ) internal {
        // Claim the tokens to the claimant.
        CompactBatchClaim memory claim;
        claim.allocatorData =
            _createAllocatorData(targetBlock, maximumBlocksAfterTarget, allocatorSignature);
        claim.sponsorSignature = sponsorSignature;
        claim.sponsor = compact.sponsor;
        claim.nonce = compact.nonce;
        claim.expires = compact.expires;
        claim.witness = mandateHash;
        claim.witnessTypestring = WITNESS_TYPESTRING;
        claim.claims = new BatchClaimComponent[](claimAmounts.length);
        for (uint256 i = 0; i < claimAmounts.length; i++) {
            BatchClaimComponent memory component;
            component.id = uint256(bytes32(compact.commitments[i].lockTag))
                | uint256(uint160(compact.commitments[i].token));
            component.allocatedAmount = compact.commitments[i].amount;
            component.portions = new Component[](1);
            component.portions[0].claimant = uint256(claimant);
            component.portions[0].amount = claimAmounts[i];
            claim.claims[i] = component;
        }
        theCompact.batchClaim(claim);

        // Do a callback to the sender
        ITribunalCallback(msg.sender).tribunalCallback(
            compact.commitments, claimAmounts, mandate.token, mandate.minimumAmount, fillAmount
        );

        // Send the tokens to the recipient
        _processFill(mandate, fillAmount);
    }

    function _processFill(Mandate calldata mandate, uint256 fillAmount) internal {
        // Handle native token withdrawals directly.
        if (mandate.token == address(0)) {
            mandate.recipient.safeTransferETH(fillAmount);
        } else {
            // NOTE: Settling fee-on-transfer tokens will result in fewer tokens
            // being received by the recipient. Be sure to acommodate for this when
            // providing the desired fill amount.
            mandate.token.safeTransferFrom(msg.sender, mandate.recipient, fillAmount);
        }
    }

    function _deriveCommitmentsHash(Lock[] calldata commitments) internal pure returns (bytes32) {
        bytes32[] memory commitmentsHashes = new bytes32[](commitments.length);
        for (uint256 i = 0; i < commitments.length; i++) {
            commitmentsHashes[i] = keccak256(
                abi.encode(
                    LOCK_TYPEHASH,
                    commitments[i].lockTag,
                    commitments[i].token,
                    commitments[i].amount
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
     * @param maximumBlocksAfterTarget Blocks after target that are still fillable.
     */
    function _processDirective(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        bytes32 claimant,
        uint256[] memory claimAmounts,
        uint256 targetBlock,
        uint256 maximumBlocksAfterTarget
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
     * @param maximumBlocksAfterTarget Blocks after target that are still fillable.
     */
    function _quoteDirective(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes calldata sponsorSignature,
        bytes calldata allocatorSignature,
        bytes32 mandateHash,
        bytes32 claimant,
        uint256[] memory claimAmounts,
        uint256 targetBlock,
        uint256 maximumBlocksAfterTarget
    ) internal view virtual returns (uint256 dispensation) {
        chainId;
        compact;
        sponsorSignature;
        allocatorSignature;
        mandateHash;
        claimant;
        claimAmounts;
        targetBlock;
        maximumBlocksAfterTarget;

        // NOTE: Override & implement quote logic.
        return msg.sender.balance / 1000;
    }

    function _createAllocatorData(
        uint256 targetBlock,
        uint256 maximumBlocksAfterTarget,
        bytes calldata allocatorSignature
    ) internal pure virtual returns (bytes memory) {
        return abi.encode(targetBlock, maximumBlocksAfterTarget, allocatorSignature);
    }
}
