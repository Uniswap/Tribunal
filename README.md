# Tribunal ☝️

**Tribunal** is a protocol that runs competitive auctions for claims against resource locks. It is tightly integrated with **The Compact** as the preferred mechanism for settling claims after fills occur.

## Overview

Tribunal serves three core roles:

1. **Price Derivation**: Calculates fair prices (either fill amounts or claim amounts) based on parameters provided by the sponsor and their assigned adjuster, the auction start block, the current block, and the transaction's priority fee.

2. **Filler Selection**: Designates a single, specific filler per unique auction and allows them to specify a claimant who is entitled to claim tokens held in the corresponding resource lock.

3. **Result Distribution**: Makes auction results available to be broadcast or relayed to any environment or chain through multiple mechanisms (dispatch callbacks, state queries, or direct on-chain claims).

### What is Tribunal?

Tribunal enables sponsors (token holders) to auction tokens held in resource locks. These auctions:
- Start at a specific block and evolve pricing over time
- Accept bids through actual blockchain transactions (with priority fees influencing prices)
- Support multiple input and/or output tokens in a single auction
- Work across different blockchains
- Integrate with various cross-chain messaging systems

The protocol doesn't dictate _how_ claims are processed across chains—that's the responsibility of the designated arbiter. Tribunal simply determines _who_ won the auction and _what amounts_ should be claimable, and makes that information available through various channels.

### Integration with The Compact

Tribunal is deeply integrated with [The Compact](https://github.com/Uniswap/the-compact), a protocol for managing token deposits and claims through resource locks:

- **Input tokens** (what fillers receive) are held in Compact resource locks
- **Claims against locks** are processed through The Compact's infrastructure
- **Settlement logic** uses The Compact's allocation and claim mechanisms
- **Sponsor signatures** follow The Compact's EIP-712 structure with Tribunal-specific witness data

## Core Concepts

### Auction Participants

**Sponsor**: Creates and signs the auction parameters (mandates). Controls the input tokens.

**Adjuster**: Trusted party assigned by the sponsor who provides signed adjustments that:
- Select which fill from a set of options to execute
- Set the auction start block
- Apply supplemental price curves for dynamic pricing
- Optionally restrict fills to specific addresses or time windows

**Filler**: Provides the output tokens to recipients and designates who can claim the input tokens.

**Arbiter**: External party responsible for ultimately processing claims (may accept or reject Tribunal's suggestions).

**Claimant**: The party designated by the filler to receive the input tokens from the resource lock.

### Auction Structure

A complete auction consists of:

1. **Mandate**: The sponsor's signed commitment containing:
   - Assigned adjuster address
   - Array of possible fills (enabling conditional execution)

2. **Fill Parameters**: Conditions for a specific fill including:
   - Target chain ID and Tribunal contract address
   - Expiration timestamp
   - Array of fill components (multi-token outputs)
   - Pricing parameters (baseline priority fee, scaling factor)
   - Price curve (time-based pricing adjustments)
   - Optional recipient callback specification

3. **Fill Components**: Individual output tokens, each specifying:
   - Token address (address(0) for native ETH)
   - Minimum fill amount
   - Recipient address
   - Whether to apply competitive scaling

4. **Adjustment**: Adjuster's signed authorization providing:
   - Selected fill index
   - Target block (auction start)
   - Supplemental price curve
   - Validity conditions (optional exclusive filler and block window)

## Pricing Mechanisms

Tribunal uses **three independent but composable pricing mechanisms** that work together:

### 1. Priority Gas Auctions (PGA)

Fillers compete by paying higher priority fees. The price adjustment is:

```
priorityFeeAboveBaseline = max(0, tx.gasprice - block.basefee - baselinePriorityFee)
priceAdjustment = priorityFeeAboveBaseline * scalingFactor
```

- **baselinePriorityFee**: Threshold where competitive scaling begins
- **scalingFactor**: Multiplier per wei of priority fee (1e18 = 1:1 ratio)

### 2. Price Curves

Time-based pricing defined as an array of duration/scaling-factor pairs:

- **Block duration** (16 bits): Time window for each segment
- **Scaling factor** (240 bits): Price multiplier for that period
- **Linear interpolation** between discrete points
- **Zero-duration segments**: Instant price jumps at specific blocks

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

**Exact-In Mode** (`scalingFactor ≥ 1e18`):
- Fill amounts increase as fillers compete
- Claim amounts remain at maximum
- Better for "how much output can you provide" auctions

**Exact-Out Mode** (`scalingFactor < 1e18`):
- Claim amounts decrease as fillers compete
- Fill amounts remain at minimum
- Better for "how little input will you accept" auctions

**Direction Consistency**: All scaling factors (base curve, supplemental curve, PGA component) must scale in the same direction or be neutral (1e18).

## Fill Execution

### Standard Fill (Cross-Chain)

For fills on a different chain than the claim:

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

**Process**:
1. Validates mandate hasn't expired and chain ID matches
2. Verifies adjuster's signature on the adjustment
3. Validates validity conditions (exclusive filler, block window)
4. Calculates fill amounts and claim amounts based on all pricing mechanisms
5. Marks claim as filled with designated claimant
6. Transfers fill tokens to recipients
7. Optionally triggers recipient callback
8. Returns claim details for cross-chain relay

### Fill with Dispatch

Immediately sends results to a cross-chain messaging contract:

```solidity
function fillAndDispatch(
    BatchCompact calldata compact,
    FillParameters calldata mandate,
    Adjustment calldata adjustment,
    bytes32[] calldata fillHashes,
    bytes32 claimant,
    uint256 fillBlock,
    DispatchParameters calldata dispatchParameters
) external payable returns (...)
```

The dispatch callback receives all claim details for relaying to the arbiter on the claim chain.

### Same-Chain Fill

For fills on the same chain as the claim:

```solidity
function claimAndFill(
    BatchClaim calldata claim,
    FillParameters calldata mandate,
    Adjustment calldata adjustment,
    bytes32[] calldata fillHashes,
    bytes32 claimant,
    uint256 fillBlock
) external payable returns (...)
```

This function simultaneously:
1. Processes the claim through The Compact
2. Executes the fill
3. Callbacks to the filler with exact requirements
4. Makes tokens immediately available to the claimant

### Deferred Dispatch

Dispatch results of a previously completed fill:

```solidity
function dispatch(
    BatchCompact calldata compact,
    bytes32 mandateHash,
    DispatchParameters calldata dispatchParams
) external payable returns (bytes32 claimHash, uint256[] memory claimAmounts)
```

Useful for:
- Retrying failed dispatches
- Delayed cross-chain messaging
- Multi-step relay processes

## Settlement and Registration

The `settleOrRegister` function handles the destination side of cross-chain flows:

```solidity
function settleOrRegister(
    bytes32 sourceClaimHash,
    BatchCompact calldata compact,
    bytes32 mandateHash,
    address recipient,
    bytes calldata context
) external payable returns (bytes32 registeredClaimHash)
```

**Multi-modal behavior**:

1. **If source claim is filled**: Forwards tokens to the filler (already claimed on source chain)
2. **If empty lock tag**: Direct transfer to recipient (no lock needed)
3. **If zero mandate hash**: Deposits tokens to The Compact without registration
4. **If nonce is zero**: On-chain allocation flow with allocator callbacks
5. **Otherwise**: Standard compact registration for follow-up auction

This flexibility enables complex multi-chain flows where:
- Fill on Chain A → Bridge to Chain B → Register new auction on Chain B
- Fill on Chain A → Bridge to Chain B → Direct transfer to recipient
- Fill on Chain A → Bridge to Chain B → Deposit for manual allocation

## Cancellation

Sponsors can cancel unfilled auctions:

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

Cancellation:
- Prevents future fills on that claim hash
- Stores `type(uint256).max` as the cancellation flag
- `claimReductionScalingFactor()` returns 0 for cancelled claims
- Can trigger dispatch callback with zero amounts

## Querying Auction Results

### Check Fill Status

```solidity
function filled(bytes32 claimHash) external view returns (bytes32)
```

Returns:
- The claimant if filled
- The sponsor if cancelled
- Zero if unfilled

### Get Scaling Factor

```solidity
function claimReductionScalingFactor(bytes32 claimHash) external view returns (uint256)
```

Returns:
- The actual scaling factor if claims were reduced (< 1e18)
- 1e18 if no reduction occurred
- 0 if the claim was cancelled

### Batch Query

```solidity
function getDispositionDetails(bytes32[] calldata claimHashes)
    external view returns (DispositionDetails[] memory)
```

Efficiently queries multiple claims at once, returning both claimant and scaling factor for each.

## Callback Interfaces

### Dispatch Callback (Cross-Chain Messaging)

Implement `IDispatchCallback` to receive fill results:

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

Use this to:
- Send cross-chain messages to arbiters
- Relay claim information to destination chains
- Trigger follow-up actions based on fill results

### Recipient Callback (Bridging)

Implement `IRecipientCallback` to receive same-chain fill notifications:

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

Use this to:
- Bridge tokens to another chain
- Register follow-up compacts
- Chain multiple auctions together

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
- Claim hashes are marked as filled on first successful fill
- Nonces in The Compact provide additional replay protection
- Mandate salts enable multiple mandates with same parameters

### Signature Verification
- Sponsor signatures on compacts (via The Compact)
- Allocator signatures for claims (via The Compact)
- Adjuster signatures on adjustments (via Tribunal)

### Expiration Checks
Multiple levels of expiration:
- Compact expiration (from The Compact)
- Fill expiration (per-fill basis)
- Mandate expiration (inherited from compact)

### Validity Conditions
Adjuster can restrict fills to:
- Specific filler addresses
- Specific block windows
- Combination of both

### Fee-on-Transfer Tokens
⚠️ **Warning**: Settling fee-on-transfer tokens results in fewer tokens received than specified. Sponsors must account for transfer fees when setting amounts.

## Arbiter Responsibilities

While Tribunal determines auction winners and computes claim amounts, **arbiters are ultimately responsible** for processing claims:

### Tribunal's Role
- Runs auctions and determines winners
- Records dispositions (claimant + scaling factor)
- Makes claim information available via multiple channels
- Suggests claim parameters

### Arbiter's Role
- Receives fill results (via dispatch or queries)
- Validates claim legitimacy
- Decides whether to accept Tribunal's suggestions
- Actually processes claims through The Compact
- Bears responsibility for claim validity

This separation allows arbiters to implement:
- Custom validation logic
- Dispute resolution mechanisms
- Multi-signature requirements
- Additional safety checks

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

Add `--report lcov` to generate a coverage report:
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
