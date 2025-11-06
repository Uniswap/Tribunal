// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {
    FillParameters,
    FillComponent,
    Adjustment,
    Mandate,
    RecipientCallback,
    FillRecipient,
    DispatchParameters
} from "../types/TribunalStructs.sol";

/**
 * @title ITribunal
 * @custom:security-contact security@uniswap.org
 * @notice Interface for the Tribunal contract that handles cross-chain swap settlements.
 * @dev Provides methods for filling, cancelling, and querying cross-chain orders with dynamic pricing.
 */
interface ITribunal {
    // ======== Events ========
    /**
     * @notice Emitted when a standard fill is successfully executed.
     * @param sponsor The address that created the compact to be claimed.
     * @param claimant The bytes32 value representing the claimant (lock tag ++ address).
     * @param claimHash The hash of the compact being claimed.
     * @param fillRecipients Array of fill amounts and their corresponding recipients.
     * @param claimAmounts The amounts of tokens to be claimed on the source chain.
     * @param targetBlock The target block number for the fill.
     */
    event Fill(
        address indexed sponsor,
        bytes32 indexed claimant,
        bytes32 claimHash,
        FillRecipient[] fillRecipients,
        uint256[] claimAmounts,
        uint256 targetBlock
    );

    /**
     * @notice Emitted when a same-chain claim and fill is successfully executed.
     * @param sponsor The address that created the claimed compact.
     * @param claimant The bytes32 value representing the claimant (lock tag ++ address).
     * @param claimHash The hash of the claimed compact.
     * @param fillRecipients Array of fill amounts and their corresponding recipients.
     * @param claimAmounts The amounts of tokens claimed.
     * @param targetBlock The target block number for the fill.
     */
    event FillWithClaim(
        address indexed sponsor,
        bytes32 indexed claimant,
        bytes32 claimHash,
        FillRecipient[] fillRecipients,
        uint256[] claimAmounts,
        uint256 targetBlock
    );

    /**
     * @notice Emitted when a compact is cancelled by its sponsor.
     * @param sponsor The address that cancelled the compact.
     * @param claimHash The hash of the cancelled compact.
     */
    event Cancel(address indexed sponsor, bytes32 claimHash);

    /**
     * @notice Emitted when a dispatch callback is executed.
     * @param dispatchTarget The address that received the dispatch callback.
     * @param chainId The chain ID the dispatch callback is intended to interact with.
     * @param claimant The bytes32 value representing the claimant.
     * @param claimHash The hash of the compact to be claimed on performing the fill.
     */
    event Dispatch(
        address indexed dispatchTarget,
        uint256 indexed chainId,
        bytes32 indexed claimant,
        bytes32 claimHash
    );

    // ======== Custom Errors ========
    error InvalidGasPrice();
    error AlreadyFilled();
    error InvalidTargetBlockDesignation();
    error InvalidTargetBlock(uint256 blockNumber, uint256 targetBlockNumber);
    error NotSponsor();
    error ReentrancyGuard();
    error InvalidRecipientCallbackLength();
    error ValidityConditionsNotMet();
    error InvalidFillBlock();
    error InvalidAdjustment();
    error InvalidFillHashArguments();
    error InvalidRecipientCallback();
    error InvalidChainId();
    error InvalidCommitmentsArray();
    error InvalidDispatchCallback();
    error DispatchNotAvailable();

    // ======== Type Declarations ========
    struct BatchClaim {
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
     * @notice Attempt to perform a standard fill.
     * @param compact The compact parameters and constraints.
     * @param mandate The fill conditions and amount derivation parameters.
     * @param adjuster The assigned adjuster for the fill.
     * @param adjustment The adjustment provided by the adjuster for the fill.
     * @param adjustmentAuthorization The authorization for the adjustment provided by the adjuster.
     * @param fillHashes An array of the hashes of each fill.
     * @param claimant The recipient of claimed tokens on the claim chain.
     * @param fillBlock The block number to target for the fill (0 allows any block).
     * @return claimHash The derived claim hash.
     * @return mandateHash The derived mandate hash.
     * @return fillAmounts The amounts of tokens to be filled for each component.
     * @return claimAmounts The amount of tokens to be claimed.
     */
    function fill(
        BatchCompact calldata compact,
        FillParameters calldata mandate,
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
            uint256[] memory fillAmounts,
            uint256[] memory claimAmounts
        );

    /**
     * @notice Attempt to perform a standard fill and execute a dispatch callback.
     * @param compact The compact parameters and constraints.
     * @param mandate The fill conditions and amount derivation parameters.
     * @param adjuster The assigned adjuster for the fill.
     * @param adjustment The adjustment provided by the adjuster for the fill.
     * @param adjustmentAuthorization The authorization for the adjustment provided by the adjuster.
     * @param fillHashes An array of the hashes of each fill.
     * @param claimant The recipient of claimed tokens on the claim chain.
     * @param fillBlock The block number to target for the fill (0 allows any block).
     * @param dispatch The dispatch callback parameters (target, value, context).
     * @return claimHash The derived claim hash.
     * @return mandateHash The derived mandate hash.
     * @return fillAmounts The amounts of tokens to be filled for each component.
     * @return claimAmounts The amount of tokens to be claimed.
     */
    function fillAndDispatch(
        BatchCompact calldata compact,
        FillParameters calldata mandate,
        address adjuster,
        Adjustment calldata adjustment,
        bytes calldata adjustmentAuthorization,
        bytes32[] calldata fillHashes,
        bytes32 claimant,
        uint256 fillBlock,
        DispatchParameters calldata dispatch
    )
        external
        payable
        returns (
            bytes32 claimHash,
            bytes32 mandateHash,
            uint256[] memory fillAmounts,
            uint256[] memory claimAmounts
        );

    /**
     * @notice Attempt to perform a same-chain fill and claim tokens in a single action.
     * @dev This function simultaneously claims tokens and performs a fill when both are on a single chain.
     * @param claim The batch claim containing compact parameters, sponsor signature, and allocator signature.
     * @param mandate The fill conditions and amount derivation parameters.
     * @param adjuster The assigned adjuster for the fill.
     * @param adjustment The adjustment provided by the adjuster for the fill.
     * @param adjustmentAuthorization The authorization for the adjustment provided by the adjuster.
     * @param fillHashes An array of the hashes of each fill.
     * @param claimant The recipient of claimed tokens on the claim chain.
     * @param fillBlock The block number to target for the fill (0 allows any block).
     * @return claimHash The derived claim hash.
     * @return mandateHash The derived mandate hash.
     * @return fillAmounts The amounts of tokens to be filled for each component.
     * @return claimAmounts The amount of tokens to be claimed.
     */
    function fillAndClaim(
        BatchClaim calldata claim,
        FillParameters calldata mandate,
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
            uint256[] memory fillAmounts,
            uint256[] memory claimAmounts
        );

    /**
     * @notice Execute a dispatch callback for a previously completed fill.
     * @dev Used for retries or delayed dispatch execution. The compact and mandate hash are used to derive the claim hash,
     * and the stored scaling factor is used to compute claim amounts.
     * @param compact The compact parameters from the original fill.
     * @param mandateHash The mandate hash from the original fill.
     * @param dispatch The dispatch callback parameters (target, value, context).
     * @return claimHash The claim hash derived from the compact and mandate.
     * @return claimAmounts The amount of tokens claimed.
     */
    function dispatch(
        BatchCompact calldata compact,
        bytes32 mandateHash,
        DispatchParameters calldata dispatch
    ) external payable returns (bytes32 claimHash, uint256[] memory claimAmounts);

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
     * @notice Cancel a claim locally without processing on the source chain.
     * @dev Must be called by the sponsor directly.
     * @param compact The compact parameters.
     * @param mandateHash The mandate hash of the claim to cancel.
     * @return claimHash The hash of the cancelled claim.
     */
    function cancel(BatchCompact calldata compact, bytes32 mandateHash)
        external
        returns (bytes32 claimHash);

    /**
     * @notice Cancel a claim and trigger a dispatch callback with all claim amounts reduced to zero.
     * @dev Must be called by the sponsor directly. Processes the directive on the source chain and triggers dispatch.
     * @param compact The compact parameters and constraints.
     * @param mandateHash The mandate hash of the claim to cancel.
     * @param dispatch The dispatch callback parameters.
     * @return claimHash The hash of the cancelled claim.
     */
    function cancelAndDispatch(
        BatchCompact calldata compact,
        bytes32 mandateHash,
        DispatchParameters calldata dispatch
    ) external payable returns (bytes32 claimHash);

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
     * @return The claimant bytes32 value provided by the filler if the claim has been filled, or the sponsor if it is cancelled.
     */
    function filled(bytes32 claimHash) external view returns (bytes32);

    /**
     * @notice Returns the claim reduction scaling factor for a given claim hash.
     * @param claimHash The claim hash to query.
     * @return scalingFactor The scaling factor (returns 1e18 if not set, 0 if cancelled).
     */
    function claimReductionScalingFactor(bytes32 claimHash)
        external
        view
        returns (uint256 scalingFactor);

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
    function deriveFillsHash(FillParameters[] calldata fills) external view returns (bytes32);

    /**
     * @notice Derives a fill hash using EIP-712 typed data.
     * @param targetFill The fill containing all hash parameters.
     * @return The derived fill hash.
     */
    function deriveFillHash(FillParameters calldata targetFill) external view returns (bytes32);

    /**
     * @notice Derives a fill component hash using EIP-712 typed data.
     * @param component The fill component containing all hash parameters.
     * @return The derived fill component hash.
     */
    function deriveFillComponentHash(FillComponent calldata component)
        external
        pure
        returns (bytes32);

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
     * @param maximumClaimAmounts The maximum claim amounts for each commitment.
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
