// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";

// Overview of the sequence of steps:
//  1) sponsor deposits and registers a compact on the source chain assigning an adjuster, a cross-chain fill, and a source-chain fallback action that will trigger a deposit and registration of a target-chain compact. Allocator ensures that deposited tokens are allocated.
//  2) adjuster cosigns an adjustment for the cross-chain fill (if they do not cosign, sponsor signs a new compact or withdraws)
//  3) cross-chain fill is revealed and active (source chain and target chain actions remain hidden)
//    3a) filler provides tokens on target chain, then claims tokens on source chain
//    3b) sponsor cancels early by submitting a transaction on the target chain before the fill occurs
//    3c) no filler takes the cross-chain order in time, proceed to step 4
//  4) adjuster cosigns an adjustment for the source chain fill (if they do not cosign, sponsor signs a new compact or withdraws)
//  5) source chain fill is revealed and active (target chain action remains hidden, though input token and expiration are revealed)
//    5a) filler takes input tokens and provides intermediate output tokens on source chain, then triggers bridge to tribunal on target chain that in turn triggers desposit + register (+ allocate if needed) on target chain (mandate remains hidden), proceed to step 6
//    5b) sponsor cancels early by submitting a transaction on the target chain — note that step 5a still may occur
//    5c) no filler takes the source chain order in time, sponsor signs a new compact or withdraws tokens
//  6) bridge lands and bridged tokens are deposited into the compact on target chain with accompanying compact registration — note that if a filler completed step 3a then tokens are sent to them instead, and if sponsor completed step 3b then tokens are sent to them directly
//   7a) sponsor claims deposited tokens directly, cancelling early
//   7b) adjuster cosigns an adjustment for the target chain fill (if they do not cosign, sponsor signs a new compact or withdraws)
//   Note: important to handle the case where the bridge transaction is not completed and funds need to be withdrawn from the bridge contract on the source chain and returned to the sponsor
//  8) target chain fill is revealed and active
//   8a) filler claims deposited tokens in exchange for providing output tokens to recipient
//   8b) sponsor claims deposited tokens directly, cancelling
//   8b) no filler takes the target chain order in time, proceed to step 9
//  9) tokens are deallocated and available in The Compact on target chain
//   9a) sponsor signs a new compact to perform a modified target chain swap
//   9b) sponsor signs a new compact to perform a cross-chain swap back to the original source chain (basically return to step 1 with target and source swapped) — note that this could also be part of the originally registered target chain compact and performed automatically
//   9c) sponsor manually withdraws tokens on target chain

// Parent mandate signed by the sponsor on source chain. Note that the EIP-712 payload differs slightly from the structs declared here (mainly around utilizing full mandates rather than mandate hashes).
struct Mandate {
    address adjuster;
    Mandate_Fill[] fills; // Arbitrary-length array
}

struct Mandate_Fill {
    uint256 chainId; // Same-chain if value matches chainId(), otherwise cross-chain
    address tribunal; // Contract where the fill is performed.
    uint256 expires; // Fill expiration timestamp.
    address fillToken; // Intermediate fill token (address(0) for native, same address for no action).
    uint256 minimumFillAmount; // Minimum fill amount.
    uint256 baselinePriorityFee; // Base fee threshold where scaling kicks in.
    uint256 scalingFactor; // Fee scaling multiplier (1e18 baseline).
    uint256[] priceCurve; // Block durations and uint240 additional scaling factors per each duration.
    address recipient; // Recipient of the tokens — address(0) or tribunal indicate that funds will be pulled by the directive.
    Mandate_RecipientCallback[] recipientCallback; // Array of length 0 or 1
    bytes32 salt;
}

// If a callback is specified, tribunal will follow up with a call to the recipient with fill details (including realized fill amount), a new compact and hash of an accompanying mandate, a target chainId, and context
// Note that this does not directly map to the EIP-712 payload (which contains a Mandate_BatchCompact containing the full Mandate mandate rather than BatchCompact + mandateHash)
struct Mandate_RecipientCallback {
    uint256 chainId;
    BatchCompact compact;
    bytes32 mandateHash;
    bytes context;
}

// Arguments signed for by adjuster.
struct Adjustment {
    // bytes32 claimHash included in EIP-712 payload but not provided as an argument.
    uint256 fillStageIndex;
    uint256 targetBlock;
    uint256[] supplementalPriceCurve; // Additional scaling factor specified duration on price curve.
    bytes32 validityConditions; // Optional value consisting of a number of blocks past the target and a exclusive filler address.
}
