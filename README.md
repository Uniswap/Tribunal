# Tribunal ☝️

**Tribunal** is a framework for processing cross-chain swap settlements against PGA (priority gas auction) blockchains. It ensures that tokens are transferred according to the mandate specified by the originating sponsor and enforces that a single party is able to perform the settlement in the event of a dispute.

To settle a cross-chain swap, the filler submits a "fill" request to the Tribunal contract. This consists of multiple components:
1. **BatchClaim**: Contains the chain ID of a batch compact, its parameters, and its sponsor signature and allocator authorization data
2. **Fill**: Specifies settlement conditions, amount derivation parameters, and recipient details
3. **Adjustment**: Parameters signed by the adjuster including target block, price improvement, and validity conditions
4. **Claimant**: Specifies the account that will receive the claimed tokens and details on whether to place them in a resource lock or to withdraw the underlying tokens

> Note for cross-chain message protocols integrating with Tribunal: inherit the `Tribunal` contract and override the `_processDirective` and `_quoteDirective` functions to implement the relevant directive processing logic for passing a message to the arbiter on the claim chain (or ensure that the necessary state is updated to allow for the arbiter to "pull" the message themselves).

### Core Components

#### BatchClaim Structure
```solidity
struct BatchClaim {
    uint256 chainId;              // Claim processing chain ID
    BatchCompact compact;          // The compact parameters
    bytes sponsorSignature;        // Authorization from the sponsor
    bytes allocatorSignature;      // Authorization from the allocator
}
```

#### BatchCompact Structure (from The Compact)
```solidity
struct BatchCompact {
    address arbiter;               // The account tasked with verifying and submitting the claim
    address sponsor;               // The account to source the tokens from
    uint256 nonce;                 // A parameter to enforce replay protection, scoped to allocator
    uint256 expires;               // The time at which the claim expires
    Lock[] commitments;            // Array of token commitments
}
```

#### Lock Structure (commitment)
```solidity
struct Lock {
    bytes12 lockTag;               // Tag identifying the lock type
    address token;                 // Token address (address(0) for native)
    uint256 amount;                // Amount of tokens locked
}
```

#### Mandate Structure
```solidity
struct Mandate {
    address adjuster;              // The adjuster who can authorize fills
    Fill[] fills;                  // Array of possible fill conditions
}
```

#### Fill Structure
```solidity
struct Fill {
    uint256 chainId;               // Chain where fill occurs
    address tribunal;              // Tribunal contract address
    uint256 expires;               // Fill expiration timestamp
    address fillToken;             // Fill token (address(0) for native)
    uint256 minimumFillAmount;     // Minimum fill amount
    uint256 baselinePriorityFee;  // Base fee threshold where scaling kicks in
    uint256 scalingFactor;         // Fee scaling multiplier (1e18 baseline)
    uint256[] priceCurve;          // Block durations and scaling factors
    address recipient;             // Recipient of filled tokens
    RecipientCallback[] recipientCallback; // Optional callback array
    bytes32 salt;                  // Preimage resistance parameter
}
```

#### Adjustment Structure
```solidity
struct Adjustment {
    uint256 fillIndex;             // Index of the fill being executed
    uint256 targetBlock;           // Target block for the fill
    uint256[] supplementalPriceCurve; // Additional price curve adjustments
    bytes32 validityConditions;   // Optional filler address and block window
}
```

#### RecipientCallback Structure
```solidity
struct RecipientCallback {
    uint256 chainId;               // Chain ID for the callback
    BatchCompact compact;          // Compact for the callback
    bytes32 mandateHash;           // Hash of the mandate
    bytes context;                 // Additional context data
}
```

### Process Flow

1. Fillers initiate by calling `fill(BatchClaim calldata claim, Fill calldata mandate, address adjuster, Adjustment calldata adjustment, bytes calldata adjustmentAuthorization, bytes32[] calldata fillHashes, bytes32 claimant, uint256 fillBlock)` and providing any msg.value required for the settlement to pay to process the cross-chain message.
2. Tribunal verifies:
   - The mandate has not expired
   - The chain ID matches
   - Validity conditions from the adjustment are met (filler address and block window)
   - The adjuster's signature on the adjustment is valid
3. Computation phase:
   - Derives the EIP-712 hash of the target `Fill` based on the index indicated by the adjuster
   - Derives `mandateHash` using the `adjuster` account and the `fillHashes` array (ensuring the hash of the indicated fill matches the provided hash at the respective index) 
   - Derives `claimHash` using the compact and mandate hash
   - Ensures that the `claimHash` has not already been used and marks it as filled
   - Calculates `fillAmount` and `claimAmounts` based on:
     - Compact commitment amounts
     - Fill parameters (`minimumFillAmount`, `baselinePriorityFee`, `scalingFactor`)
     - Price curves (both base and supplemental)
     - Target block and fill block timing
     - `tx.gasprice` and `block.basefee`
4. Execution phase:
   - Transfers `fillAmount` of `fillToken` to fill `recipient`
   - For same-chain fills: Claims tokens via The Compact and triggers a callback
   - For cross-chain fills: Processes directive via `_processDirective`
   - Performs optional recipient callback if specified
   - Returns any unused native tokens to the caller

### Key Functions

#### Fill Function
```solidity
function fill(
    BatchClaim calldata claim,
    Fill calldata mandate,
    address adjuster,
    Adjustment calldata adjustment,
    bytes calldata adjustmentAuthorization,
    bytes32[] calldata fillHashes,
    bytes32 claimant,
    uint256 fillBlock
) external payable returns (
    bytes32 claimHash,
    bytes32 mandateHash,
    uint256 fillAmount,
    uint256[] memory claimAmounts
)
```

#### Settlement/Registration Function
```solidity
function settleOrRegister(
    bytes32 sourceClaimHash,
    BatchCompact calldata compact,
    bytes32 mandateHash,
    address recipient
) external returns (bytes32 registeredClaimHash)
```
Serves as a point of entry where bridged tokens (triggered via recipient callback of a filled same-chain compact on another chain) are either:
 - used to register a new compact on the target chain
 - sent directly to the sponsor (assuming the sponsor cancels the target chain compact after the bridge was already initiated) or the filler (assuming the filler successfully performed a fill on the target chain and a same-chain fill was triggered before the filler was able to claim the tokens from the source chain).

 > Note: the adjuster is expected to only authorize a same-chain fill in the `fills` array after verifying that the cross-chain fill has not already been executed; the settlement mechanic where tokens will be forwarded to the filler in the event of a fill is intended to operate as an added "safety measure" and is not meant to be invoked as part of default behavior. This protects against race conditions or erroneous/malicious adjusters and gives fillers additional confidence that they will receive back tokens on the target chain even if the tokens are no longer claimable on the source chain. Cross-chain fillers should consider the adjuster in question and examine the entire fill array to ensure they are comfortable with the possibility that multiple fills may trigger if they are not fully confident that the adjuster will correctly prevent that outcome.

#### Cancel Functions
```solidity
function cancel(BatchClaim calldata claim, bytes32 mandateHash) external payable
function cancelChainExclusive(BatchCompact calldata compact, bytes32 mandateHash) external
```
Allows sponsors to cancel claims before they are filled. The `cancel` function will trigger a dispensation back to the source chain, explicitly consuming the source chain compact and enabling early deallocation of respective source chain tokens. The `cancelChainExclusive` function will only invalidate the fill on the target chain, skipping the dispensation and any associated costs.

> Note: Cross-chain fills must be cancelled on the target chain prior to a successful fill on that chain. Same-chain fills can be safely cancelled directly on that chain at any point prior to the fill.

#### View Functions
- `quote(...)` - Suggests a dispensation amount for cross-chain messaging costs
- `filled(bytes32 claimHash)` - Checks if a claim hash has been filled or cancelled
- `getCompactWitnessDetails()` - Returns witness typestring and argument positions
- `deriveMandateHash(Mandate calldata mandate)` - Derives EIP-712 mandate hash
- `deriveFillHash(Fill calldata targetFill)` - Derives EIP-712 fill hash
- `deriveClaimHash(BatchCompact calldata compact, bytes32 mandateHash)` - Derives claim hash
- `deriveAmounts(...)` - Calculates fill and claim amounts based on parameters

### EIP-712 Type Hashes

The contract uses a nested, recursive EIP-712 structure:

```solidity
// Main typehashes
MANDATE_TYPEHASH
MANDATE_FILL_TYPEHASH
MANDATE_RECIPIENT_CALLBACK_TYPEHASH
MANDATE_BATCH_COMPACT_TYPEHASH
MANDATE_LOCK_TYPEHASH
COMPACT_TYPEHASH_WITH_MANDATE
ADJUSTMENT_TYPEHASH
```

The witness typestring used for The Compact integration includes the full nested structure of mandates, fills, and callbacks.

### Price Curves and Scaling

The contract supports multiple concurrent pricing mechanisms:
- **Base price curves**: Define how prices change over blocks from the target block, with linear interpolation between respective durations in the relevant timeframe
- **Supplemental price curves**: Additional adjustments to the price curve provided by the adjuster
- **Scaling factors**: Modify amounts based on gas prices above baseline
- **Exact-in vs Exact-out**: Automatically determines whether to scale fill amount up or claim amount down

> Note: Each concurrent "scaling factor" is aggregated with other scaling factors to determine the final scaling factor. Exact-in indicates that the fill amount will be scaled up, while exact-out indicates that the claim amounts will be scaled down. "Wad" math is utilized such that a scaling factor of 1e18 will result in no price change, values above 1e18 will result in the fill amount being scaled up to (amount * scaling factor) / 1e18, and values below 1e18 will result in the claim amounts being scaled down to (amount * scaling factor) / 1e18. The "direction" of each scaling factor must be consistent so that all values scale the same side of the swap or are neutral.

### Integration with The Compact

Tribunal is deeply integrated with The Compact protocol for:
- Token deposits and registrations
- Claim processing for same-chain fills
- Integration with onchain allocations (indicated by providing a nonce of 0 to `settleOrRegister`)
- Batch operations for compacts involving multiple token commitments

### Security Features

- **Reentrancy protection**: Using transient storage for gas-efficient guards
- **Replay protection**: Via claim hash tracking and nonces
- **Signature verification**: For sponsors, allocators, and adjusters
- **Expiration checks**: At multiple levels (compact, fill, mandate)
- **Validity conditions**: Optional exclusive filler and block windows

### Fee-on-Transfer Token Handling
Swappers must handle fee-on-transfer tokens carefully, as settlement will result in fewer tokens being received by the recipient than the specified fill amount. When providing fill amounts for such tokens:
- Swappers must account for the token's transfer fee in their calculations
- The actual received amount will be less than the specified fill amount
- Frontend implementations should display appropriate warnings

## Remaining Work
- [ ] Provide examples for directive processing with various cross-chain messaging systems
- [ ] Provide examples for performing same-chain token swaps followed by a registration of an associated compact on a target chain via recipient callbacks with various bridging systems
- [ ] Improve quote function for gas estimation
- [ ] Add comprehensive integration tests
- [ ] Update deployment scripts
- [ ] Document adjuster role and responsibilities
- [ ] Add examples for complex multi-chain flows

## Usage

```shell
$ git clone https://github.com/uniswap/tribunal
$ forge install
```

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
$ forge coverage
```

### Deploy

```shell
$ forge script script/Tribunal.s.sol:TribunalScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```