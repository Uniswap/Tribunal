// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ValidityLib} from "the-compact/src/lib/ValidityLib.sol";
import {FixedPointMathLib} from "the-compact/lib/solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "the-compact/lib/solady/src/utils/SafeTransferLib.sol";

/**
 * @title Tribunal
 * @author 0age
 * @notice Tribunal is a framework for processing cross-chain swap settlements against PGA (priority gas auction)
 * blockchains. It ensures that tokens are transferred according to the mandate specified by the originating sponsor
 * and enforces that a single party is able to perform the settlement in the event of a dispute.
 * @dev This contract is under active development; contributions, reviews, and feedback are greatly appreciated.
 */
contract Tribunal {
    // ======== Libraries ========
    using ValidityLib for uint256;
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;

    // ======== Custom Errors ========
    error InvalidGasPrice();
    error AlreadyClaimed();

    // ======== Type Declarations ========

    struct Compact {
        address arbiter; // The account tasked with verifying and submitting the claim.
        address sponsor; // The account to source the tokens from.
        uint256 nonce; // A parameter to enforce replay protection, scoped to allocator.
        uint256 expires; // The time at which the claim expires.
        uint256 id; // The token ID of the ERC6909 token to allocate.
        uint256 amount; // The amount of ERC6909 tokens to allocate.
            // Optional witness may follow.
    }

    struct Claim {
        uint256 chainId; // Claim processing chain ID
        Compact compact;
        bytes sponsorSignature; // Authorization from the sponsor
        bytes allocatorSignature; // Authorization from the allocator
    }

    struct Mandate {
        address recipient; // Recipient of settled tokens
        uint256 expires; // Mandate expiration timestamp
        address token; // Settlement token (address(0) for native)
        uint256 minimumAmount; // Minimum settlement amount
        uint256 baselinePriorityFee; // Base fee threshold where scaling kicks in
        uint256 scalingFactor; // Fee scaling multiplier (1e18 baseline)
        bytes32 salt; // Replay protection parameter
    }

    struct Directive {
        address claimant; // Recipient of claimed tokens
        uint256 dispensation; // Cross-chain message layer payment
    }

    // ======== Constants ========

    /// @notice Base scaling factor (1e18)
    uint256 public constant BASE_SCALING_FACTOR = 1e18;

    /// @notice keccak256("Mandate(uint256 chainId,address tribunal,address recipient,uint256 expires,address token,uint256 minimumAmount,uint256 baselinePriorityFee,uint256 scalingFactor,bytes32 salt)")
    bytes32 internal constant MANDATE_TYPEHASH =
        0x52c75464356e20084ae43acac75087fbf0e0c678e7ffa326f369f37e88696036;

    /// @notice keccak256("Compact(address arbiter,address sponsor,uint256 nonce,uint256 expires,uint256 id,uint256 amount,Mandate mandate)Mandate(uint256 chainId,address tribunal,address recipient,uint256 expires,address token,uint256 minimumAmount,uint256 baselinePriorityFee,uint256 scalingFactor,bytes32 salt)")
    bytes32 internal constant COMPACT_TYPEHASH_WITH_MANDATE =
        0x27f09e0bb8ce2ae63380578af7af85055d3ada248c502e2378b85bc3d05ee0b0;

    // ======== Storage ========

    /// @notice Mapping of claim hash to whether it has been used
    mapping(bytes32 => bool) private _dispositions;

    // ======== Constructor ========

    constructor() {}

    // ======== External Functions ========

    /// @notice Returns the name of the contract
    function name() external pure returns (string memory) {
        return "Tribunal";
    }

    /**
     * @notice Submit a petition to process a cross-chain settlement
     * @param claim The claim parameters and constraints
     * @param mandate The settlement conditions and amount derivation parameters
     * @param directive The execution details
     * @return mandateHash The derived mandate hash
     * @return settlementAmount The amount of tokens to be settled
     * @return claimAmount The amount of tokens to be claimed
     */
    function petition(Claim calldata claim, Mandate calldata mandate, Directive calldata directive)
        external
        payable
        returns (bytes32 mandateHash, uint256 settlementAmount, uint256 claimAmount)
    {
        // Ensure that the mandate has not expired.
        mandate.expires.later();

        // Derive mandate hash.
        mandateHash = deriveMandateHash(mandate);

        // Derive and check claim hash
        bytes32 claimHash = deriveClaimHash(claim, mandateHash);
        if (_dispositions[claimHash]) {
            revert AlreadyClaimed();
        }
        _dispositions[claimHash] = true;

        // Derive settlement and claim amounts.
        (settlementAmount, claimAmount) = deriveAmounts(
            claim.compact.amount,
            mandate.minimumAmount,
            mandate.baselinePriorityFee,
            mandate.scalingFactor
        );

        // Handle native token withdrawals directly.
        if (mandate.token == address(0)) {
            mandate.recipient.safeTransferETH(settlementAmount);
            // Return any remaining ETH to the caller
            uint256 remaining = address(this).balance;
            if (remaining > 0) {
                msg.sender.safeTransferETH(remaining);
            }
        } else {
            // NOTE: settling fee-on-transfer tokens will result in fewer tokens
            // being received by the recipient. Be sure to acommodate for this when
            // providing the desired settlement amount.
            mandate.token.safeTransferFrom(msg.sender, mandate.recipient, settlementAmount);
        }

        // Process the directive
        _processDirective(claim, mandateHash, directive, claimAmount);
    }

    /**
     * @notice Get a quote for the required dispensation amount
     * @param claim The claim parameters and constraints
     * @param mandate The settlement conditions and amount derivation parameters
     * @param claimant The address of the claimant
     * @return dispensation The suggested dispensation amount
     */
    function quote(Claim calldata claim, Mandate calldata mandate, address claimant)
        external
        view
        returns (uint256 dispensation)
    {
        // Ensure that the mandate has not expired.
        mandate.expires.later();

        // Derive mandate hash.
        bytes32 mandateHash = deriveMandateHash(mandate);

        // Derive and check claim hash
        bytes32 claimHash = deriveClaimHash(claim, mandateHash);
        if (_dispositions[claimHash]) {
            revert AlreadyClaimed();
        }

        // Derive settlement and claim amounts.
        (, uint256 claimAmount) = deriveAmounts(
            claim.compact.amount,
            mandate.minimumAmount,
            mandate.baselinePriorityFee,
            mandate.scalingFactor
        );

        // Process the quote.
        dispensation = _quoteDirective(claim, mandateHash, claimant, claimAmount);
    }

    /**
     * @notice Get details about the compact witness
     * @return witnessTypeString The EIP-712 type string for the mandate
     * @return tokenArg The position of the token argument
     * @return amountArg The position of the amount argument
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
     * @notice Check if a claim has been processed
     * @param claimHash The hash of the claim to check
     * @return Whether the claim has been processed
     */
    function disposition(bytes32 claimHash) external view returns (bool) {
        return _dispositions[claimHash];
    }

    /**
     * @dev Derives the mandate hash using EIP-712 typed data
     * @param mandate The mandate containing all hash parameters
     * @return The derived mandate hash
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
                mandate.salt
            )
        );
    }

    /**
     * @dev Derives the claim hash from compact and mandate hash
     * @param claim The claim parameters
     * @param mandateHash The derived mandate hash
     * @return The claim hash
     */
    function deriveClaimHash(Claim calldata claim, bytes32 mandateHash)
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                COMPACT_TYPEHASH_WITH_MANDATE,
                claim.compact.arbiter,
                claim.compact.sponsor,
                claim.compact.nonce,
                claim.compact.expires,
                claim.compact.id,
                claim.compact.amount,
                mandateHash
            )
        );
    }

    /**
     * @dev Derives settlement and claim amounts based on mandate parameters and current conditions
     * @param maximumAmount The maximum amount that can be claimed
     * @param minimumAmount The minimum amount that must be settled
     * @param baselinePriorityFee The baseline priority fee in wei
     * @param scalingFactor The scaling factor to apply per priority fee wei above baseline
     * @return settlementAmount The derived settlement amount
     * @return claimAmount The derived claim amount
     */
    function deriveAmounts(
        uint256 maximumAmount,
        uint256 minimumAmount,
        uint256 baselinePriorityFee,
        uint256 scalingFactor
    ) public view returns (uint256 settlementAmount, uint256 claimAmount) {
        // Get the priority fee above baseline
        uint256 priorityFeeAboveBaseline = _getPriorityFee(baselinePriorityFee);

        // If no fee above baseline, return original amounts
        if (priorityFeeAboveBaseline == 0) {
            return (minimumAmount, maximumAmount);
        }

        // Calculate the scaling multiplier based on priority fee
        uint256 scalingMultiplier;
        if (scalingFactor > 1e18) {
            // For exact-in, increase settlement amount
            scalingMultiplier = 1e18 + ((scalingFactor - 1e18) * priorityFeeAboveBaseline);
            claimAmount = maximumAmount;
            settlementAmount = minimumAmount.mulWadUp(scalingMultiplier);
        } else {
            // For exact-out, decrease claim amount
            scalingMultiplier = 1e18 - ((1e18 - scalingFactor) * priorityFeeAboveBaseline);
            settlementAmount = minimumAmount;
            claimAmount = maximumAmount.mulWad(scalingMultiplier);
        }

        return (settlementAmount, claimAmount);
    }

    /**
     * @dev Calculates the priority fee above the baseline
     * @param baselinePriorityFee The base fee threshold where scaling kicks in
     * @return priorityFee The priority fee above baseline (or 0 if below)
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
     * @dev Process the directive for token claims
     * @param claim The claim parameters
     * @param mandateHash The derived mandate hash
     * @param directive The execution details
     * @param claimAmount The amount to claim
     */
    function _processDirective(
        Claim calldata claim,
        bytes32 mandateHash,
        Directive memory directive,
        uint256 claimAmount
    ) internal virtual {
        // NOTE: Override & implement directive processing
    }

    /**
     * @dev Derive the quote for the dispensation required for
     * the directive for token claims
     * @param claim The claim parameters
     * @param mandateHash The derived mandate hash
     * @param claimant The address of the claimant
     * @param claimAmount The amount to claim
     * @return dispensation The quoted dispensation amount
     */
    function _quoteDirective(
        Claim calldata claim,
        bytes32 mandateHash,
        address claimant,
        uint256 claimAmount
    ) internal view virtual returns (uint256 dispensation) {
        claim;
        mandateHash;
        claimant;
        claimAmount;

        // NOTE: Override & implement quote logic
        return msg.sender.balance / 1000;
    }
}
