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
    DispatchParameters,
    DispositionDetails,
    BatchClaim,
    ArgDetail
} from "../types/TribunalStructs.sol";

/**
 * @title ITribunal
 * @custom:security-contact security@uniswap.org
 * @notice Interface for the Tribunal contract that runs competitive auctions for claims against resource locks.
 * Integrates with The Compact for settling claims after fills occur.
 * @dev Provides methods for filling, cancelling, dispatching, and querying auction results with dynamic pricing
 * based on a combination of priority gas auctions (PGA), time-based price curves, and supplemental adjustments.
 */
interface ITribunal {
    // ======== Events ========
    /**
     * @notice Emitted when a standard fill is successfully executed.
     * @dev This event is emitted for all fills using the fill() or fillAndDispatch() functions.
     * @param sponsor The address that created the compact to be claimed.
     * @param claimant The bytes32 value representing the claimant (lock tag ++ address).
     * @param claimHash The hash of the compact being claimed.
     * @param fillRecipients Array of fill amounts and their corresponding recipients.
     * @param claimAmounts The amounts of tokens to be claimed on the claim chain.
     * @param targetBlock The auction start block number as provided on the adjustment.
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
     * @notice Emitted when an atomic same-chain claim and fill is successfully executed.
     * @dev This event is emitted only for claimAndFill() operations where the claim and fill occur on the same chain atomically.
     * @param sponsor The address that created the claimed compact.
     * @param claimant The bytes32 value representing the claimant (lock tag ++ address).
     * @param claimHash The hash of the claimed compact.
     * @param fillRecipients Array of fill amounts and their corresponding recipients.
     * @param claimAmounts The amounts of tokens claimed.
     * @param targetBlock The auction start block number as provided on the adjustment.
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
     * @notice Emitted when a dispatch callback is executed to relay fill results.
     * @dev This event is emitted when using fillAndDispatch(), dispatch(), or cancelAndDispatch() functions.
     * @param dispatchTarget The address that received the dispatch callback.
     * @param chainId The target chain ID for the dispatch message.
     * @param claimant The bytes32 value representing the claimant (or sponsor if cancelled).
     * @param claimHash The hash of the compact that was filled or cancelled.
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

    /**
     * @notice Executes a standard fill.
     * @dev Fillers must provide all required output tokens and have granted token approvals to Tribunal.
     * Native tokens (ETH) must be included as msg.value. This is the core execution method for most fills.
     * Works for cross-chain fills where claim and fill occur on different chains, and for same-chain fills
     * when asynchronous operation is acceptable.
     * @param compact The compact parameters and constraints.
     * @param mandate The fill conditions and amount derivation parameters.
     * @param adjustment The adjustment provided by the adjuster for the fill (includes adjuster and authorization).
     * @param fillHashes An array of the hashes of each fill in the mandate.
     * @param claimant The recipient of claimed tokens on the claim chain (lock tag ++ address).
     * @param fillBlock The block number to target for the fill (0 uses current block, otherwise must match current block).
     * @return claimHash The derived claim hash.
     * @return mandateHash The derived mandate hash.
     * @return fillAmounts The amounts of tokens to be filled for each component.
     * @return claimAmounts The amounts of each token to be claimed.
     */
    function fill(
        BatchCompact calldata compact,
        FillParameters calldata mandate,
        Adjustment calldata adjustment,
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
     * @notice Executes a standard fill and immediately triggers a filler-specified dispatch callback.
     * @dev This function combines fill execution with immediate cross-chain message relay. The filler chooses
     * the dispatch target and parameters, which are not signed by the sponsor. Ideal for relaying fill results
     * to cross-chain messaging systems via outbox or adapter contracts. Not needed for read-based cross-chain
     * systems that can query events or state directly from the source chain.
     * @param compact The compact parameters and constraints.
     * @param mandate The fill conditions and amount derivation parameters.
     * @param adjustment The adjustment provided by the adjuster for the fill (includes adjuster and authorization).
     * @param fillHashes An array of the hashes of each fill in the mandate.
     * @param claimant The recipient of claimed tokens on the claim chain (lock tag ++ address).
     * @param fillBlock The block number to target for the fill (0 uses current block, must match current block).
     * @param dispatch The dispatch callback parameters (target, chainId, value, context).
     * @return claimHash The derived claim hash.
     * @return mandateHash The derived mandate hash.
     * @return fillAmounts The amounts of tokens to be filled for each component.
     * @return claimAmounts The amounts of each token to be claimed.
     */
    function fillAndDispatch(
        BatchCompact calldata compact,
        FillParameters calldata mandate,
        Adjustment calldata adjustment,
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
     * @notice Executes an atomic same-chain fill where the claim and fill occur in a single transaction.
     * @dev Only works when the claim chain equals the fill chain. Operates atomically, optimistically releasing
     * input tokens to the filler first via a callback, then verifying they provided the output. The filler receives
     * the input tokens during the callback and can use them to generate the required output (flash loan-style).
     * Ideal for same-chain token swaps with atomic execution guarantees, capturing arbitrage opportunities, or
     * any scenarios requiring transaction-level atomicity. Note that the `tribunalCallback` function must be
     * implemented by the caller, and that all indicated fill tokens must be provided to Tribunal by the time the
     * callback completes.
     * @param claim The batch claim containing compact parameters, sponsor signature, and allocator signature.
     * @param mandate The fill conditions and amount derivation parameters.
     * @param adjustment The adjustment provided by the adjuster for the fill (includes adjuster and authorization).
     * @param fillHashes An array of the hashes of each fill in the mandate.
     * @param claimant The recipient of claimed tokens on the claim chain (lock tag ++ address).
     * @param fillBlock The block number to target for the fill (0 uses current block, must match current block).
     * @return claimHash The derived claim hash.
     * @return mandateHash The derived mandate hash.
     * @return fillAmounts The amounts of tokens to be filled for each component.
     * @return claimAmounts The amounts of tokens to be claimed.
     */
    function claimAndFill(
        BatchClaim calldata claim,
        FillParameters calldata mandate,
        Adjustment calldata adjustment,
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
     * @notice Relays fill results after the fact by triggering a dispatch callback for a previously completed fill.
     * @dev This function queries the stored claimant and scaling factor, reconstructs claim amounts, and triggers
     * the dispatch callback. Used for batch relaying of multiple fills, retrying failed cross-chain message dispatch,
     * or delayed dispatch for systems with specific timing requirements. Only works on previously completed fills
     * where a claimant has already been recorded. Not needed for read-based systems that can query state directly.
     * @param compact The compact parameters from the original fill.
     * @param mandateHash The mandate hash from the original fill.
     * @param dispatch The dispatch callback parameters (target, chainId, value, context).
     * @return claimHash The claim hash derived from the compact and mandate.
     * @return claimAmounts The amounts of tokens claimed.
     */
    function dispatch(
        BatchCompact calldata compact,
        bytes32 mandateHash,
        DispatchParameters calldata dispatch
    ) external payable returns (bytes32 claimHash, uint256[] memory claimAmounts);

    /**
     * @notice Handles token receipt on destination chains after bridging, with race condition protection.
     * @dev This function is typically triggered by a recipient callback from a same-chain fill on the source chain.
     * It implements multi-modal behavior based on parameters and state:
     * 1. If source claim filled: forwards tokens to the filler who won the target chain auction
     * 2. If empty lock tag: performs direct transfer to recipient
     * 3. If zero mandate hash: deposits to The Compact without registration
     * 4. If nonce is zero: triggers on-chain allocation flow
     * 5. Otherwise: performs standard compact deposit and registration for follow-up auction
     * Race condition protection ensures that if a direct cross-chain fill and a same-chain fill + bridge both
     * execute, the filler who provided output tokens still receives their input tokens.
     * @param sourceClaimHash The claim hash of the source compact on the target chain.
     * @param compact The parameters to register a follow-up compact.
     * @param mandateHash The mandate hash of the follow-up compact (bytes32(0) for no registration).
     * @param recipient The recipient of directly forwarded tokens (defaults to sponsor if address(0)).
     * @param context The context forwarded to the allocator in an on-chain allocation.
     * @return registeredClaimHash The hash of the newly-registered compact (bytes32(0) if no registration).
     */
    function settleOrRegister(
        bytes32 sourceClaimHash,
        BatchCompact calldata compact,
        bytes32 mandateHash,
        address recipient,
        bytes calldata context
    ) external payable returns (bytes32 registeredClaimHash);

    /**
     * @notice Cancels an unfilled auction on the target chain (fill chain).
     * @dev Must be called by the sponsor. CANNOT cancel on the origin chain (claim chain) as a filler may have
     * already executed the fill on the target chain and is waiting for proof to claim their input tokens. CAN cancel
     * on the target chain before a fill occurs, preventing other fillers from executing the auction (analogous to a
     * self-fill where no tokens need to be supplied). Stores type(uint256).max as a cancellation flag.
     * @param compact The compact parameters.
     * @param mandateHash The mandate hash of the claim to cancel.
     * @return claimHash The hash of the cancelled claim.
     */
    function cancel(BatchCompact calldata compact, bytes32 mandateHash)
        external
        returns (bytes32 claimHash);

    /**
     * @notice Cancels an unfilled auction and triggers a dispatch callback to notify cross-chain systems.
     * @dev Must be called by the sponsor. Performs the same cancellation as cancel(), but additionally dispatches
     * a message with zero claim amounts and the sponsor designated as the claimant. This enables notifying cross-chain
     * systems of the cancellation, allowing The Compact to consume the nonce so allocators can securely deallocate
     * committed resource locks on those chains.
     * @param compact The compact parameters and constraints.
     * @param mandateHash The mandate hash of the claim to cancel.
     * @param dispatch The dispatch callback parameters (target, chainId, value, context).
     * @return claimHash The hash of the cancelled claim.
     */
    function cancelAndDispatch(
        BatchCompact calldata compact,
        bytes32 mandateHash,
        DispatchParameters calldata dispatch
    ) external payable returns (bytes32 claimHash);

    /**
     * @notice Returns EIP-712 witness structure details for The Compact integration.
     * @dev The witness (or mandate) typestring is used when registering compacts with The Compact, enabling selective
     * reveal of nested data. This provides the structure for embedding Tribunal-specific witness data within
     * The Compact's EIP-712 structure.
     * @return witnessTypeString The EIP-712 type string for the mandate witness.
     * @return details An array of argument details mapping tokens and amounts for witness validation.
     */
    function getCompactWitnessDetails()
        external
        pure
        returns (string memory witnessTypeString, ArgDetail[] memory details);

    /**
     * @notice Checks the fill status of a claim.
     * @dev Returns the claimant's identifier (lock tag ++ address) if filled, the sponsor's identifier if cancelled,
     * or zero if unfilled.
     * @param claimHash The hash of the claim to check.
     * @return The claimant bytes32 value if filled, sponsor if cancelled, or bytes32(0) if unfilled.
     */
    function filled(bytes32 claimHash) external view returns (bytes32);

    /**
     * @notice Returns the claim reduction scaling factor for a given claim hash.
     * @dev In exact-out mode, this factor indicates how much claim amounts were reduced due to competitive bidding.
     * Returns 1e18 if no reduction occurred, 0 if cancelled, or the actual reduction factor if claims were reduced.
     * @param claimHash The claim hash to query.
     * @return scalingFactor The scaling factor (1e18 if not set, 0 if cancelled, or actual factor if reduced).
     */
    function claimReductionScalingFactor(bytes32 claimHash)
        external
        view
        returns (uint256 scalingFactor);

    /**
     * @notice Queries multiple claims at once, returning both claimant and scaling factor for each.
     * @dev Provides batch querying functionality for multi-claim status checks.
     * @param claimHashes Array of claim hashes to query.
     * @return details Array of disposition details containing the claimant identifier and scaling factor for each claim.
     */
    function getDispositionDetails(bytes32[] calldata claimHashes)
        external
        view
        returns (DispositionDetails[] memory details);

    /**
     * @notice Derives the mandate hash using EIP-712 typed data hashing.
     * @dev The mandate contains the adjuster address and an array of possible fills that enable conditional execution.
     * @param mandate The mandate containing adjuster and fills array.
     * @return The derived mandate hash.
     */
    function deriveMandateHash(Mandate calldata mandate) external view returns (bytes32);

    /**
     * @notice Derives the hash of an array of fills using EIP-712 typed data hashing.
     * @dev Each fill in the array is hashed individually, then the array of hashes is hashed together.
     * @param fills The array of fill parameters.
     * @return The derived fills array hash.
     */
    function deriveFillsHash(FillParameters[] calldata fills) external view returns (bytes32);

    /**
     * @notice Derives a fill hash using EIP-712 typed data hashing.
     * @dev The fill hash includes chain ID, tribunal address, expiration, components, pricing parameters,
     * price curve, recipient callback, and salt for uniqueness.
     * @param targetFill The fill parameters including all pricing and execution conditions.
     * @return The derived fill hash.
     */
    function deriveFillHash(FillParameters calldata targetFill) external view returns (bytes32);

    /**
     * @notice Derives a fill component hash using EIP-712 typed data hashing.
     * @dev Each fill component represents an individual output token with its own token address, amount,
     * recipient, and scaling flag.
     * @param component The fill component with token, amount, recipient, and applyScaling flag.
     * @return The derived fill component hash.
     */
    function deriveFillComponentHash(FillComponent calldata component)
        external
        pure
        returns (bytes32);

    /**
     * @notice Derives a recipient callback hash using EIP-712 typed data hashing.
     * @dev The recipient callback is signed by the sponsor as part of the mandate. The array must be empty
     * or contain exactly one element. Used for bridging fill tokens to destination chains or triggering
     * follow-up compacts.
     * @param recipientCallback The recipient callback array (empty or single element).
     * @return The derived recipient callback hash.
     */
    function deriveRecipientCallbackHash(RecipientCallback[] calldata recipientCallback)
        external
        pure
        returns (bytes32);

    /**
     * @notice Derives the claim hash from compact parameters and mandate hash.
     * @dev The claim hash uniquely identifies a specific auction instance combining The Compact's
     * commitment structure with Tribunal's mandate.
     * @param compact The compact parameters (arbiter, sponsor, nonce, expires, commitments).
     * @param mandateHash The derived mandate hash.
     * @return The derived claim hash.
     */
    function deriveClaimHash(BatchCompact calldata compact, bytes32 mandateHash)
        external
        pure
        returns (bytes32);

    /**
     * @notice Simulates price derivation (fill amounts and claim amounts) for an analogous auction.
     * @dev Derives fill and claim amounts based on mandate parameters and current conditions, incorporating
     * all three pricing mechanisms: priority gas auctions (PGA), time-based price curves, and supplemental curves.
     * In exact-in mode (scalingFactor >= 1e18), fill amounts increase and claim amounts stay at maximum.
     * In exact-out mode (scalingFactor < 1e18), claim amounts decrease and fill amounts stay at minimum.
     * @param maximumClaimAmounts The maximum claim amounts for each commitment (input tokens).
     * @param priceCurve The time-based price curve (array of duration/scaling-factor pairs).
     * @param targetBlock The auction start block number.
     * @param fillBlock The block where the fill is performed.
     * @param minimumFillAmount The minimum fill amount (output tokens).
     * @param baselinePriorityFee The baseline priority fee threshold in wei.
     * @param scalingFactor The PGA scaling factor (1e18 = neutral, >1e18 = exact-in, <1e18 = exact-out).
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
