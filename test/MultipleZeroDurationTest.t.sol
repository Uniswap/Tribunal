// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PriceCurveLib, PriceCurveElement} from "../src/lib/PriceCurveLib.sol";
import {PriceCurveTestHelper} from "./helpers/PriceCurveTestHelper.sol";

/**
 * @title MultipleZeroDurationTest
 * @notice Comprehensive test to verify the behavior of multiple consecutive zero-duration elements
 * @dev Confirms that:
 *      1. At the exact block, the FIRST zero-duration element is used
 *      2. For subsequent interpolation, the LAST zero-duration element is used as starting point
 */
contract MultipleZeroDurationTest is Test {
    using PriceCurveLib for uint256[];

    PriceCurveTestHelper public helper;

    function setUp() public {
        helper = new PriceCurveTestHelper();
    }

    /**
     * @notice Test the actual behavior of multiple consecutive zero-duration elements
     * @dev This test verifies the documentation update showing that:
     *      - At block 10: returns the first zero-duration (1.5e18)
     *      - At blocks 11-20: interpolates from the last zero-duration (1.3e18) to 1.0e18
     */
    function test_MultipleConsecutiveZeroDuration_DetailedBehavior() public pure {
        uint256[] memory priceCurve = new uint256[](4);
        priceCurve[0] = (10 << 240) | uint256(1.2e18); // 10 blocks at 1.2x
        priceCurve[1] = (0 << 240) | uint256(1.5e18); // First zero-duration at block 10
        priceCurve[2] = (0 << 240) | uint256(1.3e18); // Second zero-duration at block 10
        priceCurve[3] = (10 << 240) | uint256(1e18); // 10 blocks ending at 1x

        // Test interpolation during first segment (blocks 0-9)
        // Should interpolate from 1.2x towards 1.5x (the next element)
        uint256 scalingAtBlock0 = priceCurve.getCalculatedValues(0);
        assertEq(scalingAtBlock0, 1.2e18, "Block 0: should be 1.2x");

        uint256 scalingAtBlock5 = priceCurve.getCalculatedValues(5);
        // Expected: 1.2 + (1.5 - 1.2) * (5/10) = 1.35
        assertEq(scalingAtBlock5, 1.35e18, "Block 5: should interpolate to 1.35x");

        uint256 scalingAtBlock9 = priceCurve.getCalculatedValues(9);
        // Expected: 1.2 + (1.5 - 1.2) * (9/10) = 1.47
        assertEq(scalingAtBlock9, 1.47e18, "Block 9: should be close to 1.5x");

        // CRITICAL TEST 1: At block 10, should return FIRST zero-duration element
        uint256 scalingAtBlock10 = priceCurve.getCalculatedValues(10);
        assertEq(scalingAtBlock10, 1.5e18, "Block 10: should use FIRST zero-duration (1.5x)");

        // CRITICAL TEST 2: After block 10, should interpolate from LAST zero-duration element
        // The implementation uses parameters[i-1] when hasPassedZeroDuration is true
        // This means it uses priceCurve[2] (1.3e18) as the starting point

        uint256 scalingAtBlock11 = priceCurve.getCalculatedValues(11);
        // Expected: 1.3 - (1.3 - 1.0) * (1/10) = 1.27
        assertEq(
            scalingAtBlock11, 1.27e18, "Block 11: should interpolate from LAST zero-duration (1.3x)"
        );

        uint256 scalingAtBlock15 = priceCurve.getCalculatedValues(15);
        // Expected: 1.3 - (1.3 - 1.0) * (5/10) = 1.15
        assertEq(scalingAtBlock15, 1.15e18, "Block 15: midway from 1.3x to 1.0x");

        uint256 scalingAtBlock19 = priceCurve.getCalculatedValues(19);
        // Expected: 1.3 - (1.3 - 1.0) * (9/10) = 1.03
        assertEq(scalingAtBlock19, 1.03e18, "Block 19: close to 1.0x");
    }

    /**
     * @notice Test with three consecutive zero-duration elements
     * @dev Verifies that with 3 zero-duration elements:
     *      - At the exact block: first is used
     *      - For interpolation: last (third) is used
     */
    function test_ThreeConsecutiveZeroDuration() public pure {
        uint256[] memory priceCurve = new uint256[](5);
        priceCurve[0] = (10 << 240) | uint256(1.1e18); // 10 blocks at 1.1x
        priceCurve[1] = (0 << 240) | uint256(1.6e18); // First zero-duration
        priceCurve[2] = (0 << 240) | uint256(1.4e18); // Second zero-duration
        priceCurve[3] = (0 << 240) | uint256(1.2e18); // Third zero-duration (last)
        priceCurve[4] = (10 << 240) | uint256(1e18); // 10 blocks to 1x

        // At block 10: should return FIRST zero-duration
        uint256 scalingAtBlock10 = priceCurve.getCalculatedValues(10);
        assertEq(scalingAtBlock10, 1.6e18, "Should use first zero-duration (1.6x)");

        // After block 10: should interpolate from LAST (third) zero-duration
        uint256 scalingAtBlock11 = priceCurve.getCalculatedValues(11);
        // Expected: 1.2 - (1.2 - 1.0) * (1/10) = 1.18
        assertEq(scalingAtBlock11, 1.18e18, "Should interpolate from third zero-duration (1.2x)");

        uint256 scalingAtBlock15 = priceCurve.getCalculatedValues(15);
        // Expected: 1.2 - (1.2 - 1.0) * (5/10) = 1.1
        assertEq(scalingAtBlock15, 1.1e18, "Midway from 1.2x to 1.0x");
    }

    /**
     * @notice Test zero-duration elements at different positions
     * @dev Verifies that multiple zero-duration elements only affect the same block position
     */
    function test_ZeroDurationAtDifferentPositions() public pure {
        uint256[] memory priceCurve = new uint256[](5);
        priceCurve[0] = (10 << 240) | uint256(1.2e18); // 10 blocks
        priceCurve[1] = (0 << 240) | uint256(1.5e18); // Zero-duration at block 10
        priceCurve[2] = (10 << 240) | uint256(1.3e18); // 10 blocks
        priceCurve[3] = (0 << 240) | uint256(1.4e18); // Zero-duration at block 20
        priceCurve[4] = (10 << 240) | uint256(1e18); // 10 blocks

        // At block 10: first zero-duration
        assertEq(priceCurve.getCalculatedValues(10), 1.5e18, "Block 10 zero-duration");

        // At block 15: interpolating in segment 2
        uint256 scalingAtBlock15 = priceCurve.getCalculatedValues(15);
        // After a zero-duration element, the implementation interpolates from the zero-duration value
        // to the current segment's scaling factor (NOT to the next element)
        // Segment 2 has scaling factor 1.3, so we interpolate from 1.5 (zero-duration) to 1.3
        // At block 15 (5 blocks into 10-block segment): 1.5 - (1.5 - 1.3) * (5/10) = 1.4
        assertEq(scalingAtBlock15, 1.4e18, "Block 15 interpolation");

        // At block 20: second zero-duration
        assertEq(priceCurve.getCalculatedValues(20), 1.4e18, "Block 20 zero-duration");

        // At block 25: interpolating in final segment
        uint256 scalingAtBlock25 = priceCurve.getCalculatedValues(25);
        // Interpolates from 1.4 (zero-duration at block 20) to 1.0 (segment 4's end value)
        // Expected: 1.4 - (1.4 - 1.0) * (5/10) = 1.2
        assertEq(scalingAtBlock25, 1.2e18, "Block 25 interpolation");
    }

    /**
     * @notice Test edge case with all zero-duration elements
     * @dev Verifies behavior when curve consists only of zero-duration elements
     */
    function test_OnlyZeroDurationElements() public {
        uint256[] memory priceCurve = new uint256[](3);
        priceCurve[0] = (0 << 240) | uint256(1.5e18); // First zero-duration at block 0
        priceCurve[1] = (0 << 240) | uint256(1.3e18); // Second zero-duration at block 0
        priceCurve[2] = (0 << 240) | uint256(1.1e18); // Third zero-duration at block 0

        // At block 0: should return first zero-duration
        uint256 scalingAtBlock0 = priceCurve.getCalculatedValues(0);
        assertEq(scalingAtBlock0, 1.5e18, "Block 0: should use first zero-duration");

        // Any block after 0 should revert (no duration to interpolate)
        // The curve has no actual duration, so accessing beyond block 0 exceeds it
        // Using helper to properly capture the revert
        vm.expectRevert(PriceCurveLib.PriceCurveBlocksExceeded.selector);
        helper.getCalculatedValues(priceCurve, 1);
    }

    /**
     * @notice Test practical use case: step function with instant price change
     * @dev Shows how multiple zero-duration elements can create complex price dynamics
     */
    function test_PracticalUseCase_StepWithInstantChange() public pure {
        uint256[] memory priceCurve = new uint256[](4);
        priceCurve[0] = (50 << 240) | uint256(2e18); // Start high at 2x for 50 blocks
        priceCurve[1] = (0 << 240) | uint256(1.2e18); // Instant drop to 1.2x for display
        priceCurve[2] = (0 << 240) | uint256(1.5e18); // But actually start next phase at 1.5x
        priceCurve[3] = (50 << 240) | uint256(1e18); // Decay to 1x over 50 blocks

        // During first segment
        uint256 scalingAtBlock25 = priceCurve.getCalculatedValues(25);
        // Expected: 2.0 - (2.0 - 1.2) * (25/50) = 1.6
        assertEq(scalingAtBlock25, 1.6e18, "Block 25: interpolating to instant drop point");

        // At block 50: shows the instant drop price
        uint256 scalingAtBlock50 = priceCurve.getCalculatedValues(50);
        assertEq(scalingAtBlock50, 1.2e18, "Block 50: instant drop to 1.2x (first zero-duration)");

        // After block 50: interpolates from different starting point
        uint256 scalingAtBlock51 = priceCurve.getCalculatedValues(51);
        // Expected: 1.5 - (1.5 - 1.0) * (1/50) = 1.49
        assertEq(
            scalingAtBlock51, 1.49e18, "Block 51: interpolating from 1.5x (last zero-duration)"
        );

        uint256 scalingAtBlock75 = priceCurve.getCalculatedValues(75);
        // Expected: 1.5 - (1.5 - 1.0) * (25/50) = 1.25
        assertEq(scalingAtBlock75, 1.25e18, "Block 75: midway from 1.5x to 1.0x");
    }
}
