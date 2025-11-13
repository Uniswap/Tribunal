// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {EfficiencyLib} from "the-compact/src/lib/EfficiencyLib.sol";

/**
 * @title PriceCurveElement
 * @notice Custom type for price curve parameters with bit-packed values.
 * @dev Each element packs two values into a single uint256:
 *      - blockDuration (16 bits): Duration in blocks for this curve segment
 *      - scalingFactor (240 bits): Scaling factor to apply during this segment (1e18 = neutral)
 */
type PriceCurveElement is uint256;

/**
 * @title PriceCurveLib
 * @author 0age
 * @custom:security-contact security@uniswap.org
 * @notice Library for managing time-based price curves in Tribunal auctions.
 * @dev Provides functionality for creating, manipulating, and evaluating price curves that define how
 * auction prices evolve over time. Supports linear interpolation between discrete points, instant price
 * jumps via zero-duration segments, and combining base curves with supplemental adjustments from adjusters.
 * Each PriceCurveElement packs a block duration (16 bits) and scaling factor (240 bits) into a single uint256.
 */
library PriceCurveLib {
    using PriceCurveLib for uint256;
    using FixedPointMathLib for uint256;
    using EfficiencyLib for bool;

    error PriceCurveBlocksExceeded();
    error InvalidPriceCurveParameters();

    // Constants for bit manipulation
    uint256 private constant BLOCK_DURATION_BITS = 16;
    uint256 private constant SCALING_FACTOR_BITS = 240;

    // Bit positions
    uint256 private constant BLOCK_DURATION_SHIFT = SCALING_FACTOR_BITS;

    // Bit masks
    uint256 private constant SCALING_FACTOR_MASK = ((1 << SCALING_FACTOR_BITS) - 1);

    /**
     * @notice Creates a new PriceCurveElement from individual components.
     * @dev Packs the block duration (16 bits) and scaling factor (240 bits) into a single uint256.
     * The scaling factor represents the price multiplier for this segment (1e18 = neutral/100%).
     * @param blockDuration Duration in blocks for this curve segment (16 bits).
     * @param scalingFactor Scaling factor to apply during this segment (240 bits, 1e18 = neutral).
     * @return The packed PriceCurveElement containing both values.
     */
    function create(uint16 blockDuration, uint240 scalingFactor)
        internal
        pure
        returns (PriceCurveElement)
    {
        uint256 packed = (uint256(blockDuration) << BLOCK_DURATION_SHIFT) | uint256(scalingFactor);

        return PriceCurveElement.wrap(packed);
    }

    /**
     * @notice Extracts the block duration from a PriceCurveElement.
     * @dev Unpacks and shifts the upper 16 bits to retrieve the duration value.
     * @param self The PriceCurveElement to extract from.
     * @return The block duration as uint256 (originally 16 bits).
     */
    function getBlockDuration(PriceCurveElement self) internal pure returns (uint256) {
        return PriceCurveElement.unwrap(self) >> BLOCK_DURATION_SHIFT;
    }

    /**
     * @notice Extracts the scaling factor from a PriceCurveElement.
     * @dev Unpacks and masks the lower 240 bits to retrieve the scaling factor value.
     * @param self The PriceCurveElement to extract from.
     * @return The scaling factor as uint256 (originally 240 bits, 1e18 = neutral).
     */
    function getFillIncrease(PriceCurveElement self) internal pure returns (uint256) {
        return PriceCurveElement.unwrap(self) & SCALING_FACTOR_MASK;
    }

    /**
     * @notice Extracts both block duration and scaling factor from a PriceCurveElement in a single call.
     * @dev More gas-efficient than calling getBlockDuration and getFillIncrease separately.
     * Unpacks the uint256 by shifting for duration and masking for scaling factor.
     * @param self The PriceCurveElement to extract from.
     * @return blockDuration The block duration value (originally 16 bits).
     * @return scalingFactor The scaling factor value (originally 240 bits, 1e18 = neutral).
     */
    function getComponents(PriceCurveElement self)
        internal
        pure
        returns (uint256 blockDuration, uint256 scalingFactor)
    {
        uint256 value = PriceCurveElement.unwrap(self);

        blockDuration = value >> BLOCK_DURATION_SHIFT;
        scalingFactor = (value & SCALING_FACTOR_MASK);

        return (blockDuration, scalingFactor);
    }

    /**
     * @notice Combines a base price curve with a supplemental price curve from the adjuster.
     * @dev Applies the adjuster's supplemental curve by adding scaling factors and subtracting 1e18 to maintain
     * proper scaling: combinedScalingFactor = baseScalingFactor + supplementalScalingFactor - 1e18.
     * This allows the adjuster to modify prices dynamically while preserving the sponsor's base curve structure.
     * Validates that both curves scale in the same direction and that combined values don't overflow 240 bits.
     * If supplemental curve is shorter, base curve values are used for remaining segments.
     * @param parameters The base price curve array (calldata).
     * @param supplementalParameters The supplemental price curve array from the adjuster (calldata).
     * @return combinedParameters The combined price curve array with adjusted scaling factors.
     */
    function applySupplementalPriceCurve(
        uint256[] calldata parameters,
        uint256[] calldata supplementalParameters
    ) internal pure returns (uint256[] memory combinedParameters) {
        combinedParameters = new uint256[](parameters.length);
        uint256 errorBuffer = 0;
        uint256 applicationRange = parameters.length.min(supplementalParameters.length);
        for (uint256 i = 0; i < applicationRange; ++i) {
            (uint256 duration, uint256 scalingFactor) =
                getComponents(PriceCurveElement.wrap(parameters[i]));
            uint256 supplementalScalingFactor = supplementalParameters[i];

            uint256 combinedScalingFactor = scalingFactor + supplementalScalingFactor - 1e18;

            errorBuffer |= (!scalingFactor.sharesScalingDirection(supplementalScalingFactor))
            .asUint256() | (combinedScalingFactor > type(uint240).max).asUint256();

            combinedParameters[i] =
                PriceCurveElement.unwrap(create(uint16(duration), uint240(combinedScalingFactor)));
        }

        if (errorBuffer != 0) {
            revert InvalidPriceCurveParameters();
        }

        for (uint256 i = applicationRange; i < parameters.length; ++i) {
            combinedParameters[i] = parameters[i];
        }
    }

    /**
     * @notice Combines a base price curve with a supplemental price curve (memory version).
     * @dev Memory-based variant of applySupplementalPriceCurve for cases where curves are already in memory.
     * Applies the adjuster's supplemental curve by adding scaling factors and subtracting 1e18 to maintain
     * proper scaling: combinedScalingFactor = baseScalingFactor + supplementalScalingFactor - 1e18.
     * Validates that both curves scale in the same direction and that combined values don't overflow 240 bits.
     * If supplemental curve is shorter, base curve values are used for remaining segments.
     * @param parameters The base price curve array (memory).
     * @param supplementalParameters The supplemental price curve array from the adjuster (memory).
     * @return combinedParameters The combined price curve array with adjusted scaling factors.
     */
    function applyMemorySupplementalPriceCurve(
        uint256[] memory parameters,
        uint256[] memory supplementalParameters
    ) internal pure returns (uint256[] memory combinedParameters) {
        combinedParameters = new uint256[](parameters.length);
        uint256 errorBuffer = 0;
        uint256 applicationRange = parameters.length.min(supplementalParameters.length);
        for (uint256 i = 0; i < applicationRange; ++i) {
            (uint256 duration, uint256 scalingFactor) =
                getComponents(PriceCurveElement.wrap(parameters[i]));
            uint256 supplementalScalingFactor = supplementalParameters[i];

            uint256 combinedScalingFactor = scalingFactor + supplementalScalingFactor - 1e18;

            errorBuffer |= (!scalingFactor.sharesScalingDirection(supplementalScalingFactor))
            .asUint256() | (combinedScalingFactor > type(uint240).max).asUint256();

            combinedParameters[i] =
                PriceCurveElement.unwrap(create(uint16(duration), uint240(combinedScalingFactor)));
        }

        if (errorBuffer != 0) {
            revert InvalidPriceCurveParameters();
        }

        for (uint256 i = applicationRange; i < parameters.length; ++i) {
            combinedParameters[i] = parameters[i];
        }
    }

    /**
     * @notice Calculates the current scaling factor based on blocks elapsed since auction start.
     * @dev Processes the price curve array sequentially to determine the current price based on block progression.
     * Supports linear interpolation between discrete curve points for gradual price transitions, and zero-duration
     * segments that enable instant price jumps at specific blocks. The final segment defaults to 1e18 (neutral)
     * if the auction extends beyond the specified curve duration. Reverts if blocks elapsed exceeds total curve duration.
     * @param parameters Array of PriceCurveElements defining the curve segments.
     * @param blocksPassed Number of blocks elapsed since the auction start (targetBlock).
     * @return currentScalingFactor The calculated scaling factor for the current block (1e18 = neutral).
     */
    function getCalculatedValues(uint256[] memory parameters, uint256 blocksPassed)
        internal
        pure
        returns (uint256 currentScalingFactor)
    {
        // Check if there are no parameters
        if (parameters.length == 0) {
            return (1e18);
        }

        uint256 blocksCounted = 0;
        bool hasPassedZeroDuration = false;

        // Process each parameter segment in a single pass
        for (uint256 i = 0; i < parameters.length; i++) {
            // Extract values from current parameter
            (uint256 duration, uint256 scalingFactor) =
                getComponents(PriceCurveElement.wrap(parameters[i]));

            // Special handling for zero duration
            if (duration == 0) {
                // If we've reached or passed this zero duration point
                if (blocksPassed >= blocksCounted) {
                    // Update values to the zero duration values
                    currentScalingFactor = scalingFactor;
                    hasPassedZeroDuration = true;

                    // If we're exactly at this point, return these values
                    if (blocksPassed == blocksCounted) {
                        return scalingFactor;
                    }
                }

                // Continue to the next segment (zero duration doesn't add to blocksCounted)
                continue;
            }

            // If blocksPassed is in this segment
            if (blocksPassed < blocksCounted + duration) {
                // For regular segments, we need to handle based on whether we've passed a zero duration
                if (
                    hasPassedZeroDuration
                        && getBlockDuration(PriceCurveElement.wrap(parameters[i - 1])) == 0
                ) {
                    // We're in a segment right after a zero duration - start interpolation from zero duration values
                    (, uint256 zeroDurationScalingFactor) =
                        getComponents(PriceCurveElement.wrap(parameters[i - 1]));

                    if (!zeroDurationScalingFactor.sharesScalingDirection(scalingFactor)) {
                        revert InvalidPriceCurveParameters();
                    }

                    // Interpolate from zero duration values to current segment values
                    currentScalingFactor = _locateCurrentAmount(
                        zeroDurationScalingFactor,
                        scalingFactor,
                        blocksCounted,
                        blocksPassed,
                        blocksCounted + duration,
                        zeroDurationScalingFactor > 1e18 // Round up for fillIncrease, down for claimDecrease
                    );
                } else {
                    // Standard interpolation between current and next segment
                    uint256 endScalingFactor;

                    if (i + 1 < parameters.length) {
                        // Next segment determines the target values
                        (, endScalingFactor) =
                            getComponents(PriceCurveElement.wrap(parameters[i + 1]));
                    } else {
                        // Last segment ends at 1e18
                        // For exact-in, defaults to decaying fill amount to minFillAmount that the sponsor is willing to accept
                        // For exact-out, default to increasing claim amounts to maximumClaimAmounts that the sponsor is willing to pay
                        endScalingFactor = 1e18;
                    }

                    if (!scalingFactor.sharesScalingDirection(endScalingFactor)) {
                        revert InvalidPriceCurveParameters();
                    }

                    // Use the provided interpolation function
                    currentScalingFactor = _locateCurrentAmount(
                        scalingFactor,
                        endScalingFactor,
                        blocksCounted,
                        blocksPassed,
                        blocksCounted + duration,
                        scalingFactor > 1e18 // Round up for fillIncrease, down for claimDecrease
                    );
                }

                return (currentScalingFactor);
            }

            // We've passed this segment, update our tracking
            blocksCounted += duration;
        }

        // If we went through all segments and exceeded total blocks, revert
        if (blocksPassed >= blocksCounted) {
            revert PriceCurveBlocksExceeded();
        }

        // This should never be reached
        return (0);
    }

    /**
     * @notice Performs linear interpolation to derive the current scaling factor between two points.
     * @dev Private pure function that interpolates between start and end amounts based on block progression.
     * If start and end amounts are equal, returns the end amount without calculation. Otherwise, performs
     * weighted interpolation: ((startAmount × remaining) + (endAmount × elapsed)) / duration.
     * The roundUp parameter controls rounding direction: up for exact-in mode (increasing fills), down for
     * exact-out mode (decreasing claims).
     * IMPORTANT: This function expects startBlock ≤ currentBlock < endBlock; violating this causes underflow.
     * @param startAmount The starting scaling factor value at the segment start.
     * @param endAmount The ending scaling factor value at the segment end.
     * @param startBlock The block number where this segment begins.
     * @param currentBlock The current block number within the segment.
     * @param endBlock The block number where this segment ends.
     * @param roundUp Whether to round up (true for exact-in) or down (false for exact-out).
     * @return amount The interpolated scaling factor for the current block.
     */
    function _locateCurrentAmount(
        uint256 startAmount,
        uint256 endAmount,
        uint256 startBlock,
        uint256 currentBlock,
        uint256 endBlock,
        bool roundUp
    ) private pure returns (uint256 amount) {
        // Only modify end amount if it doesn't already equal start amount.
        if (startAmount != endAmount) {
            // Declare variables to derive in the subsequent unchecked scope.
            uint256 duration;
            uint256 elapsed;
            uint256 remaining;

            // Skip underflow checks as startBlock <= _getBlockNumberish() < endBlock.
            unchecked {
                // Derive block duration and place it on the stack.
                duration = endBlock - startBlock;

                // Derive blocks elapsed since the start block & place on stack.
                elapsed = currentBlock - startBlock;

                // Derive blocks remaining until the end block & place on stack.
                remaining = duration - elapsed;
            }

            // Aggregate new amounts weighted by blocks with rounding factor.
            uint256 totalBeforeDivision = ((startAmount * remaining) + (endAmount * elapsed));

            // Use assembly to combine operations and skip divide-by-zero check.
            assembly {
                // Multiply by iszero(iszero(totalBeforeDivision)) to ensure
                // amount is set to zero if totalBeforeDivision is zero,
                // as intermediate overflow can occur if it is zero.
                amount := mul(
                    iszero(iszero(totalBeforeDivision)),
                    // Subtract 1 from the numerator and add 1 to the result
                    // if roundUp is true to get proper rounding direction.
                    // Division is performed with no zero check as duration
                    // cannot be zero as long as startBlock < endBlock.
                    add(div(sub(totalBeforeDivision, roundUp), duration), roundUp)
                )
            }

            // Return the current amount.
            return amount;
        }

        // Return the original amount as startAmount == endAmount.
        return endAmount;
    }

    /**
     * @notice Validates that two scaling factors scale in the same direction (both exact-in or both exact-out).
     * @dev Checks whether two values are on the same side of the neutral threshold (1e18), or if either equals 1e18.
     * Returns true if:
     * - Either value equals 1e18 (neutral scaling)
     * - Both values are > 1e18 (both exact-in mode)
     * - Both values are < 1e18 (both exact-out mode)
     * Returns false only if one value is strictly < 1e18 and the other strictly > 1e18, indicating incompatible
     * scaling directions. This validation ensures price curves don't switch between exact-in and exact-out modes.
     * @param a The first scaling factor to check.
     * @param b The second scaling factor to check.
     * @return result True if compatible scaling directions; false if incompatible (one exact-in, one exact-out).
     */
    function sharesScalingDirection(uint256 a, uint256 b) internal pure returns (bool result) {
        assembly {
            let threshold := 1000000000000000000

            result := or(
                or(eq(a, threshold), eq(b, threshold)), // either value is 1e18
                eq(gt(a, threshold), gt(b, threshold)) // both values are either greater or less than 1e18
            )
        }
    }
}
