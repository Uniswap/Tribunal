// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

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

struct Mandate_BatchCompact {
    address arbiter;
    address sponsor;
    uint256 nonce;
    uint256 expires;
    Mandate_Lock[] commitments;
    bytes32 mandateHash; // NOTE: this is `Mandate mandate` in the actual EIP-712 typestring; here it is instead provided as an argument on fills
}

struct Mandate_Lock {
    bytes12 lockTag; // A tag representing the allocator, reset period, and scope.
    address token; // The locked token, or address(0) for native tokens.
    uint256 amount; // The maximum committed amount of tokens.
}

// Full mandate originally signed by swapper on source chain.
struct Mandate {
    address adjuster;
    Mandate_Fill[] fills; // Arbitrary-length array
}

struct Mandate_Fill {
    uint256 chainId; // same-chain if value matches chainId()
    address tribunal; //
    uint256 expires;
    // Source chain action expiration timestamp.
    address fillToken; // Intermediate fill token (address(0) for native, same address for no action).
    uint256 minimumFillAmount; // Minimum fill amount.
    uint256 baselinePriorityFee; // Base fee threshold where scaling kicks in.
    uint256 scalingFactor; // Fee scaling multiplier (1e18 baseline).
    uint256[] priceCurve; // Block durations and uint240 additional scaling factors per each duration.
    address recipient; // Recipient of the tokens — address(0) or tribunal indicate that funds will be pulled by the directive.
    Mandate_RecipientCallback[] recipientCallback; // Array of length 0 or 1
}

// If a callback is specified, tribunal will follow up with a call to the recipient with fill details (including realized fill amount), a new compact and hash of an accompanying mandate, a target chainId, and context
struct Mandate_RecipientCallback {
    uint256 chainId;
    Mandate_BatchCompact compact;
    bytes context;
}

// Arguments signed for by adjuster.
struct Adjustment {
    uint256 fillStageIndex;
    uint256 targetBlock;
    uint256[] supplementalPriceCurve; // Additional scaling factor specified duration on price curve.
    bytes32 validityConditions; // Optional value consisting of a number of blocks past the target and a exclusive filler address.
}

// Arguments provided by cross chain filler.
// struct CrossChainFill {
//   Compact compact;
//   Mandate_CrossChainFill mandate;
//   address adjuster;
//   Adjustment adjustment;
//   bytes adjustmentAuthorization;
//   bytes32 sourceChainActionHash;
//   address claimant;
// }

struct Mandate_AdditionalCompact {
    uint256 chainId; // chain ID on the target chain.
    BatchCompact compact;
}

// Arguments signed by swapper for source chain action.
struct Mandate_SingleChainFill {
    Mandate_Auction auction;
    Mandate_AdditionalCompact[] targetChainCompacts;
    bytes32 salt; // Replay protection parameter.
}

// Arguments provided by source chain filler.
// struct SourceChainAction {
//   Compact compact;
//   Mandate_SourceChainAction mandate;
//   address adjuster;
//   Adjustment adjustment;
//   bytes adjustmentAuthorization;
//   bytes32 crossChainFillHash;
//   address claimant;
// }

// Arguments used to build the target chain compact.
struct TargetChainCompact {
    // address arbiter; // Tribunal on the target chain.
    address sponsor; // The account to register the tokens to.
    uint256 nonce; // can be set automatically by the allocator by passing a value of 0.
    uint256 expires; // The time at which the target chain claim expires.
    uint256 id; // The token ID of the ERC6909 token; must match the bridged token.
    // uint256 amount set automatically by tribunal based on post-bridge balance.
    TargetChainMandate targetChainMandate; // mandate for target chain.
}

// Mandate originally signed by swapper for target chain compact. Note that this struct will actually be named "Mandate" in the registered compact.
struct TargetChainMandate {
    address adjuster;
    Mandate_TargetChainAction targetChainAction;
}

// Arguments signed by swapper for target chain action.
struct Mandate_TargetChainAction {
    address recipient; // Recipient of filled tokens.
    address fillToken; // Fill token (address(0) for native).
    uint256 minimumFillAmount; // Minimum fill amount.
    uint256 baselinePriorityFee; // Base fee threshold where scaling kicks in.
    uint256 scalingFactor; // Fee scaling multiplier (1e18 baseline).
    uint256[] priceCurve; // Block durations and uint240 additional scaling factors per each duration.
    bytes32 salt; // Replay protection parameter.
}

// Arguments provided by target chain filler.
// struct TargetChainAction {
//   Compact compact; // based on TargetChainCompact data.
//   Mandate_TargetChainAction mandate;
//   address adjuster;
//   Adjustment adjustment;
//   bytes adjustmentAuthorization;
//   address claimant;
// }
