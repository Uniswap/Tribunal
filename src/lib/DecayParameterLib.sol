// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title DecayParameter
 * @dev Custom type for decay parameters with bit-packed values
 */
type DecayParameter is uint256;

/**
 * @title DecayParameterLib
 * @dev Library for the DecayParameter type which packs three values:
 *      - blockDuration (16 bits): Duration in blocks
 *      - fillIncrease (120 bits): Amount to increase on fill
 *      - claimDecrease (120 bits): Amount to decrease on claim
 */
library DecayParameterLib {
    error DecayBlocksExceeded();

    // Constants for bit manipulation
    uint256 private constant FILL_INCREASE_BITS = 120;
    uint256 private constant CLAIM_DECREASE_BITS = 120;

    // Bit positions
    uint256 private constant FILL_INCREASE_SHIFT = CLAIM_DECREASE_BITS;
    uint256 private constant BLOCK_DURATION_SHIFT = CLAIM_DECREASE_BITS + FILL_INCREASE_BITS;

    // Bit masks
    uint256 private constant CLAIM_DECREASE_MASK = ((1 << CLAIM_DECREASE_BITS) - 1);
    uint256 private constant FILL_INCREASE_MASK =
        ((1 << FILL_INCREASE_BITS) - 1) << FILL_INCREASE_SHIFT;

    /**
     * @dev Create a new DecayParameter from individual components
     * @param blockDuration Duration in blocks (16 bits)
     * @param fillIncrease Amount to increase on fill (120 bits)
     * @param claimDecrease Amount to decrease on claim (120 bits)
     * @return The packed DecayParameter
     */
    function create(uint16 blockDuration, uint120 fillIncrease, uint120 claimDecrease)
        internal
        pure
        returns (DecayParameter)
    {
        uint256 packed = uint256(claimDecrease);
        packed |= uint256(fillIncrease) << FILL_INCREASE_SHIFT;
        packed |= uint256(blockDuration) << BLOCK_DURATION_SHIFT;

        return DecayParameter.wrap(packed);
    }

    /**
     * @dev Get the blockDuration value
     * @param self The DecayParameter
     * @return The blockDuration as uint256
     */
    function getBlockDuration(DecayParameter self) internal pure returns (uint256) {
        return DecayParameter.unwrap(self) >> BLOCK_DURATION_SHIFT;
    }

    /**
     * @dev Get the fillIncrease value
     * @param self The DecayParameter
     * @return The fillIncrease as uint256
     */
    function getFillIncrease(DecayParameter self) internal pure returns (uint256) {
        return (DecayParameter.unwrap(self) & FILL_INCREASE_MASK) >> FILL_INCREASE_SHIFT;
    }

    /**
     * @dev Get the claimDecrease value
     * @param self The DecayParameter
     * @return The claimDecrease as uint256
     */
    function getClaimDecrease(DecayParameter self) internal pure returns (uint256) {
        return DecayParameter.unwrap(self) & CLAIM_DECREASE_MASK;
    }

    /**
     * @dev Get all components at once
     * @param self The DecayParameter
     * @return blockDuration The blockDuration value
     * @return fillIncrease The fillIncrease value
     * @return claimDecrease The claimDecrease value
     */
    function getComponents(DecayParameter self)
        internal
        pure
        returns (uint256 blockDuration, uint256 fillIncrease, uint256 claimDecrease)
    {
        uint256 value = DecayParameter.unwrap(self);

        blockDuration = value >> BLOCK_DURATION_SHIFT;
        fillIncrease = (value & FILL_INCREASE_MASK) >> FILL_INCREASE_SHIFT;
        claimDecrease = value & CLAIM_DECREASE_MASK;

        return (blockDuration, fillIncrease, claimDecrease);
    }

    /**
     * @dev Calculate the current fill increase and claim decrease values based on block progression
     * @param parameters Array of DecayParameters to process sequentially
     * @param blocksPassed Number of blocks that have already passed
     * @return currentFillIncrease The current fill increase value
     * @return currentClaimDecrease The current claim decrease value
     */
    function getCalculatedValues(uint256[] calldata parameters, uint256 blocksPassed)
        internal
        pure
        returns (uint256 currentFillIncrease, uint256 currentClaimDecrease)
    {
        // Check if there are no parameters
        if (parameters.length == 0) {
            return (0, 0);
        }

        uint256 blocksCounted = 0;
        bool hasPassedZeroDuration = false;

        // Process each parameter segment in a single pass
        for (uint256 i = 0; i < parameters.length; i++) {
            // Extract values from current parameter
            (uint256 duration, uint256 fillIncrease, uint256 claimDecrease) =
                getComponents(DecayParameter.wrap(parameters[i]));

            // Special handling for zero duration
            if (duration == 0) {
                // If we've reached or passed this zero duration point
                if (blocksPassed >= blocksCounted) {
                    // Update values to the zero duration values
                    currentFillIncrease = fillIncrease;
                    currentClaimDecrease = claimDecrease;
                    hasPassedZeroDuration = true;

                    // If we're exactly at this point, return these values
                    if (blocksPassed == blocksCounted) {
                        return (fillIncrease, claimDecrease);
                    }
                }

                // Continue to the next segment (zero duration doesn't add to blocksCounted)
                continue;
            }

            // If blocksPassed is in this segment
            if (blocksPassed < blocksCounted + duration) {
                // For regular segments, we need to handle based on whether we've passed a zero duration
                if (
                    hasPassedZeroDuration && i > 0
                        && getBlockDuration(DecayParameter.wrap(parameters[i - 1])) == 0
                ) {
                    // We're in a segment right after a zero duration - start interpolation from zero duration values
                    (, uint256 zeroDurationFill, uint256 zeroDurationClaim) =
                        getComponents(DecayParameter.wrap(parameters[i - 1]));

                    // Interpolate from zero duration values to current segment values
                    currentFillIncrease = _locateCurrentAmount(
                        zeroDurationFill,
                        fillIncrease,
                        blocksCounted,
                        blocksPassed,
                        blocksCounted + duration,
                        true // Round up for fillIncrease
                    );

                    currentClaimDecrease = _locateCurrentAmount(
                        zeroDurationClaim,
                        claimDecrease,
                        blocksCounted,
                        blocksPassed,
                        blocksCounted + duration,
                        false // Round down for claimDecrease
                    );
                } else {
                    // Standard interpolation between current and next segment
                    uint256 endFillIncrease;
                    uint256 endClaimDecrease;

                    if (i + 1 < parameters.length) {
                        // Next segment determines the target values
                        (, endFillIncrease, endClaimDecrease) =
                            getComponents(DecayParameter.wrap(parameters[i + 1]));
                    } else {
                        // Last segment ends at zero
                        endFillIncrease = 0;
                        endClaimDecrease = 0;
                    }

                    // Use the provided interpolation function
                    currentFillIncrease = _locateCurrentAmount(
                        fillIncrease,
                        endFillIncrease,
                        blocksCounted,
                        blocksPassed,
                        blocksCounted + duration,
                        true // Round up for fillIncrease
                    );

                    currentClaimDecrease = _locateCurrentAmount(
                        claimDecrease,
                        endClaimDecrease,
                        blocksCounted,
                        blocksPassed,
                        blocksCounted + duration,
                        false // Round down for claimDecrease
                    );
                }

                return (currentFillIncrease, currentClaimDecrease);
            }

            // We've passed this segment, update our tracking
            blocksCounted += duration;
        }

        // If we went through all segments and exceeded total blocks, revert
        if (blocksPassed >= blocksCounted) {
            revert DecayBlocksExceeded();
        }

        // This should never be reached
        return (0, 0);
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
}
