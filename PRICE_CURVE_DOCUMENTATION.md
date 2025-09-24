# PriceCurveLib Documentation: Constructing and Understanding Price Curves

## Overview

PriceCurveLib is a critical component of the Tribunal system that enables dynamic pricing through time-based scaling factors. This library manages how fill amounts (for exact-in swaps) or claim amounts (for exact-out swaps) change over time based on block progression.

## Core Concepts

### 1. PriceCurveElement Structure

Each price curve element is a 256-bit packed value containing:
- **Block Duration** (16 bits): Number of blocks this segment lasts
- **Scaling Factor** (240 bits): The scaling factor at the start of this segment

```solidity
// Bit layout:
// [16 bits: blockDuration][240 bits: scalingFactor]
```

### 2. Scaling Factor Semantics

The scaling factor determines the swap mode and how priority fees affect pricing:
- `scalingFactor > 1e18`: **Exact-in mode** - Filler provides variable fill amount, claims fixed maximum amounts
- `scalingFactor < 1e18`: **Exact-out mode** - Filler provides fixed minimum fill amount, claims variable amounts
- `scalingFactor == 1e18`: **Neutral** - No priority fee scaling applied

**Important**: The scaling factor determines the MODE (exact-in vs exact-out), NOT the direction of price movement over time. The price curve elements control how prices change over time, and can increase, decrease, or remain constant regardless of the mode.

### 3. Interpolation Behavior

Within each segment, the system linearly interpolates between:
- The segment's starting scaling factor
- The next segment's scaling factor (or 1e18 if it's the last segment)

## Auction Duration and Timing

### Auction Lifecycle

The auction timing is controlled by three key parameters:

1. **`targetBlock`** (from Adjustment): The block when the auction begins
2. **`validBlockWindow`** (from Adjustment.validityConditions): How long the auction runs
3. **Price Curve Duration**: The total blocks defined in the price curve

### Validity Window Mechanics

The `validityConditions` field packs two values:
- **Lower 160 bits**: Exclusive filler address (0 = anyone can fill)
- **Upper 96 bits**: `validBlockWindow` - blocks the auction remains valid

```solidity
// Extracting the validity window:
uint256 validBlockWindow = uint256(adjustment.validityConditions) >> 160;
```

**Validity Window Behaviors**:
- `validBlockWindow == 0`: No restriction - auction runs until price curve ends
- `validBlockWindow == 1`: Must be filled exactly at `targetBlock`
- `validBlockWindow > 1`: Auction valid for exactly this many blocks after `targetBlock`

### Boundary Conditions

1. **Before Target Block**:
   ```solidity
   fillBlock < targetBlock → InvalidTargetBlock error
   ```

2. **After Validity Window**:
   ```solidity
   validBlockWindow != 0 && fillBlock >= targetBlock + validBlockWindow 
   → ValidityConditionsNotMet error
   ```

3. **After Price Curve Duration**:
   ```solidity
   blocksPassed >= totalPriceCurveDuration → PriceCurveBlocksExceeded error
   ```

### Timeline Example

```
targetBlock = 100
validBlockWindow = 50
Price curve total duration = 30 blocks

Block 99:  Cannot fill (InvalidTargetBlock)
Block 100: Auction begins, price at curve start
Block 130: Price curve ends (reaches 1e18), but auction still valid
Block 149: Last valid block (if validBlockWindow = 50)
Block 150: Cannot fill (ValidityConditionsNotMet)
```

**Important**: The price curve and validity window operate independently:
- Price curve can be shorter than validity window (price stays at final value)
- Price curve cannot be longer than validity window (would revert with PriceCurveBlocksExceeded)

## Edge Cases and Special Behaviors

### 1. Empty Price Curve Array

```solidity
uint256[] memory priceCurve = new uint256[](0);
```

**Behavior**: Returns a constant scaling factor of `1e18` (neutral)
**Use Case**: No time-based price adjustment needed
**Note**: An empty price curve always returns neutral scaling (1e18) regardless of targetBlock

### 2. Zero Duration Elements

Zero duration elements (`blockDuration == 0`) create "instantaneous" price points:

```solidity
uint256[] memory priceCurve = new uint256[](3);
priceCurve[0] = (10 << 240) | uint256(1.2e18);  // 10 blocks at 1.2x
priceCurve[1] = (0 << 240) | uint256(1.5e18);   // Zero duration at 1.5x
priceCurve[2] = (20 << 240) | uint256(1e18);    // 20 blocks ending at 1x
```

**Key Behaviors**:
- Zero-duration elements act as "waypoints" that are active at specific block numbers
- If `blocksPassed` equals the block count when a zero-duration element is reached, that element's scaling factor is used
- The next non-zero segment interpolates FROM the zero-duration scaling factor
- The `hasPassedZeroDuration` flag tracks whether a zero-duration element was actually reached

**Example Timeline**:
```
Block 0-9:   Interpolate from 1.2x to 1.5x
Block 10:    Exactly 1.5x (zero-duration element)
Block 11-30: Interpolate from 1.5x to 1.0x
```

### 3. Zero Scaling Factor

```solidity
priceCurve[0] = (100 << 240) | uint256(0); // Scaling factor of 0
```

**Behavior**: 
- For exact-out mode: Claim amount becomes 0
- Generally not recommended as it can lead to zero-value fills
- Used only in extreme cases where you want to effectively disable fills after a certain time

### 4. Scaling Factor of 1e18 (Neutral)

```solidity
priceCurve[0] = (100 << 240) | uint256(1e18); // Neutral scaling
```

**Behavior**: No scaling applied - original amounts remain unchanged
**Use Case**: Maintain constant pricing across a time period

### 5. Multiple Consecutive Zero-Duration Elements

```solidity
priceCurve[0] = (10 << 240) | uint256(1.2e18);
priceCurve[1] = (0 << 240) | uint256(1.5e18);   // First zero-duration
priceCurve[2] = (0 << 240) | uint256(1.3e18);   // Second zero-duration (ignored)
priceCurve[3] = (10 << 240) | uint256(1e18);
```

**Behavior**: Only the FIRST zero-duration element at a given block count is used (subsequent ones are ignored)

### 6. Invalid Configurations

The following will cause reverts:

#### a. Exceeding Total Block Duration
```solidity
// Will revert with PriceCurveBlocksExceeded if blocksPassed >= total duration
priceCurve[0] = (10 << 240) | uint256(1.2e18);
// Trying to access block 15 when only 10 blocks defined
```

#### b. Inconsistent Scaling Directions
```solidity
// Will revert with InvalidPriceCurveParameters
priceCurve[0] = (10 << 240) | uint256(1.5e18);  // Increase (>1e18)
priceCurve[1] = (10 << 240) | uint256(0.5e18);  // Decrease (<1e18) - INVALID!
```

#### c. Mixed Scaling Directions
```solidity
// All segments must be on the same side of 1e18
// Cannot mix exact-in (>1e18) and exact-out (<1e18) scaling factors
```

## Common Price Curve Patterns

### 1. Linear Decay (Dutch Auction Style)

```solidity
// Price increases linearly from 0.8x to 1.0x over 100 blocks
uint256[] memory priceCurve = new uint256[](1);
priceCurve[0] = (100 << 240) | uint256(8e17); // 0.8x scaling
// Automatically interpolates to 1e18 (1.0x) at the end
```

### 2. Step Function with Plateaus

```solidity
uint256[] memory priceCurve = new uint256[](4);
priceCurve[0] = (50 << 240) | uint256(1.5e18);  // High price for 50 blocks
priceCurve[1] = (0 << 240) | uint256(1.2e18);   // Drop to 1.2x (zero-duration)
priceCurve[2] = (50 << 240) | uint256(1.2e18);  // Hold at 1.2x for 50 blocks (creates plateau)
priceCurve[3] = (50 << 240) | uint256(1e18);    // Final decay to 1.0x

// Timeline:
// Blocks 0-49: Interpolate from 1.5x down to 1.2x
// Block 50: Drop to exactly 1.2x (zero-duration element)
// Blocks 51-100: Stay at 1.2x (plateau - segment 2 matches zero-duration value)
// Blocks 101-150: Interpolate from 1.0x (segment 3) to 1.0x (final value)
```

**Note**: When a zero-duration element has the same value as the next segment, it creates a true plateau where the value stays constant.

### 3. Aggressive Initial Discount

```solidity
uint256[] memory priceCurve = new uint256[](2);
priceCurve[0] = (10 << 240) | uint256(5e17);   // Start at 0.5x (50% discount)
priceCurve[1] = (90 << 240) | uint256(9e17);   // Quickly rise to 0.9x
// Then gradually approach 1.0x
```

### 4. Reverse Dutch Auction

```solidity
// Price starts high and decreases over time (regardless of mode)
uint256[] memory priceCurve = new uint256[](1);
priceCurve[0] = (200 << 240) | uint256(2e18);   // Start at 2x
// Interpolates down to 1x over 200 blocks
```

### 5. Inverted Auction (Price Increases Over Time)

```solidity
// Price starts low and increases over time
uint256[] memory priceCurve = new uint256[](1);
priceCurve[0] = (100 << 240) | uint256(5e17);   // Start at 0.5x
// Interpolates up to 1x over 100 blocks
```

### 6. Complex Multi-Phase Curve

```solidity
// All segments must stay on same side of 1e18 (all above or all below)
uint256[] memory priceCurve = new uint256[](3);
priceCurve[0] = (30 << 240) | uint256(0.5e18);  // Start at 0.5x
priceCurve[1] = (40 << 240) | uint256(0.7e18);  // Rise to 0.7x at block 30
priceCurve[2] = (30 << 240) | uint256(0.8e18);  // Rise to 0.8x at block 70
// Final interpolation to 1x at block 100

// Timeline:
// Blocks 0-29: Interpolate from 0.5x to 0.7x
// Blocks 30-69: Interpolate from 0.7x to 0.8x
// Blocks 70-99: Interpolate from 0.8x to 1.0x
```

**Important**: Cannot mix scaling factors above and below 1e18 - this would cause `InvalidPriceCurveParameters`.

## Integration with Tribunal

### Priority Fee Interaction

The price curve provides a base scaling factor (`currentScalingFactor`) that changes over time. This is then adjusted based on priority fees:

```solidity
// For exact-in (scalingFactor > 1e18):
// Higher priority fees increase the fill amount required
scalingMultiplier = currentScalingFactor + ((scalingFactor - 1e18) * priorityFeeAboveBaseline);
fillAmount = minimumFillAmount.mulWadUp(scalingMultiplier);
// Claim amounts remain at maximum

// For exact-out (scalingFactor < 1e18):
// Higher priority fees decrease the claim amounts
scalingMultiplier = currentScalingFactor - ((1e18 - scalingFactor) * priorityFeeAboveBaseline);
fillAmount = minimumFillAmount; // Stays fixed
// Claim amounts are scaled down from maximum
```

**Key Insight**: The price curve controls how `currentScalingFactor` changes over blocks, while `scalingFactor` controls how priority fees modify this base value.

### Supplemental Price Curves

Adjusters can apply supplemental price curves that modify the base curve:

```solidity
// Base curve + supplemental curve
uint256 combinedScalingFactor = scalingFactor + supplementalScalingFactor - 1e18;
```

**Important**: Both curves must share the same scaling direction (both > 1e18 or both < 1e18).

## Complete Example: Dutch Auction with Validity Window

```solidity
// Sponsor creates a fill with price curve
Fill memory fill = Fill({
    chainId: 1,
    tribunal: tribunalAddress,
    expires: block.timestamp + 1 hours,
    fillToken: USDC,
    minimumFillAmount: 1000e6,
    baselinePriorityFee: 1 gwei,
    scalingFactor: 15e17, // 1.5x scaling with priority fees
    priceCurve: createDutchAuctionCurve(),
    recipient: recipientAddress,
    recipientCallback: new RecipientCallback[](0),
    salt: keccak256("unique")
});

// Adjuster signs adjustment
Adjustment memory adjustment = Adjustment({
    fillIndex: 0,
    targetBlock: 1000000, // Auction starts at block 1,000,000
    supplementalPriceCurve: new uint256[](0),
    validityConditions: bytes32(uint256(100) << 160) // Valid for 100 blocks
});

function createDutchAuctionCurve() pure returns (uint256[] memory) {
    uint256[] memory curve = new uint256[](3);
    
    // First 30 blocks: Start at 1.5x, decay to 1.2x
    curve[0] = (30 << 240) | uint256(15e17);
    
    // Next 40 blocks: Continue from 1.2x to 1.0x  
    curve[1] = (40 << 240) | uint256(12e17);
    
    // Final 30 blocks: Remain at minimum price (1.0x)
    curve[2] = (30 << 240) | uint256(1e18);
    
    return curve; // Total: 100 blocks matching validity window
}
```

**Timeline**:
- Blocks 999,999 and before: Cannot fill (before targetBlock)
- Block 1,000,000: Auction starts at 1.5x scaling
- Block 1,000,030: Price at 1.2x (end of first segment)
- Block 1,000,070: Price at 1.0x (end of second segment)
- Block 1,000,099: Last valid fill block at 1.0x
- Block 1,000,100+: Cannot fill (ValidityConditionsNotMet)

## Best Practices

1. **Match price curve to validity window** - Ensure total curve duration ≤ validity window
2. **Consider block time variance** - Blocks may not be perfectly regular
3. **Test boundary conditions** - Especially at targetBlock and targetBlock + validBlockWindow
4. **Account for gas costs** - Very long price curves consume more gas to process
5. **Set reasonable expiration times** - The Fill.expires provides an absolute deadline

## Debugging Tips

When a price curve isn't behaving as expected:

1. **Check timing alignment**: Ensure targetBlock, validBlockWindow, and curve duration are compatible
2. **Verify scaling directions**: All segments must be on same side of 1e18
3. **Test zero-duration placement**: They only apply at exact block positions
4. **Validate bit packing**: Ensure duration fits in 16 bits (max 65,535 blocks)
5. **Monitor blocksPassed calculation**: `blocksPassed = fillBlock - targetBlock`

## Security Considerations

1. **Overflow Protection**: The library uses unchecked math in safe contexts
2. **Direction Validation**: `sharesScalingDirection` prevents dangerous crossovers
3. **Bounds Checking**: Multiple layers of validation for block ranges
4. **Precision Loss**: Be aware of potential rounding in interpolation calculations
5. **Timing Attacks**: Validators/sequencers could potentially manipulate fill timing within validity windows
