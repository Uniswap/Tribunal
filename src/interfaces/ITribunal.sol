// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {Fill, Adjustment, Mandate, RecipientCallback} from "../types/TribunalStructs.sol";

/**
 * @title ITribunal
 * @custom:security-contact security@uniswap.org
 * @notice Interface for the Tribunal contract that handles cross-chain swap settlements.
 * @dev Provides methods for filling, cancelling, and querying cross-chain orders with dynamic pricing.
 */
interface ITribunal {
    // ======== Events ========
    /**
     * @notice Emitted when a cross-chain fill is successfully executed.
     * @param chainId The chain ID where the claim will be processed.
     * @param sponsor The address that created the compact to be claimed.
     * @param claimant The address that will receive tokens on the claim chain.
     * @param claimHash The hash of the compact being claimed.
     * @param fillAmount The amount of tokens filled on the destination chain.
     * @param claimAmounts The amounts of tokens to be claimed on the source chain.
     * @param targetBlock The target block number for the fill.
     */
    event CrossChainFill(
        uint256 indexed chainId,
        address indexed sponsor,
        address indexed claimant,
        bytes32 claimHash,
        uint256 fillAmount,
        uint256[] claimAmounts,
        uint256 targetBlock
    );

    /**
     * @notice Emitted when a single-chain fill is successfully executed.
     * @param sponsor The address that created the compact to be claimed.
     * @param claimant The address that receives the tokens and optionally a callback.
     * @param claimHash The hash of the compact being claimed.
     * @param fillAmount The amount of tokens filled.
     * @param claimAmounts The amounts of tokens claimed.
     * @param targetBlock The target block number for the fill.
     */
    event SingleChainFill(
        address indexed sponsor,
        address indexed claimant,
        bytes32 claimHash,
        uint256 fillAmount,
        uint256[] claimAmounts,
        uint256 targetBlock
    );

    /**
     * @notice Emitted when a compact is cancelled by its sponsor.
     * @param sponsor The address that cancelled the compact.
     * @param claimHash The hash of the cancelled compact.
     */
    event Cancel(address indexed sponsor, bytes32 claimHash);

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
    error InvalidChainId();
    error InvalidCommitmentsArray();

    // ======== Type Declarations ========
    struct BatchClaim {
        uint256 chainId; // Claim processing chain ID
        BatchCompact compact;
        bytes sponsorSignature; // Authorization from the sponsor
        bytes allocatorSignature; // Authorization from the allocator
    }

    struct ArgDetail {
        string tokenPath;
        string argPath;
        string description;
    }

    /**
     * @notice Attempt to perform a fill.
     * @param claim The claim parameters and constraints.
     * @param mandate The fill conditions and amount derivation parameters.
     * @param adjuster The assigned adjuster for the fill.
     * @param adjustment The adjustment provided by the adjuster for the fill.
     * @param adjustmentAuthorization The authorization for the adjustment provided by the adjuster.
     * @param fillHashes An array of the hashes of each fill.
     * @param claimant The recipient of claimed tokens on the claim chain.
     * @param fillBlock The block number to target for the fill (0 allows any block).
     * @return claimHash The derived claim hash.
     * @return mandateHash The derived mandate hash.
     * @return fillAmount The amount of tokens to be filled.
     * @return claimAmounts The amount of tokens to be claimed.
     */
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
        returns (
            bytes32 claimHash,
            bytes32 mandateHash,
            uint256 fillAmount,
            uint256[] memory claimAmounts
        );

    /**
     * @notice Settle or register a claim made against a compact on another chain.
     * @dev If filled, forwards the settle tokens to the filler
     * @dev If not filled, it can open a follow up order or forward the tokens directly to the recipient.
     * @param sourceClaimHash The claim hash of the source compact.
     * @param compact The parameters to register a follow-up compact.
     * @param mandateHash The mandate hash of the follow-up compact.
     * @param recipient The recipient of the directly forwarded tokens.
     * @param context The context forwarded to the allocator in an onchain allocation.
     * @return registeredClaimHash The hash of the newly-registered compact.
     */
    function settleOrRegister(
        bytes32 sourceClaimHash,
        BatchCompact calldata compact,
        bytes32 mandateHash,
        address recipient,
        bytes calldata context
    ) external payable returns (bytes32 registeredClaimHash);

    /**
     * @notice Cancel a claim. Will mark the order as filled.
     * @dev Must be called by the sponsor directly.
     * @dev Will process the directive, effectively canceling the order on the source chain to free up allocated tokens.
     * @param claim The claim parameters and constraints.
     * @param mandateHash The mandate hash of the claim to cancel.
     * @return claimHash The hash of the cancelled claim.
     */
    function cancel(BatchClaim calldata claim, bytes32 mandateHash)
        external
        payable
        returns (bytes32 claimHash);

    /**
     * @notice Cancel a claim. Will mark the order as filled.
     * @dev Will not process the directive, effectively leaving the order open on the source chain.
     * @dev Must be called by the sponsor directly.
     * @param compact The compact parameters to open a follow up order.
     * @param mandateHash The mandate hash of the follow up order.
     * @return claimHash The hash of the cancelled claim.
     */
    function cancelChainExclusive(BatchCompact calldata compact, bytes32 mandateHash)
        external
        returns (bytes32 claimHash);

    /**
     * @notice Get a quote for any native tokens supplied to pay for dispensation (i.e. cost to trigger settlement).
     * @param claim The claim parameters and constraints.
     * @param mandate The fill conditions and amount derivation parameters.
     * @param adjuster The assigned adjuster for the fill.
     * @param adjustment The adjustment provided by the adjuster for the fill.
     * @param fillHashes An array of the hashes of each fill.
     * @param claimant The recipient of claimed tokens on the claim chain.
     * @param fillBlock The block number to target for the fill (0 allows any block).
     * @return dispensation The amount quoted to perform the dispensation.
     */
    function quote(
        BatchClaim calldata claim,
        Fill calldata mandate,
        address adjuster,
        Adjustment calldata adjustment,
        bytes32[] calldata fillHashes,
        bytes32 claimant,
        uint256 fillBlock
    ) external view returns (uint256 dispensation);

    /**
     * @notice Get details about the expected compact witness.
     * @return witnessTypeString The EIP-712 type string for the mandate.
     * @return details An array of argument details for tokens and amounts.
     */
    function getCompactWitnessDetails()
        external
        pure
        returns (string memory witnessTypeString, ArgDetail[] memory details);

    /**
     * @notice Check if a claim has been filled.
     * @param claimHash The hash of the claim to check.
     * @return The claimant account provided by the filler if the claim has been filled, or the sponsor if it is cancelled.
     */
    function filled(bytes32 claimHash) external view returns (address);

    /**
     * @notice Derives the mandate hash using EIP-712 typed data.
     * @param mandate The mandate containing all hash parameters.
     * @return The derived mandate hash.
     */
    function deriveMandateHash(Mandate calldata mandate) external view returns (bytes32);

    /**
     * @notice Derives hash of an array of fills using EIP-712 typed data.
     * @param fills The array of fills containing all hash parameters.
     * @return The derived fills array hash.
     */
    function deriveFillsHash(Fill[] calldata fills) external view returns (bytes32);

    /**
     * @notice Derives a fill hash using EIP-712 typed data.
     * @param targetFill The fill containing all hash parameters.
     * @return The derived fill hash.
     */
    function deriveFillHash(Fill calldata targetFill) external view returns (bytes32);

    /**
     * @notice Derives a recipient callback hash using EIP-712 typed data.
     * @param recipientCallback The recipient callback array containing all hash parameters.
     * @return The derived recipient callback hash.
     */
    function deriveRecipientCallbackHash(RecipientCallback[] calldata recipientCallback)
        external
        pure
        returns (bytes32);

    /**
     * @notice Derives the claim hash from compact and mandate hash.
     * @param compact The compact parameters.
     * @param mandateHash The derived mandate hash.
     * @return The claim hash.
     */
    function deriveClaimHash(BatchCompact calldata compact, bytes32 mandateHash)
        external
        pure
        returns (bytes32);

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
    ) external view returns (uint256 fillAmount, uint256[] memory claimAmounts);

    /**
     * @notice Returns the name of this contract.
     * @return The contract name.
     */
    function name() external pure returns (string memory);
}
