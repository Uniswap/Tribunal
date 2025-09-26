// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {EfficiencyLib} from "the-compact/src/lib/EfficiencyLib.sol";

/**
 * @title PriceCurveLib
 * @dev Custom type for price curve parameters with bit-packed values
 */
type PriceCurveElement is uint256;

/**
 * @title PriceCurveLib
 * @custom:security-contact security@uniswap.org
 * @dev Library for the DecayParameter type which packs three values:
 *      - blockDuration (16 bits): Duration in blocks
 *      - scalingFactor (240 bits): additional scaling factor to apply to fill increase or claim decrease
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
     * @dev Create a new PriceCurveElement from individual components
     * @param blockDuration Duration in blocks (16 bits)
     * @param scalingFactor Additional scaling factor to apply to fill increase or claim decrease
     * @return The packed PriceCurveElement
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
     * @dev Get the blockDuration value
     * @param self The PriceCurveElement
     * @return The blockDuration as uint256
     */
    function getBlockDuration(PriceCurveElement self) internal pure returns (uint256) {
        return PriceCurveElement.unwrap(self) >> BLOCK_DURATION_SHIFT;
    }

    /**
     * @dev Get the scalingFactor value
     * @param self The PriceCurveElement
     * @return The scaling factor as uint256
     */
    function getFillIncrease(PriceCurveElement self) internal pure returns (uint256) {
        return PriceCurveElement.unwrap(self) & SCALING_FACTOR_MASK;
    }

    /**
     * @dev Get all components at once
     * @param self The PriceCurve element
     * @return blockDuration The blockDuration value
     * @return scalingFactor The scaling factor as uint256
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
     * @dev Calculate the current scaling factor value based on block progression
     * @param parameters Array of DecayParameters to process sequentially
     * @param blocksPassed Number of blocks that have already passed
     * @return currentScalingFactor The current scaling factor value
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
     * @dev Private pure function to derive the current amount of a given item
     *      based on the current price, the starting price, and the ending
     *      price. If the start and end prices differ, the current price will be
     *      interpolated on a linear basis. Note that this function expects that
     *      the startBlock parameter is not greater than the current block number
     *      and that the endBlock parameter is greater than the current block
     *      number. If this condition is not upheld, duration / elapsed / remaining
     *      variables will underflow.
     *
     * @param startAmount  The starting amount of the item.
     * @param endAmount    The ending amount of the item.
     * @param startBlock   The indicated starting block.
     * @param currentBlock The indicated current block.
     * @param endBlock     The indicated end block.
     * @param roundUp      A boolean indicating whether the resultant amount
     *                     should be rounded up or down.
     *
     * @return amount The current amount.
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
                amount :=
                    mul(
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
     * @notice Checks whether two values are on the same side of the threshold (1e18),
     *         or if either value is exactly equal to 1e18.
     * @dev Returns false only if one value is strictly less than 1e18 and the other strictly greater.
     * @param a The first value to check.
     * @param b The second value to check.
     * @return result True if values are equal to 1e18 or both on the same side of it; false otherwise.
     */
    function sharesScalingDirection(uint256 a, uint256 b) internal pure returns (bool result) {
        assembly {
            let threshold := 1000000000000000000

            result :=
                or(
                    or(eq(a, threshold), eq(b, threshold)), // either value is 1e18
                    eq(gt(a, threshold), gt(b, threshold)) // both values are either greater or less than 1e18
                )
        }
    }
}
