# Tribunal

**Tribunal** is a framework for processing cross-chain swap settlements against PGA (priority gas auction) blockchains. It ensures that tokens are transferred according to the mandate specified by the originating sponsor and enforces that a single party is able to perform the settlement in the event of a dispute.

To settle a cross-chain swap, the filler submits a `petition` to the Tribunal contract. This consists of three core components:
1. **Compact**: Defines the claim parameters and constraints specified by the sponsor.
2. **Mandate**: Specifies settlement conditions and amount derivation parameters specified by the sponsor.
3. **Directive**: Contains execution details provided by the filler including claimant and dispensation.

### Core Components

#### Compact Structure
```solidity
struct Compact {
    uint256 chainId;          // Claim processing chain ID
    address arbiter;          // Claim verification account
    address sponsor;          // Token source account
    uint256 nonce;            // Replay protection parameter
    uint256 expires;          // Claim expiration timestamp
    uint256 id;               // Claimed ERC6909 token ID
    uint256 maxAmount;        // Maximum claimable tokens
    bytes sponsorSignature;   // Authorization from the sponsor
    bytes allocatorSignature; // Authorization from the allocator
}
```

#### Mandate Structure
```solidity
struct Mandate {
    bytes32 seal;                // Replay protection parameter
    uint256 expires;             // Mandate expiration timestamp
    address recipient;           // Recipient of settled tokens
    address token;               // Settlement token (address(0) for native)
    uint256 minAmount;           // Minimum settlement amount
    uint256 baselinePriorityFee; // Base fee threshold where scaling kicks in
    uint256 scalingFactor;       // Fee scaling multiplier (1e18 baseline)
}
```

#### Directive Structure
```solidity
struct Directive {
    address claimant;     // Recipient of claimed tokens
    uint256 dispensation; // Cross-chain message layer payment
}
```

### Process Flow

1. Fillers initiate by calling `petition(Compact calldata compact, Mandate calldata mandate, Directive calldata directive)` and providing any msg.value required for the settlement and the dispensation to pay to process the cross-chain message.
2. Tribunal performs validation:
   - Checks `seal` uniqueness in storage mapping & sets it
   - Verifies mandate `expires` timestamp
3. Computation phase:
   - Derives `mandateHash` using an EIP712 typehash, destination chainId, tribunal address, and mandate data
   - Calculates `settlementAmount` and `claimAmount` based on:
     - Compact `maxAmount`
     - Mandate parameters (`minAmount`, `baselinePriorityFee`, `scalingFactor`)
     - `tx.gasprice` and `block.basefee`
     - NOTE: `scalingFactor` will result in an increased `settlementAmount` if `> 1e18` or a decreased `claimAmount` if `< 1e18`
     - NOTE: `scalingFactor` is combined with `tx.gasprice - (block.basefee + baselinePriorityFee)` (or 0 if it would otherwise be negative) before being applied to the amount
4. Execution phase:
   - Transfers `settlementAmount` of `token` to mandate `recipient`
   - Processes directive via `_processDirective(compact, mandateHash, directive, claimAmount)`

There are also a few view functions:
 - `quote(Compact calldata compact, Mandate calldata mandate, Directive calldata directive)` will suggest a dispensation amount (function of gas on claim chain + any additional "protocol overhead" if using push-based cross-chain messaging)
 - `getCompactWitnessDetails()` will return the Mandate witness typestring and that correlates token + amount arguments (so frontends can show context about the token and use decimal inputs)
 - `disposition(address sponsor, bytes32 seal)` will check if a seal has been recorded yet for a given sponsor.
 - `getMandateHash(Compact calldata compact, Mandate calldata mandate)` will return the EIP712 typehash for the mandate, which must be provided as the witness to The Compact when processing the claim.
 - `getSettlementAmount(Compact calldata compact, Mandate calldata mandate)` will return the settlement amount based on the compact and mandate; the base fee and priority fee will be applied to the amount and so should be tuned in the call appropriately.

#### Mandate EIP-712 Typehash
This is what swappers will see as their witness data when signing a `Compact`:
```solidity
struct Mandate {
    uint256 chainId;
    address tribunal;
    bytes32 seal;
    uint256 expires;
    address recipient;
    address token;
    uint256 minAmount;
    uint256 baselinePriorityFee;
    uint256 scalingFactor;
}
```

## Remaining Work
- [ ] Create CI/CD pipeline
- [ ] Implement bitpacking for seal
- [ ] Implement directive processing with cross-chain messaging
- [ ] Implement quote function for gas estimation
- [ ] Implement getCompactWitnessDetails for frontend integration
- [ ] Set up comprehensive testing suite
- [ ] Add tests for fee-on-transfer tokens
- [ ] Add tests for quote function
- [ ] Add tests for witness details
- [ ] Add tests for directive processing
- [ ] Develop integration tests
- [ ] Create deployment scripts

## Test Cases

### Core Functionality
- [X] Petition submission
- [X] Seal verification
- [X] Expiration checking
- [X] Hash derivation
- [X] Amount calculations
- [X] Token transfers
- [ ] Quote function
- [ ] Witness details
- [ ] Directive processing

### Edge Cases
- [X] Zero amounts
- [X] Native token handling
- [X] Invalid seals
- [X] Expired mandates
- [X] Gas price edge cases
- [X] Scale factor boundaries
- [ ] Fee-on-transfer tokens
- [ ] Cross-chain message failures
- [ ] Maximum gas price scenarios

### Security
- [X] Replay protection
- [X] Access control
- [X] Input validation
- [X] Integer overflow/underflow
- [X] ECDSA Sponsor signature verification
- [ ] EIP-1271 Sponsor signature verification
- [ ] Cross-chain message security
- [ ] Gas estimation attack vectors

### Reentrancy
Reentrancy protection is not needed in the current design as it follows the checks-effects-interactions pattern and never holds tokens. The contract consumes nonces before any external calls and uses a pull pattern for token transfers.

### Sponsor Signature Verification
To prevent griefing attacks where a malicious filler could consume a sponsor's seal without a valid compact:
- Each compact must be signed by the sponsor using EIP-712
- The signature is verified before consuming the seal
- Note: EIP-1271 contract sponsors are not currently supported and will need a different griefing prevention mechanism

### Fee-on-Transfer Token Handling
Swappers must handle fee-on-transfer tokens carefully, as settlement will result in fewer tokens being received by the recipient than the specified settlement amount. When providing settlement amounts for such tokens:
- Swappers must account for the token's transfer fee in their calculations
- The actual received amount will be less than the specified settlement amount
- Frontend implementations should display appropriate warnings
- Consider implementing additional safety checks or multipliers (though this also complicates matters for fillers)

## Future Work
* Additional amount derivation functions (eg reverse dutch)
* Multi-token settlement support
* Batch processing capabilities
* Cross-chain message optimization
* Advanced dispute resolution mechanisms
* Gas optimization improvements

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