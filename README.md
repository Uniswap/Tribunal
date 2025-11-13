# Tribunal ☝️

**Tribunal** is a protocol that runs competitive auctions for claims against resource locks. It integrates with **The Compact** for settling claims after fills occur.

## Overview

Tribunal serves three core roles:

1. **Price Derivation**: Calculates prices (either fill amounts or claim amounts) based on parameters provided by the sponsor and their assigned adjuster, the auction start block, the current block, and the transaction's priority fee.

2. **Filler Selection**: Designates a single, specific filler per unique auction and allows them to specify a claimant who is entitled to claim tokens held in the corresponding resource lock.

3. **Result Distribution**: Makes auction results available to be broadcast or relayed to any environment or chain through multiple mechanisms (dispatch callbacks, state queries, or direct on-chain claims).

### What is Tribunal?

Tribunal enables sponsors (token holders) to auction tokens held in resource locks. These auctions start at a specific block and evolve their pricing over time. They accept bids through actual blockchain transactions, where priority fees directly influence the final prices. Each auction can support multiple input and output tokens simultaneously, allowing for complex multi-token swaps. The auctions are designed to support token swaps across distinct blockchains and integrate with various cross-chain messaging systems.

The protocol doesn't dictate how claims are processed across chains—that responsibility falls to the designated arbiter. Tribunal simply determines who won the auction and what amounts should be claimable, then makes that information available through various channels including dispatch callbacks, state queries, and direct on-chain claims.

### Integration with The Compact

Tribunal is deeply integrated with [The Compact](https://github.com/Uniswap/the-compact), a protocol for managing token deposits and claims through resource locks. The input tokens that fillers receive are held in Compact resource locks. All claims against these locks are processed through The Compact's infrastructure. The settlement logic leverages The Compact's allocation and claim mechanisms to ensure secure token transfers. Sponsor signatures follow The Compact's EIP-712 structure, with Tribunal-specific witness data embedded within the compact registration.

## Core Concepts

### Auction Participants

**Sponsor**: The sponsor creates and signs the auction parameters (mandates) and controls the input tokens that will be auctioned.

**Adjuster**: The adjuster is a trusted party assigned by the sponsor who provides signed adjustments for each fill. The adjuster can select which fill from a set of options should be executed, set the auction start block, apply supplemental price curves for dynamic pricing, and optionally restrict fills to specific addresses or time windows.

**Filler**: The filler provides the output tokens to recipients and designates who can claim the input tokens from the resource lock.

**Arbiter**: The arbiter is an external party responsible for ultimately processing claims. The arbiter may accept or reject Tribunal's suggestions concerning claimants and claim amounts (unless Tribunal is itself the arbiter).

**Claimant**: The claimant is the party designated by the filler to receive the input tokens from the resource lock after a successful fill.

### Auction Structure

A complete auction consists of four main components:

1. **Mandate**: The mandate contains the sponsor's signed commitment, including the assigned adjuster address and an array of possible fills that enable conditional execution based on market conditions.

2. **Fill Parameters**: The fill parameters specify conditions for a specific fill. These include the target chain ID and Tribunal contract address, an expiration timestamp, an array of fill components for multi-token outputs, pricing parameters such as the baseline priority fee and scaling factor, a price curve defining time-based pricing adjustments, and an optional recipient callback specification.

3. **Fill Components**: Each fill component represents an individual output token and specifies the token address (with address(0) representing native ETH), the minimum fill amount, the recipient address, and whether to apply competitive scaling to that particular component.

4. **Adjustment**: The adjustment contains the adjuster's signed authorization and provides the selected fill index, the target block where the auction begins, a supplemental price curve for additional price modifications, and validity conditions that can optionally restrict fills to specific addresses or time windows.

## Pricing Mechanisms

Tribunal uses **three independent but composable pricing mechanisms** that work together:

### 1. Priority Gas Auctions (PGA)

Fillers compete by paying higher priority fees, which directly impacts the final auction price. The price adjustment is calculated as follows:

```
priorityFeeAboveBaseline = max(0, tx.gasprice - block.basefee - baselinePriorityFee)
priceAdjustment = priorityFeeAboveBaseline * scalingFactor
```

The **baselinePriorityFee** represents the threshold where competitive scaling begins; any priority fee below this baseline has no effect on pricing. The **scalingFactor** is a multiplier applied per wei of priority fee above the baseline, with 1e18 representing a 1:1 ratio (e.g. no scaling based on priority fee).

### 2. Price Curves

Time-based pricing is defined as an array of duration/scaling-factor pairs that determine how prices evolve over time. The **block duration** (16 bits) specifies the time window for each segment of the curve. The **scaling factor** (240 bits) defines the price multiplier that should be applied during that period. The protocol uses **linear interpolation** between discrete points to support price transitions over a period of time, such as traditional reverse dutch auctions. **Zero-duration segments** enable instant price jumps at specific blocks without a gradual transition.

Example curve:
```solidity
[
  encode(100 blocks, 1.5e18),  // 150% for first 100 blocks
  encode(0 blocks, 1.2e18),     // Instant jump to 120%
  encode(200 blocks, 1.1e18),   // Decay to 110% over 200 blocks
  // Defaults to 1e18 (neutral) if auction continues beyond specified duration
]
```

### 3. Supplemental Price Curves

Additional adjustments provided by the adjuster, combined with the base curve:

```
combinedScalingFactor = baseCurveScalingFactor + supplementalScalingFactor - 1e18
```

This allows dynamic pricing based on market conditions while maintaining the sponsor's original curve structure.

### Pricing Direction: Exact-In vs Exact-Out

The protocol automatically determines auction mode based on the `scalingFactor`:

**Exact-In Mode** (`scalingFactor ≥ 1e18`): In this mode, fill amounts increase as fillers compete to provide more output tokens. The claim amounts remain at their maximum values. This mode is suited for auctions seeking to maximize output amount given some fixed input input amount.

**Exact-Out Mode** (`scalingFactor < 1e18`): In this mode, claim amounts decrease as fillers compete to accept fewer input tokens. The fill amounts remain at their minimum values. This mode is suited for auctions where a fixed output amount is preferred.

**Direction Consistency**: All scaling factors (base curve, supplemental curve, PGA component) must scale in the same direction or be neutral (1e18).

## Fill Execution

Tribunal provides several fill execution methods, each designed for specific use cases:

### Standard Fill

The `fill()` function is the core execution method for both same-chain and cross-chain fills:

```solidity
function fill(
    BatchCompact calldata compact,
    FillParameters calldata mandate,
    Adjustment calldata adjustment,
    bytes32[] calldata fillHashes,
    bytes32 claimant,
    uint256 fillBlock
) external payable returns (
    bytes32 claimHash,
    bytes32 mandateHash,
    uint256[] memory fillAmounts,
    uint256[] memory claimAmounts
)
```

**What fillers must provide**: Fillers must provide all required output tokens in the computed amounts. They must also have granted token approvals to Tribunal for ERC20 transfers. If native tokens (ETH) are required, fillers must include them as `msg.value` in the transaction.

**What fillers receive**: Fillers receive a storage slot that records their designated claimant for the claim hash. They also receive an event (`Fill`) that announces the successful fill to all observers. Most importantly, they gain the ability to claim input tokens from the resource lock through their designated claimant.

**How it works**: The function first validates that the mandate hasn't expired and that the chain ID matches the current chain. It then verifies the adjuster's signature on the adjustment to ensure authorization. Next, it validates validity conditions on the adjustment such as exclusive filler restrictions and block window requirements. The protocol then calculates both fill amounts and claim amounts based on all active pricing mechanisms (PGA, price curves, and supplemental curves). It marks the claim as filled, setting the filler's designated claimant in storage mapped to the underlying claim hash. The function then transfers ERC20 tokens from the filler to the specified recipients and forwards any required native tokens (which must be supplied as value when calling the function). If a recipient callback is specified in the mandate, it triggers that callback (see Callback Types section). Finally, it returns relevant details including hashes and amounts.

**Use cases**: This function is most commonly used for cross-chain fills where the claim and fill occur on different chains. It's also suitable for same-chain fills when asynchronous operation is acceptable. More generally, it works for any scenario where the filler provides output tokens upfront and then claims inputs separately through a distinct process.

### Fill with Dispatch

The `fillAndDispatch()` function combines fill execution with immediate cross-chain message relay:

```solidity
function fillAndDispatch(
    BatchCompact calldata compact,
    FillParameters calldata mandate,
    Adjustment calldata adjustment,
    bytes32[] calldata fillHashes,
    bytes32 claimant,
    uint256 fillBlock,
    DispatchParameters calldata dispatchParameters
) external payable returns (
    bytes32 claimHash,
    bytes32 mandateHash,
    uint256[] memory fillAmounts,
    uint256[] memory claimAmounts
)
```

**How it differs from fill()**: This function executes the fill identically to the standard `fill()` function. It then immediately triggers a filler-specified dispatch callback with the fill results. The key distinction is that the filler chooses the dispatch target and parameters, which are not signed by the sponsor and can be parameterized by the filler on execution based on their preferences.

**Use cases**: This function is ideal for relaying fill results to cross-chain messaging systems via outbox or adapter contracts. It's also useful for triggering custom filler callbacks immediately after completing a fill. The function enables combining fill execution with immediate cross-chain proof submission in a single transaction.

**Important notes**: The dispatch target is chosen by the filler, not the sponsor, giving fillers flexibility in how they relay the information. This function is particularly useful for active cross-chain messaging systems that require explicit calls to propagate messages. However, it's not needed for read-based cross-chain systems that can query events or state directly from the source chain.

### Deferred Dispatch

The `dispatch()` function allows relaying fill results after the fact:

```solidity
function dispatch(
    BatchCompact calldata compact,
    bytes32 mandateHash,
    DispatchParameters calldata dispatchParams
) external payable returns (bytes32 claimHash, uint256[] memory claimAmounts)
```

**How it works**: The function queries the stored claimant for the claim hash from Tribunal's state. It retrieves the stored scaling factor that was recorded during the original fill. The function then reconstructs the claim amounts by applying the scaling factor to the compact's commitment amounts. Finally, it triggers the dispatch callback with all fill details including the reconstructed amounts.

**Use cases**: This function is designed to support batch relaying of multiple fill results in a single operation and retrying failed cross-chain message dispatch when the initial dispatch doesn't go through. The function supports delayed dispatch for systems with specific timing requirements that may need to wait before propagating messages. Note that read-based systems may not need dispatch at all since they can query state directly from the source chain.

**Important notes**: This function only works on previously completed fills where a claimant has already been recorded. It's a convenience function that's not strictly required for all cross-chain systems. Systems that can read events or state directly may skip dispatch entirely and use alternative methods to retrieve fill information.

### Atomic Same-Chain Fill

The `claimAndFill()` function enables atomic same-chain operations:

```solidity
function claimAndFill(
    BatchClaim calldata claim,
    FillParameters calldata mandate,
    Adjustment calldata adjustment,
    bytes32[] calldata fillHashes,
    bytes32 claimant,
    uint256 fillBlock
) external payable returns (
    bytes32 claimHash,
    bytes32 mandateHash,
    uint256[] memory fillAmounts,
    uint256[] memory claimAmounts
)
```

**How it differs from fill()**: This function only works when the claim chain equals the fill chain, enabling same-chain atomic operations. It operates atomically in a single transaction, unlike the asynchronous nature of standard fills. The function optimistically releases input tokens to the filler first, before verifying they provided the output. The filler receives a callback while holding the input tokens, giving them an opportunity to use those tokens. The function only verifies that output tokens were provided after the callback completes, allowing the filler to use the input tokens to generate the required output.

**Execution flow**: The function first processes the claim through The Compact, releasing input tokens to the filler immediately. It then triggers a callback to the filler with exact fill requirements, operating in a flash loan-like manner. During this callback, the filler can use the input tokens for swaps, arbitrage, or any other purpose they choose. After the callback returns, Tribunal verifies that the filler has provided it with the required output tokens, at which point the protocol will transfer them to the designated recipients. If the filler fails to provide the output tokens, the entire transaction reverts, ensuring atomicity.

**Use cases**: This function is ideal for same-chain token swaps with atomic execution guarantees. It enables capturing arbitrage opportunities between input and output tokens where the filler can profit from market inefficiencies. The function supports flash loan-style operations where the filler uses the claimed tokens to generate the required output. More generally, it's suited for any scenarios requiring transaction-level atomicity where success or failure of both the claim portion and fill portion of settlement must be determined within a single operation.

**Important notes**: This function gives the filler temporary custody of input tokens before they provide the output, creating a unique trust model. The filler can profit from the spread between the value of input tokens received and the cost of generating the required output tokens. This function is only available when both the claim and fill occur on the same chain, as cross-chain operations cannot provide the same atomicity guarantees.

## Settlement and Registration

The `settleOrRegister()` function handles token receipt on destination chains after bridging:

```solidity
function settleOrRegister(
    bytes32 sourceClaimHash,
    BatchCompact calldata compact,
    bytes32 mandateHash,
    address recipient,
    bytes calldata context
) external payable returns (bytes32 registeredClaimHash)
```

**Purpose**:
This function is called when a bridge transaction lands on the destination chain, typically triggered by a recipient callback from a same-chain fill on the source chain. It safely handles token receipt while protecting against race conditions between direct cross-chain fills and bridged same-chain fills.

**Race condition protection**: When a sponsor signs a mandate with multiple fills (such as one direct cross-chain fill and one same-chain fill with bridge callback), both could potentially execute simultaneously. In this scenario, Filler A might perform a direct cross-chain fill on the target chain while Filler B performs a same-chain fill on the source chain that triggers a bridge to the target chain.

To address this race condition, the function implements a three-step mechanism. First, it checks if the target chain claim has already been filled. If a direct cross-chain fill already occurred, it redirects the bridged tokens to that filler's claimant who has already provided the output tokens. Second, it checks if the target chain claim was cancelled by the sponsor. If so, it redirects the bridged tokens to the sponsor. Otherwise, if neither condition is met, it proceeds to deposit the provided tokens and register an accompanying compact committing the deposited tokens on behalf of the indicated sponsor.

Note that this mechanism is meant to serve as a fail-safe protection, and should not be encountered as long as the adjuster is functioning correctly and only authorizing secondary fills once a primary fill is confirmed to be no longer fillable. Fillers should exercise caution when performing fills with partial information on the contents of the fills array, and be prepared to accept bridged token equivalents if they do not have confidence that the assigned adjuster will adequately protect them against "double-fill" scenarios.

**Multi-modal behavior**: The function operates in one of five distinct modes based on the parameters and state:

1. **If source claim hash is filled**: When the function detects that the source claim hash has already been filled on the destination chain, it forwards the bridged tokens directly to the filler who won the target chain auction. This filler has already provided the output tokens and therefore receives the bridged input tokens as payment.

2. **If empty lock tag**: When the compact contains an empty lock tag (bytes12(0)), the function performs a direct transfer to the specified recipient. This mode bypasses lock registration and compact mechanisms entirely, providing a simple token forwarding path.

3. **If zero mandate hash**: When no mandate hash is provided (bytes32(0)), the function deposits the bridged tokens to The Compact without registering any compact. This leaves the tokens available in The Compact for the sponsor to use in future operations without committing them to a specific auction.

4. **If nonce is zero**: When the compact's nonce is set to zero, the function triggers an on-chain allocation flow. This involves calling the designated allocator's `prepareAllocation()` function before registration and following up with a call to the `executeAllocation()` function after registration, enabling dynamic allocation logic to be applied to the deposited tokens.

5. **Otherwise**: In all other cases, the function performs a standard compact deposit and registration for a follow-up auction on the destination chain. It deposits the bridged tokens and registers them with the provided compact parameters, creating a new auction that can be filled according to the associated mandate.

**Why this protection matters**:
Without this mechanism, a filler who successfully completes a direct cross-chain fill could be denied their input tokens if a same-chain fill + bridge completes first. Using the `settleOrRegister()` function as the call target for the bridge transaction ensures fillers still receive what they're owed, regardless of which flow completes first.

## Cancellation

Sponsors can cancel unfilled auctions, but with important restrictions:

```solidity
function cancel(
    BatchCompact calldata compact,
    bytes32 mandateHash
) external returns (bytes32 claimHash)
```

Or cancel with a dispatch notification:

```solidity
function cancelAndDispatch(
    BatchCompact calldata compact,
    bytes32 mandateHash,
    DispatchParameters calldata dispatchParams
) external payable returns (bytes32 claimHash)
```

**Critical cancellation rules**:

⚠️ **Sponsors CANNOT cancel on the origin chain (claim chain)** because a filler may have already executed the fill on the target chain and is waiting for proof to claim their input tokens. Cancelling on the origin chain would deny payment to a filler who correctly completed the fill.

✅ **Sponsors CAN cancel on the target chain (fill chain)** before a fill occurs. This is roughly analogous to a self-fill where no tokens need to be supplied, and prevents other fillers from executing the auction.

**How cancellation works**:

The `cancel()` function marks the claim as filled by the sponsor, which prevents other fillers from executing the auction on the target chain. The `cancelAndDispatch()` function performs the same cancellation operation, but additionally dispatches a message with zero claim amounts and the sponsor designated as the claimant.

Both functions store `type(uint256).max` as a dedicated "cancellation flag" in storage, which the `claimReductionScalingFactor()` function interprets by returning 0 for cancelled claims. When using `cancelAndDispatch()`, the function triggers the dispatch callback with zero amounts to notify cross-chain systems of the cancellation. 

**Use cases**:

Cancellation is useful when a sponsor wants to reclaim tokens before the auction fills or when market conditions change and the fill is no longer desired. Additionally, the `cancelAndDispatch()` variant enables notifying cross-chain systems of the cancellation via dispatch callbacks; this enables The Compact to consume the nonce so that allocators can securely deallocate committed resource locks on those chains.

## Querying Auction Results

### Check Fill Status

```solidity
function filled(bytes32 claimHash) external view returns (bytes32)
```

This function returns the claimant's identifier (i.e. preferred lock tag and recipient) if the claim has been filled, the sponsor's identifier if the claim has been cancelled, or zero if the claim remains unfilled.

### Get Scaling Factor

```solidity
function claimReductionScalingFactor(bytes32 claimHash) external view returns (uint256)
```

This function returns the actual scaling factor if claim amounts were reduced (a value less than 1e18), 1e18 if no reduction occurred, or 0 if the claim was cancelled.

### Batch Query

```solidity
function getDispositionDetails(bytes32[] calldata claimHashes)
    external view returns (DispositionDetails[] memory)
```

This function queries multiple claims at once, returning both the claimant and scaling factor for each claim in a single call.

## Callback Types

Tribunal uses three distinct callback mechanisms, each serving a different purpose:

### 1. Dispatch Callback (Filler-Specified, Optional)

**Interface**: `IDispatchCallback`

**Who specifies it**: The filler (via `DispatchParameters`)

**When it's called**: After fill completion, when using `fillAndDispatch()` or `dispatch()`

**Purpose**: Relay fill results to cross-chain messaging systems or custom filler logic

```solidity
interface IDispatchCallback {
    function dispatchCallback(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes32 mandateHash,
        bytes32 claimHash,
        bytes32 claimant,
        uint256 claimReductionScalingFactor,
        uint256[] calldata claimAmounts,
        bytes calldata context
    ) external payable returns (bytes4);
}
```

**Key characteristics**:

This callback is not signed by the sponsor; instead, the filler chooses both the target and parameters. The callback is optional, meaning fillers can skip dispatch entirely if it's not needed for their use case. It's particularly useful for active messaging systems such as outboxes, bridges, and adapters. However, it's not needed for read-based systems that can query state directly from the source chain. If the initial dispatch fails, it can be retried later via the `dispatch()` function.

**Use cases**:

This callback is commonly used for submitting fill proofs to cross-chain message bridges, triggering custom filler logic after completing a fill, relaying claim information to destination chains, and batch processing multiple fills in a single operation.

### 2. Recipient Callback (Sponsor-Specified, Required if Specified)

**Interface**: `IRecipientCallback`

**Who specifies it**: The sponsor (in `FillParameters.recipientCallback[]`)

**When it's called**: After all fill tokens are transferred, before function returns

**Purpose**: Bridge tokens to another chain or trigger follow-up compacts

```solidity
interface IRecipientCallback {
    function tribunalCallback(
        uint256 chainId,
        bytes32 sourceClaimHash,
        bytes32 sourceMandateHash,
        address fillToken,
        uint256 fillAmount,
        BatchCompact calldata targetCompact,
        bytes32 targetMandateHash,
        bytes calldata context
    ) external returns (bytes4);
}
```

**Key characteristics**:

This callback is signed by the sponsor as part of the mandate, ensuring it's an authorized part of the auction design. It executes automatically after fill token transfers specified by the executed fill are complete, and is called on the first fill component's recipient address. The callback must succeed for the fill to complete, meaning any failure will revert the entire transaction. This mechanism typically triggers bridging to a destination chain, enabling cross-chain auction workflows even when fillers do not have inventory they are willing to provide upfront on the target chain.

**Use cases**:

The recipient callback can be used for bridging fill tokens to a destination chain, registering follow-up compacts on the destination chain to continue the auction process, chaining multiple auctions together for complex multi-step swaps, and implementing multi-step cross-chain workflows that span multiple chains.

**Typical flow**:

The filler executes a same-chain fill, which triggers the transfer of fill tokens to the recipient (typically a bridge contract). The recipient callback is then triggered with target compact details that specify how to proceed on the destination chain. The bridge initiates a cross-chain transfer of the tokens. Finally, on the destination chain, the `settleOrRegister()` function handles token receipt and continues the process according to the compact parameters.

### 3. Tribunal Callback (Filler Flash Loan, Required)

**Interface**: `ITribunalCallback`

**Who receives it**: The filler (msg.sender) during `claimAndFill()`

**When it's called**: Immediately after input tokens are released to filler, before output tokens are verified

**Purpose**: Allow filler to use claimed tokens to generate required output tokens

```solidity
interface ITribunalCallback {
    function tribunalCallback(
        bytes32 claimHash,
        Lock[] calldata commitments,
        uint256[] calldata claimAmounts,
        FillRequirement[] calldata fillRequirements
    ) external returns (bytes4);
}
```

**Key characteristics**:

This callback is only used in `claimAndFill()` for same-chain atomic fills, where the filler receives input tokens before providing output tokens. The mechanism operates in a flash loan style, where the filler temporarily holds both input and output value during the callback. The filler must provide the required output tokens before the callback returns, or the entire transaction will revert, ensuring atomicity.

**Execution sequence**:

The callback follows a specific execution flow. First, Tribunal processes the claim, releasing input tokens to the filler. Next, Tribunal calls `tribunalCallback()` on the filler (msg.sender), giving them custody of the input tokens. During the callback, the filler can perform swaps, arbitrage, or other operations to generate the required output tokens. After the callback returns, Tribunal verifies that the filler provided the required output tokens. If the output tokens are missing, the transaction reverts.

**Use cases**:

This callback enables same-chain token swaps with atomic execution guarantees, supports using claimed tokens to generate required outputs, and facilitates flash loan-style operations.

## Callback Comparison

| Aspect | Dispatch Callback | Recipient Callback | Tribunal Callback |
|--------|------------------|-------------------|------------------|
| **Who specifies** | Filler | Sponsor | Automatic (filler) |
| **Precommitted by sponsor** | No | Yes | Partially |
| **Optional** | Yes | Yes (0 or 1 in array) | No (if using claimAndFill) |
| **When called** | After fill & any other callbacks | After fill | Before fill |
| **Primary use** | Cross-chain messaging | Bridging tokens | Flash loan swaps |
| **Available in** | fillAndDispatch, dispatch, cancelAndDispatch | fill, fillAndDispatch, claimAndFill | claimAndFill only |
| **Can retry** | Yes | No | No |

## Data Structures

### BatchCompact (from The Compact)

```solidity
struct BatchCompact {
    address arbiter;        // Party responsible for processing claims
    address sponsor;        // Token source
    uint256 nonce;         // Replay protection (0 for on-chain allocation)
    uint256 expires;       // Expiration timestamp
    Lock[] commitments;    // Array of token locks
}
```

### Lock (Commitment)

```solidity
struct Lock {
    bytes12 lockTag;       // Lock type identifier
    address token;         // Token address (address(0) for native)
    uint256 amount;        // Token amount
}
```

### Mandate

```solidity
struct Mandate {
    address adjuster;           // Assigned adjuster
    FillParameters[] fills;     // Array of possible fills
}
```

### FillParameters

```solidity
struct FillParameters {
    uint256 chainId;                      // Target chain
    address tribunal;                     // Tribunal contract address
    uint256 expires;                      // Expiration timestamp
    FillComponent[] components;           // Multi-token outputs
    uint256 baselinePriorityFee;         // PGA threshold
    uint256 scalingFactor;                // PGA multiplier (1e18 baseline)
    uint256[] priceCurve;                 // Time-based pricing
    RecipientCallback[] recipientCallback; // Optional callback (0 or 1 elements)
    bytes32 salt;                         // Preimage resistance
}
```

### FillComponent

```solidity
struct FillComponent {
    address fillToken;           // Output token
    uint256 minimumFillAmount;   // Base amount
    address recipient;           // Token recipient
    bool applyScaling;          // Enable competitive scaling
}
```

### Adjustment

```solidity
struct Adjustment {
    address adjuster;                    // Adjuster address (not in EIP-712 payload)
    uint256 fillIndex;                   // Selected fill index
    uint256 targetBlock;                 // Auction start block
    uint256[] supplementalPriceCurve;    // Additional pricing
    bytes32 validityConditions;          // Encoded filler + window
    bytes adjustmentAuthorization;       // Adjuster signature (not in EIP-712 payload)
}
```

**Validity Conditions Encoding**:
- Lower 160 bits: Exclusive filler address (0 = any filler)
- Upper 96 bits: Block window duration (0 = no limit, 1 = exact block, N = N blocks)

### DispatchParameters

```solidity
struct DispatchParameters {
    uint256 chainId;    // Target chain for message
    address target;     // Dispatch callback contract
    uint256 value;      // Native token to send
    bytes context;      // Arbitrary data
}
```

### RecipientCallback

```solidity
struct RecipientCallback {
    uint256 chainId;         // Target chain
    BatchCompact compact;    // Follow-up compact
    bytes32 mandateHash;     // Follow-up mandate hash
    bytes context;           // Arbitrary data
}
```

## View Functions

### Hash Derivation

```solidity
function deriveMandateHash(Mandate calldata mandate) external view returns (bytes32)
function deriveFillsHash(FillParameters[] calldata fills) external view returns (bytes32)
function deriveFillHash(FillParameters calldata targetFill) external view returns (bytes32)
function deriveFillComponentHash(FillComponent calldata component) external pure returns (bytes32)
function deriveRecipientCallbackHash(RecipientCallback[] calldata recipientCallback) external pure returns (bytes32)
function deriveClaimHash(BatchCompact calldata compact, bytes32 mandateHash) external pure returns (bytes32)
```

### Amount Calculation

```solidity
function deriveAmounts(
    Lock[] calldata maximumClaimAmounts,
    uint256[] memory priceCurve,
    uint256 targetBlock,
    uint256 fillBlock,
    uint256 minimumFillAmount,
    uint256 baselinePriorityFee,
    uint256 scalingFactor
) external view returns (uint256 fillAmount, uint256[] memory claimAmounts)
```

Simulates price calculation for testing and estimation.

### Compact Integration

```solidity
function getCompactWitnessDetails() external pure returns (
    string memory witnessTypeString,
    ArgDetail[] memory details
)
```

Returns EIP-712 witness structure for The Compact integration.

## EIP-712 Type Structure

Tribunal uses a deeply nested EIP-712 structure:

```
Mandate
├── adjuster: address
└── fills: Mandate_Fill[]
    ├── chainId: uint256
    ├── tribunal: address
    ├── expires: uint256
    ├── components: Mandate_FillComponent[]
    │   ├── fillToken: address
    │   ├── minimumFillAmount: uint256
    │   ├── recipient: address
    │   └── applyScaling: bool
    ├── baselinePriorityFee: uint256
    ├── scalingFactor: uint256
    ├── priceCurve: uint256[]
    ├── recipientCallback: Mandate_RecipientCallback[]
    │   ├── chainId: uint256
    │   ├── compact: Mandate_BatchCompact
    │   │   ├── arbiter: address
    │   │   ├── sponsor: address
    │   │   ├── nonce: uint256
    │   │   ├── expires: uint256
    │   │   ├── commitments: Mandate_Lock[]
    │   │   │   ├── lockTag: bytes12
    │   │   │   ├── token: address
    │   │   │   └── amount: uint256
    │   │   └── mandate: (recursive)
    │   ├── mandateHash: bytes32
    │   └── context: bytes
    └── salt: bytes32

Adjustment
├── claimHash: bytes32
├── fillIndex: uint256
├── targetBlock: uint256
├── supplementalPriceCurve: uint256[]
└── validityConditions: bytes32
```

The witness typestring is used when registering compacts with The Compact, enabling selective reveal of nested data.

## Security Considerations

### Reentrancy Protection
Uses transient storage (`tstore`/`tload`) for gas-efficient, multi-function reentrancy guards. All external state-changing functions are protected.

### Replay Protection

Tribunal implements multiple layers of replay protection to prevent duplicate fills. Claim hashes are marked as filled upon the first successful fill, preventing the same claim from being filled multiple times. Additionally, nonces in The Compact provide replay protection at the claim level. Mandate salts enable sponsors to create multiple mandates with identical parameters while maintaining unique identities.

### Signature Verification

The protocol verifies multiple types of signatures to ensure authorization. Sponsor signatures on compacts are verified through The Compact's infrastructure. Allocator signatures for claims are also verified via The Compact. Finally, adjuster signatures on adjustments are verified directly by Tribunal (via either ECDSA or EIP-1271) to ensure that fills have been properly authorized.

### Expiration Checks

The protocol enforces multiple levels of expiration to ensure timely execution. Claim expiration is enforced through The Compact's mechanisms. Fill expiration operates on a per-fill basis, allowing different fills within the same mandate to have different expiration times. Specific adjustments can also specify their own validity window (expressed in blocks).

### Validity Conditions

The adjuster can restrict fills through validity conditions. These restrictions can limit fills to specific filler addresses, ensuring only intended parties can execute the fill. They can also restrict fills to specific block windows, controlling when fills can occur. Additionally, the adjuster can combine both types of restrictions for fine-grained control over fill execution.

### Fee-on-Transfer Tokens
⚠️ **Warning**: Settling fee-on-transfer tokens results in receiving fewer tokens than specified. Sponsors and fillers must both account for any transfer fees when setting amounts.

## Arbiter Responsibilities

While Tribunal determines auction winners and computes claim amounts, **arbiters are ultimately responsible** for processing claims:

### Tribunal's Role

Tribunal runs auctions and determines the winning fillers for each auction. It records dispositions that include both the claimant identifier and the scaling factor applied to claim amounts. The protocol makes this claim information available through multiple channels including dispatch callbacks, view functions, and events. Finally, Tribunal suggests claim parameters to the arbiter, though the arbiter makes the ultimate decision on whether to accept these suggestions.

### Arbiter's Role

The arbiter receives fill results either via dispatch callbacks or by querying Tribunal's state directly. The arbiter validates the legitimacy of each claim, examining the fill details and ensuring they meet the arbiter's requirements. Based on this validation, the arbiter decides whether to accept Tribunal's suggestions for claimants and claim amounts. The arbiter then actually processes the claims through The Compact's infrastructure, executing the token transfers. Importantly, the arbiter bears full responsibility for the validity of processed claims.

This separation of responsibilities allows arbiters to implement custom validation logic or claim post-processing tailored to their specific requirements. Additionally, arbiters can implement any additional safety checks they deem necessary beyond Tribunal's base guarantees. Fillers are strongly encouraged to familiarize themselves with the implementations and trust assumptions of both the arbiter in question and the the cross-chain messaging protocols they utilize before performing any cross-chain fill to ensure that they will be able to successfully process the associated claim.

## Usage Examples

### Basic Fill Flow

```solidity
// 1. Sponsor creates and signs mandate with The Compact
Mandate memory mandate = Mandate({
    adjuster: adjusterAddress,
    fills: [fillParams]
});

// 2. Adjuster signs adjustment
Adjustment memory adjustment = Adjustment({
    adjuster: adjusterAddress,
    fillIndex: 0,
    targetBlock: block.number,
    supplementalPriceCurve: new uint256[](0),
    validityConditions: bytes32(0),
    adjustmentAuthorization: signature
});

// 3. Filler executes fill
(bytes32 claimHash, bytes32 mandateHash, uint256[] memory fillAmounts, uint256[] memory claimAmounts) = 
    tribunal.fill{value: dispatchCost}(
        compact,
        fillParams,
        adjustment,
        fillHashes,
        claimant,
        0 // use current block
    );

// 4. Results available for cross-chain relay
```

### Same-Chain Fill

```solidity
// Execute claim and fill atomically
(bytes32 claimHash, bytes32 mandateHash, uint256[] memory fillAmounts, uint256[] memory claimAmounts) = 
    tribunal.claimAndFill(
        batchClaim,
        fillParams,
        adjustment,
        fillHashes,
        claimant,
        0
    );

// Tokens immediately available to claimant
```

### Querying Results

```solidity
// Check if filled
bytes32 claimant = tribunal.filled(claimHash);

// Get scaling factor
uint256 scalingFactor = tribunal.claimReductionScalingFactor(claimHash);

// Reconstruct claim amounts
uint256[] memory claimAmounts = new uint256[](compact.commitments.length);
for (uint256 i = 0; i < compact.commitments.length; i++) {
    claimAmounts[i] = compact.commitments[i].amount * scalingFactor / 1e18;
}
```

## Development

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot --isolate
```

### Code Coverage

```shell
$ FOUNDRY_PROFILE=coverage forge coverage --exclude-tests
```

Add `--report lcov` to generate a coverage report. To view the report locally:
```shell
$ genhtml lcov.info --output-directory coverage
$ open coverage/index.html
```

### Deploy

```shell
$ forge script script/Tribunal.s.sol:TribunalScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

## License

MIT
