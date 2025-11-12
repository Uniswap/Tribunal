// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PriceCurveLib, PriceCurveElement} from "../src/lib/PriceCurveLib.sol";
import {MockPriceCurveLib} from "./mocks/MockPriceCurveLib.sol";

/**
 * @title PriceCurveLibCoverageTest
 * @dev Comprehensive tests to achieve 100% coverage of PriceCurveLib
 *      Focuses on uncovered code paths identified in lcov.info
 */
contract PriceCurveLibCoverageTest is Test {
    MockPriceCurveLib public mock;

    function setUp() public {
        mock = new MockPriceCurveLib();
    }

    // ============ Memory Version Tests ============
    // Tests for applyMemorySupplementalPriceCurve (currently 0% coverage)

    function test_applyMemorySupplementalPriceCurve_Success() public view {
        uint256[] memory baseCurve = new uint256[](2);
        baseCurve[0] = (100 << 240) | uint256(1.2e18);
        baseCurve[1] = (50 << 240) | uint256(1.1e18);

        uint256[] memory supplemental = new uint256[](2);
        supplemental[0] = 1.1e18; // Additional 0.1 scaling
        supplemental[1] = 1.05e18; // Additional 0.05 scaling

        uint256[] memory combined = mock.applyMemorySupplementalPriceCurve(baseCurve, supplemental);

        assertEq(combined.length, 2, "Combined array should have correct length");

        // First element: 1.2 + 1.1 - 1.0 = 1.3
        (uint256 duration0, uint256 scaling0) =
            mock.getComponents(PriceCurveElement.wrap(combined[0]));
        assertEq(duration0, 100, "Duration should be preserved");
        assertEq(scaling0, 1.3e18, "Scaling should be combined correctly");

        // Second element: 1.1 + 1.05 - 1.0 = 1.15
        (uint256 duration1, uint256 scaling1) =
            mock.getComponents(PriceCurveElement.wrap(combined[1]));
        assertEq(duration1, 50, "Duration should be preserved");
        assertEq(scaling1, 1.15e18, "Scaling should be combined correctly");
    }

    function test_applyMemorySupplementalPriceCurve_PartialApplication() public view {
        // Base curve has 3 elements, supplemental has only 1
        uint256[] memory baseCurve = new uint256[](3);
        baseCurve[0] = (100 << 240) | uint256(1.2e18);
        baseCurve[1] = (50 << 240) | uint256(1.1e18);
        baseCurve[2] = (30 << 240) | uint256(1.05e18);

        uint256[] memory supplemental = new uint256[](1);
        supplemental[0] = 1.1e18;

        uint256[] memory combined = mock.applyMemorySupplementalPriceCurve(baseCurve, supplemental);

        assertEq(combined.length, 3, "Combined array should preserve base length");

        // First element should be combined
        (, uint256 scaling0) = mock.getComponents(PriceCurveElement.wrap(combined[0]));
        assertEq(scaling0, 1.3e18, "First element should be combined");

        // Second and third should be unchanged
        (, uint256 scaling1) = mock.getComponents(PriceCurveElement.wrap(combined[1]));
        assertEq(scaling1, 1.1e18, "Second element should be unchanged");

        (, uint256 scaling2) = mock.getComponents(PriceCurveElement.wrap(combined[2]));
        assertEq(scaling2, 1.05e18, "Third element should be unchanged");
    }

    function test_applyMemorySupplementalPriceCurve_InvalidDirection() public {
        uint256[] memory baseCurve = new uint256[](1);
        baseCurve[0] = (100 << 240) | uint256(1.2e18); // >1e18 (increase)

        uint256[] memory supplemental = new uint256[](1);
        supplemental[0] = 0.9e18; // <1e18 (decrease) - INVALID!

        vm.expectRevert(PriceCurveLib.InvalidPriceCurveParameters.selector);
        mock.applyMemorySupplementalPriceCurve(baseCurve, supplemental);
    }

    function test_applyMemorySupplementalPriceCurve_ExceedsMaxScaling() public {
        uint256[] memory baseCurve = new uint256[](1);
        // Use a very large base scaling factor
        baseCurve[0] = (100 << 240) | uint256(type(uint240).max);

        uint256[] memory supplemental = new uint256[](1);
        supplemental[0] = 1.1e18; // Adding this would overflow uint240

        vm.expectRevert(PriceCurveLib.InvalidPriceCurveParameters.selector);
        mock.applyMemorySupplementalPriceCurve(baseCurve, supplemental);
    }

    function test_applyMemorySupplementalPriceCurve_BaseWithNeutral() public view {
        // Test combining when base is 1e18 (neutral)
        uint256[] memory baseCurve = new uint256[](1);
        baseCurve[0] = (100 << 240) | uint256(1e18); // Neutral

        uint256[] memory supplemental = new uint256[](1);
        supplemental[0] = 1.2e18; // Increase

        uint256[] memory combined = mock.applyMemorySupplementalPriceCurve(baseCurve, supplemental);

        (, uint256 scaling) = mock.getComponents(PriceCurveElement.wrap(combined[0]));
        // 1e18 + 1.2e18 - 1e18 = 1.2e18
        assertEq(scaling, 1.2e18, "Should handle neutral base correctly");
    }

    function test_applyMemorySupplementalPriceCurve_SupplementalWithNeutral() public view {
        // Test combining when supplemental is 1e18 (neutral)
        uint256[] memory baseCurve = new uint256[](1);
        baseCurve[0] = (100 << 240) | uint256(1.2e18);

        uint256[] memory supplemental = new uint256[](1);
        supplemental[0] = 1e18; // Neutral - no change

        uint256[] memory combined = mock.applyMemorySupplementalPriceCurve(baseCurve, supplemental);

        (, uint256 scaling) = mock.getComponents(PriceCurveElement.wrap(combined[0]));
        // 1.2e18 + 1e18 - 1e18 = 1.2e18
        assertEq(scaling, 1.2e18, "Should handle neutral supplemental correctly");
    }

    // ============ Calldata Version Error Tests ============
    // Tests for error paths in applySupplementalPriceCurve (lines 99-108)

    function test_applySupplementalPriceCurve_InvalidDirection() public {
        uint256[] memory baseCurve = new uint256[](1);
        baseCurve[0] = (100 << 240) | uint256(1.2e18); // >1e18 (increase)

        uint256[] memory supplemental = new uint256[](1);
        supplemental[0] = 0.9e18; // <1e18 (decrease) - INVALID!

        vm.expectRevert(PriceCurveLib.InvalidPriceCurveParameters.selector);
        mock.applySupplementalPriceCurve(baseCurve, supplemental);
    }

    function test_applySupplementalPriceCurve_ExceedsMaxScaling() public {
        uint256[] memory baseCurve = new uint256[](1);
        // Use a very large base scaling factor
        baseCurve[0] = (100 << 240) | uint256(type(uint240).max);

        uint256[] memory supplemental = new uint256[](1);
        supplemental[0] = 1.1e18; // Adding this would overflow uint240

        vm.expectRevert(PriceCurveLib.InvalidPriceCurveParameters.selector);
        mock.applySupplementalPriceCurve(baseCurve, supplemental);
    }

    function test_applySupplementalPriceCurve_BothInvalidConditions() public {
        // Test when both error conditions are true (direction mismatch AND overflow)
        uint256[] memory baseCurve = new uint256[](2);
        baseCurve[0] = (100 << 240) | uint256(1.2e18); // >1e18
        baseCurve[1] = (50 << 240) | uint256(type(uint240).max); // Very large

        uint256[] memory supplemental = new uint256[](2);
        supplemental[0] = 0.9e18; // <1e18 - direction mismatch
        supplemental[1] = 1.1e18; // Would overflow

        vm.expectRevert(PriceCurveLib.InvalidPriceCurveParameters.selector);
        mock.applySupplementalPriceCurve(baseCurve, supplemental);
    }

    // ============ Invalid Scaling Direction in getCalculatedValues ============
    // Tests for lines 205-206 (InvalidPriceCurveParameters in zero-duration interpolation)

    function test_getCalculatedValues_InvalidDirectionAfterZeroDuration() public {
        // Create a curve with zero duration followed by a segment with opposite direction
        uint256[] memory priceCurve = new uint256[](2);
        priceCurve[0] = (0 << 240) | uint256(1.5e18); // Zero duration at 1.5x (increase)
        priceCurve[1] = (10 << 240) | uint256(0.8e18); // Decrease - INVALID after increase!

        // Try to access a block in the second segment (which should trigger the error)
        vm.expectRevert(PriceCurveLib.InvalidPriceCurveParameters.selector);
        mock.getCalculatedValues(priceCurve, 5);
    }

    function test_getCalculatedValues_InvalidDirectionBetweenSegments() public {
        // Create a curve where adjacent segments have opposite directions
        uint256[] memory priceCurve = new uint256[](2);
        priceCurve[0] = (10 << 240) | uint256(1.5e18); // Increase (>1e18)
        priceCurve[1] = (10 << 240) | uint256(0.5e18); // Decrease (<1e18) - INVALID!

        // Access block 5 which should interpolate from segment 0 toward segment 1
        vm.expectRevert(PriceCurveLib.InvalidPriceCurveParameters.selector);
        mock.getCalculatedValues(priceCurve, 5);
    }

    function test_getCalculatedValues_InvalidDirectionLastSegmentToNeutral() public view {
        // Last segment should interpolate to 1e18, but if starting value has wrong direction
        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = (10 << 240) | uint256(0); // Start at 0, should go to 1e18

        // This should actually work (0 to 1e18 is increasing)
        uint256 result = mock.getCalculatedValues(priceCurve, 5);
        assertEq(result, 0.5e18, "Should interpolate from 0 to 1e18");
    }

    // ============ sharesScalingDirection Tests ============
    // Additional tests to ensure complete coverage of the helper function

    function test_sharesScalingDirection_BothIncrease() public view {
        assertTrue(mock.sharesScalingDirection(1.5e18, 1.2e18), "Both >1e18 should return true");
    }

    function test_sharesScalingDirection_BothDecrease() public view {
        assertTrue(mock.sharesScalingDirection(0.8e18, 0.5e18), "Both <1e18 should return true");
    }

    function test_sharesScalingDirection_FirstNeutral() public view {
        assertTrue(
            mock.sharesScalingDirection(1e18, 1.2e18), "First =1e18 should return true regardless"
        );
        assertTrue(
            mock.sharesScalingDirection(1e18, 0.8e18), "First =1e18 should return true regardless"
        );
    }

    function test_sharesScalingDirection_SecondNeutral() public view {
        assertTrue(
            mock.sharesScalingDirection(1.2e18, 1e18), "Second =1e18 should return true regardless"
        );
        assertTrue(
            mock.sharesScalingDirection(0.8e18, 1e18), "Second =1e18 should return true regardless"
        );
    }

    function test_sharesScalingDirection_BothNeutral() public view {
        assertTrue(mock.sharesScalingDirection(1e18, 1e18), "Both =1e18 should return true");
    }

    function test_sharesScalingDirection_OppositeDirections() public view {
        assertFalse(
            mock.sharesScalingDirection(1.5e18, 0.5e18), "Opposite directions should return false"
        );
        assertFalse(
            mock.sharesScalingDirection(0.5e18, 1.5e18), "Opposite directions should return false"
        );
    }

    // ============ Edge Cases for Complete Coverage ============

    function test_getCalculatedValues_ZeroDurationAtExactBlock() public view {
        // Test hitting a zero-duration element exactly
        uint256[] memory priceCurve = new uint256[](2);
        priceCurve[0] = (10 << 240) | uint256(1.2e18);
        priceCurve[1] = (0 << 240) | uint256(1.5e18); // Zero duration at block 10

        uint256 result = mock.getCalculatedValues(priceCurve, 10);
        assertEq(result, 1.5e18, "Should return zero-duration value exactly");
    }

    function test_getCalculatedValues_AfterZeroDuration_ValidDirection() public view {
        // Test interpolation after zero-duration with valid direction
        uint256[] memory priceCurve = new uint256[](3);
        priceCurve[0] = (5 << 240) | uint256(1.1e18);
        priceCurve[1] = (0 << 240) | uint256(1.3e18); // Zero duration at block 5
        priceCurve[2] = (10 << 240) | uint256(1.5e18); // Valid: both increasing

        // Access block 8 (3 blocks into the 10-block segment after zero duration)
        uint256 result = mock.getCalculatedValues(priceCurve, 8);

        // Should interpolate from 1.3 to 1.5 over 10 blocks, at position 3
        // 1.3 + (1.5 - 1.3) * 3/10 = 1.36
        assertApproxEqRel(result, 1.36e18, 0.01e18, "Should interpolate from zero duration");
    }

    function test_create_MaxValues() public view {
        PriceCurveElement element = mock.create(type(uint16).max, type(uint240).max);
        (uint256 duration, uint256 scaling) = mock.getComponents(element);

        assertEq(duration, type(uint16).max, "Should preserve max duration");
        assertEq(scaling, type(uint240).max, "Should preserve max scaling");
    }

    function test_create_MinValues() public view {
        PriceCurveElement element = mock.create(0, 0);
        (uint256 duration, uint256 scaling) = mock.getComponents(element);

        assertEq(duration, 0, "Should preserve min duration");
        assertEq(scaling, 0, "Should preserve min scaling");
    }

    function test_applyMemorySupplementalPriceCurve_EmptySupplemental() public view {
        // Base curve has elements but supplemental is empty
        uint256[] memory baseCurve = new uint256[](2);
        baseCurve[0] = (100 << 240) | uint256(1.2e18);
        baseCurve[1] = (50 << 240) | uint256(1.1e18);

        uint256[] memory supplemental = new uint256[](0);

        uint256[] memory combined = mock.applyMemorySupplementalPriceCurve(baseCurve, supplemental);

        // All elements should remain unchanged
        assertEq(combined.length, 2, "Should preserve base length");
        assertEq(combined[0], baseCurve[0], "First element should be unchanged");
        assertEq(combined[1], baseCurve[1], "Second element should be unchanged");
    }

    function test_applyMemorySupplementalPriceCurve_MultipleElements() public view {
        // Test with multiple elements to ensure loop coverage
        uint256[] memory baseCurve = new uint256[](3);
        baseCurve[0] = (100 << 240) | uint256(1.2e18);
        baseCurve[1] = (50 << 240) | uint256(1.15e18);
        baseCurve[2] = (30 << 240) | uint256(1.1e18);

        uint256[] memory supplemental = new uint256[](3);
        supplemental[0] = 1.05e18;
        supplemental[1] = 1.03e18;
        supplemental[2] = 1.02e18;

        uint256[] memory combined = mock.applyMemorySupplementalPriceCurve(baseCurve, supplemental);

        // Verify all three elements are combined correctly
        (, uint256 scaling0) = mock.getComponents(PriceCurveElement.wrap(combined[0]));
        assertEq(scaling0, 1.25e18, "First: 1.2 + 1.05 - 1.0");

        (, uint256 scaling1) = mock.getComponents(PriceCurveElement.wrap(combined[1]));
        assertEq(scaling1, 1.18e18, "Second: 1.15 + 1.03 - 1.0");

        (, uint256 scaling2) = mock.getComponents(PriceCurveElement.wrap(combined[2]));
        assertEq(scaling2, 1.12e18, "Third: 1.1 + 1.02 - 1.0");
    }
}
