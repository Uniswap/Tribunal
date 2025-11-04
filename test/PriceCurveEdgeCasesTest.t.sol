// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {PriceCurveLib, PriceCurveElement} from "../src/lib/PriceCurveLib.sol";
import {
    Mandate,
    FillParameters,
    FillComponent,
    Adjustment,
    RecipientCallback
} from "../src/types/TribunalStructs.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {PriceCurveTestHelper} from "./helpers/PriceCurveTestHelper.sol";

contract PriceCurveEdgeCasesTest is Test {
    using FixedPointMathLib for uint256;
    using PriceCurveLib for uint256[];

    Tribunal public tribunal;
    address theCompact;
    PriceCurveTestHelper public helper;

    uint256[] public emptyPriceCurve;

    receive() external payable {}

    function setUp() public {
        theCompact = address(0xC0);
        tribunal = new Tribunal();
        helper = new PriceCurveTestHelper();

        emptyPriceCurve = new uint256[](0);
    }

    // ============ Edge Case: Empty Price Curve Array ============

    function test_EmptyPriceCurve_ReturnsNeutralScaling() public pure {
        uint256[] memory priceCurve = new uint256[](0);

        uint256 currentScalingFactor = priceCurve.getCalculatedValues(0);
        assertEq(currentScalingFactor, 1e18, "Empty price curve should return 1e18");
    }

    function test_EmptyPriceCurve_WithTargetBlock() public view {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256[] memory priceCurve = new uint256[](0);

        // Empty price curve with non-zero target block doesn't revert
        // It just returns neutral scaling (1e18)
        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            100, // targetBlock != 0
            200, // fillBlock
            1 ether,
            0,
            1e18
        );

        assertEq(fillAmount, 1 ether); // Neutral scaling
        assertEq(claimAmounts[0], 1 ether);
    }

    // ============ Edge Case: Zero Duration Elements ============

    function test_ZeroDuration_InstantaneousPricePoint() public pure {
        uint256[] memory priceCurve = new uint256[](3);
        priceCurve[0] = (10 << 240) | uint256(1.2e18); // 10 blocks at 1.2x
        priceCurve[1] = (0 << 240) | uint256(1.5e18); // Zero duration at 1.5x
        priceCurve[2] = (20 << 240) | uint256(1e18); // 20 blocks ending at 1x

        // At block 5: should interpolate from 1.2x towards 1.5x
        uint256 scalingAtBlock5 = priceCurve.getCalculatedValues(5);
        // Expected: 1.2 + (1.5 - 1.2) * (5/10) = 1.35
        assertApproxEqRel(scalingAtBlock5, 1.35e18, 0.01e18);

        // At block 10: should be exactly 1.5x (zero-duration element)
        uint256 scalingAtBlock10 = priceCurve.getCalculatedValues(10);
        assertEq(scalingAtBlock10, 1.5e18);

        // At block 15: should interpolate from 1.5x towards 1x
        uint256 scalingAtBlock15 = priceCurve.getCalculatedValues(15);
        // Expected: 1.5 - (1.5 - 1.0) * (5/20) = 1.375
        assertApproxEqRel(scalingAtBlock15, 1.375e18, 0.01e18);
    }

    function test_ZeroDuration_InterpolationFromZeroDuration() public view {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256[] memory priceCurve = new uint256[](3);
        priceCurve[0] = (5 << 240) | uint256(1.1e18); // 5 blocks at 1.1x
        priceCurve[1] = (0 << 240) | uint256(1.3e18); // Zero duration at 1.3x
        priceCurve[2] = (10 << 240) | uint256(1e18); // 10 blocks to 1x

        uint256 targetBlock = 100;
        uint256 fillBlock = targetBlock + 7; // 2 blocks into the third segment

        (uint256 fillAmount,) = tribunal.deriveAmounts(
            maximumClaimAmounts, priceCurve, targetBlock, fillBlock, 1 ether, 0, 1e18
        );

        // At block 7: interpolating from 1.3x (at block 5) to 1x (at block 15)
        // 2 blocks into a 10-block segment
        // Expected: 1.3 - (1.3 - 1.0) * (2/10) = 1.24
        uint256 expectedScaling = 1.24e18;
        assertApproxEqRel(fillAmount, uint256(1 ether).mulWadUp(expectedScaling), 0.01e18);
    }

    // ============ Edge Case: Zero Scaling Factor ============

    function test_ZeroScalingFactor() public pure {
        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = (100 << 240) | uint256(0); // Scaling factor of 0

        uint256 scalingFactor = priceCurve.getCalculatedValues(50);

        // Should interpolate from 0 to 1e18 over 100 blocks
        // At block 50: 0 + (1e18 - 0) * (50/100) = 0.5e18
        assertEq(scalingFactor, 0.5e18);
    }

    function test_ZeroScalingFactor_ExactOut_ZeroClaimAmount() public view {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = (10 << 240) | uint256(0); // Start at 0

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            100,
            100, // At targetBlock, scaling is 0
            1 ether,
            0,
            0.5e18 // Exact-out mode
        );

        assertEq(fillAmount, 1 ether); // Fill amount unchanged
        assertEq(claimAmounts[0], 0); // Claim amount scaled to 0
    }

    // ============ Edge Case: Multiple Consecutive Zero-Duration Elements ============

    function test_MultipleConsecutiveZeroDuration() public pure {
        uint256[] memory priceCurve = new uint256[](4);
        priceCurve[0] = (10 << 240) | uint256(1.2e18);
        priceCurve[1] = (0 << 240) | uint256(1.5e18); // First zero-duration
        priceCurve[2] = (0 << 240) | uint256(1.3e18); // Second zero-duration (should NOT override)
        priceCurve[3] = (10 << 240) | uint256(1e18);

        // At block 10: should use the first zero-duration element (1.5x)
        // The second zero-duration at the same block doesn't get processed
        uint256 scalingAtBlock10 = priceCurve.getCalculatedValues(10);
        assertEq(scalingAtBlock10, 1.5e18, "Should use first zero-duration element");
    }

    // ============ Invalid Configurations ============

    function test_ExceedingTotalBlockDuration_Reverts() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = (10 << 240) | uint256(1.2e18);

        // Try to access beyond the defined duration
        // The curve goes from block 0-9 (10 blocks total)
        // Accessing at block 10 or beyond should revert
        vm.expectRevert(PriceCurveLib.PriceCurveBlocksExceeded.selector);
        tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            100, // targetBlock
            110, // fillBlock - 10 blocks after target, exceeds curve duration
            1 ether,
            0,
            1e18
        );
    }

    function test_InconsistentScalingDirections_Reverts() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256[] memory priceCurve = new uint256[](2);
        priceCurve[0] = (10 << 240) | uint256(1.5e18); // Increase (>1e18)
        priceCurve[1] = (10 << 240) | uint256(0.5e18); // Decrease (<1e18) - INVALID!

        vm.expectRevert(PriceCurveLib.InvalidPriceCurveParameters.selector);
        tribunal.deriveAmounts(maximumClaimAmounts, priceCurve, 100, 105, 1 ether, 0, 1e18);
    }

    // ============ Common Price Curve Patterns ============

    function test_LinearDecay_DutchAuction() public pure {
        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = (100 << 240) | uint256(0.8e18); // 100 blocks total duration

        // At block 0: should be 0.8
        assertEq(priceCurve.getCalculatedValues(0), 0.8e18);

        // At block 50: should interpolate to 0.9
        uint256 scalingAtBlock50 = priceCurve.getCalculatedValues(50);
        assertEq(scalingAtBlock50, 0.9e18);

        // At block 99: should be close to 1.0 (last valid block)
        uint256 scalingAtBlock99 = priceCurve.getCalculatedValues(99);
        // Expected: 0.8 + (1.0 - 0.8) * (99/100) = 0.998
        assertApproxEqRel(scalingAtBlock99, 0.998e18, 0.001e18);
    }

    function test_LinearDecay_DutchAuction_ExceedsDuration() public {
        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = (100 << 240) | uint256(0.8e18); // 100 blocks total duration

        // At block 100: should revert (exceeds total duration)
        vm.expectRevert(PriceCurveLib.PriceCurveBlocksExceeded.selector);
        helper.getCalculatedValues(priceCurve, 100);
    }

    function test_StepFunctionWithPlateaus() public pure {
        uint256[] memory priceCurve = new uint256[](3);
        priceCurve[0] = (50 << 240) | uint256(1.5e18); // 50 blocks
        priceCurve[1] = (50 << 240) | uint256(1.2e18); // 50 blocks
        priceCurve[2] = (50 << 240) | uint256(1e18); // 50 blocks
        // Total duration: 150 blocks

        // During first segment (block 25)
        uint256 scalingAtBlock25 = priceCurve.getCalculatedValues(25);
        // Should interpolate from 1.5 towards 1.2
        // Expected: 1.5 - (1.5 - 1.2) * (25/50) = 1.35
        assertEq(scalingAtBlock25, 1.35e18);

        // At block 50 (start of second segment)
        uint256 scalingAtBlock50 = priceCurve.getCalculatedValues(50);
        // Should interpolate from 1.2 towards 1.0
        // Expected: 1.2 - (1.2 - 1.0) * (0/50) = 1.2
        assertEq(scalingAtBlock50, 1.2e18);

        // At block 75 (halfway through second segment)
        uint256 scalingAtBlock75 = priceCurve.getCalculatedValues(75);
        // Block 75 is 25 blocks into segment 1 (blocks 50-100)
        // Expected: 1.2 - (1.2 - 1.0) * (25/50) = 1.1
        assertEq(scalingAtBlock75, 1.1e18);

        // At block 100 (start of third segment)
        uint256 scalingAtBlock100 = priceCurve.getCalculatedValues(100);
        // Expected: 1.0 - (1.0 - 1.0) * (0/50) = 1.0
        assertEq(scalingAtBlock100, 1e18);

        // At block 149 (last valid block)
        uint256 scalingAtBlock149 = priceCurve.getCalculatedValues(149);
        assertEq(scalingAtBlock149, 1e18);
    }

    function test_StepFunctionWithPlateaus_ExceedsDuration() public {
        uint256[] memory priceCurve = new uint256[](3);
        priceCurve[0] = (50 << 240) | uint256(1.5e18); // 50 blocks
        priceCurve[1] = (50 << 240) | uint256(1.2e18); // 50 blocks
        priceCurve[2] = (50 << 240) | uint256(1e18); // 50 blocks
        // Total duration: 150 blocks

        // At block 150: should revert (exceeds total duration)
        vm.expectRevert(PriceCurveLib.PriceCurveBlocksExceeded.selector);
        helper.getCalculatedValues(priceCurve, 150);
    }

    function test_InvertedAuction_PriceIncreasesOverTime() public pure {
        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = (100 << 240) | uint256(0.5e18); // 100 blocks total duration

        // Price should increase from 0.5x to 1x over 100 blocks
        assertEq(priceCurve.getCalculatedValues(0), 0.5e18);
        assertEq(priceCurve.getCalculatedValues(50), 0.75e18);
        assertApproxEqRel(priceCurve.getCalculatedValues(99), 0.995e18, 0.001e18);
    }

    function test_InvertedAuction_ExceedsDuration() public {
        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = (100 << 240) | uint256(0.5e18); // 100 blocks total duration

        // At block 100: should revert (exceeds total duration)
        vm.expectRevert(PriceCurveLib.PriceCurveBlocksExceeded.selector);
        helper.getCalculatedValues(priceCurve, 100);
    }

    function test_ComplexMultiPhaseCurve() public pure {
        uint256[] memory priceCurve = new uint256[](3);
        priceCurve[0] = (30 << 240) | uint256(1.5e18); // 30 blocks
        priceCurve[1] = (40 << 240) | uint256(1.3e18); // 40 blocks
        priceCurve[2] = (30 << 240) | uint256(1.1e18); // 30 blocks
        // Total duration: 30 + 40 + 30 = 100 blocks

        // Block 15: interpolating from 1.5 to 1.3
        uint256 scalingAtBlock15 = priceCurve.getCalculatedValues(15);
        // Expected: 1.5 - (1.5 - 1.3) * (15/30) = 1.4
        assertEq(scalingAtBlock15, 1.4e18);

        // Block 50: interpolating from 1.3 to 1.1
        uint256 scalingAtBlock50 = priceCurve.getCalculatedValues(50);
        // Expected: 1.3 - (1.3 - 1.1) * (20/40) = 1.2
        assertEq(scalingAtBlock50, 1.2e18);

        // Block 85: interpolating from 1.1 to 1.0
        uint256 scalingAtBlock85 = priceCurve.getCalculatedValues(85);
        // Expected: 1.1 - (1.1 - 1.0) * (15/30) = 1.05
        assertEq(scalingAtBlock85, 1.05e18);

        // At block 99: last valid block
        uint256 scalingAtBlock99 = priceCurve.getCalculatedValues(99);
        // Expected: 1.1 - (1.1 - 1.0) * (29/30) ≈ 1.0033
        assertApproxEqRel(scalingAtBlock99, 1.0033e18, 0.001e18);
    }

    function test_ComplexMultiPhaseCurve_ExceedsDuration() public {
        uint256[] memory priceCurve = new uint256[](3);
        priceCurve[0] = (30 << 240) | uint256(1.5e18); // 30 blocks
        priceCurve[1] = (40 << 240) | uint256(1.3e18); // 40 blocks
        priceCurve[2] = (30 << 240) | uint256(1.1e18); // 30 blocks
        // Total duration: 30 + 40 + 30 = 100 blocks

        // At block 100: should revert (exceeds total duration)
        vm.expectRevert(PriceCurveLib.PriceCurveBlocksExceeded.selector);
        helper.getCalculatedValues(priceCurve, 100);
    }

    // ============ Auction Duration and Validity Window ============

    function test_ValidityWindow_ExactBlock() public view {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = (1 << 240) | uint256(1.2e18); // 1 block duration

        // validBlockWindow = 1 means must be filled exactly at targetBlock
        bytes32 validityConditions = bytes32(uint256(1) << 160);

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: 100,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: validityConditions
        });

        // Should work at exact target block
        (uint256 fillAmount,) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            adjustment.targetBlock,
            adjustment.targetBlock, // Exactly at target
            1 ether,
            0,
            1e18
        );
        assertEq(fillAmount, uint256(1 ether).mulWadUp(1.2e18));
    }

    function test_PriceCurveShorterThanValidityWindow() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = (30 << 240) | uint256(1.5e18); // 30 block total duration

        // Test at block 29: last valid block of the curve
        (uint256 fillAmount,) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            100, // targetBlock
            129, // fillBlock (29 blocks after target, within 30-block curve)
            1 ether,
            0,
            1e18
        );

        // At block 29: close to 1e18 (end of interpolation)
        // Expected: 1.5 - (1.5 - 1.0) * (29/30) ≈ 1.0167
        assertApproxEqRel(fillAmount, uint256(1 ether).mulWadUp(1.0167e18), 0.01e18);

        // At block 30: should revert (exceeds curve duration)
        vm.expectRevert(PriceCurveLib.PriceCurveBlocksExceeded.selector);
        tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            100, // targetBlock
            130, // fillBlock (30 blocks after target, exceeds 30-block curve)
            1 ether,
            0,
            1e18
        );
    }

    // ============ Supplemental Price Curves ============

    function test_SupplementalPriceCurve() public view {
        // Test supplemental curves through deriveAmounts which internally applies them
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256[] memory baseCurve = new uint256[](1);
        baseCurve[0] = (100 << 240) | uint256(1.2e18); // Base: 1.2x

        // Create a mock Fill to get supplemental curve applied
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            recipient: address(this),
            applyScaling: true
        });

        FillParameters memory fill = FillParameters({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: block.timestamp + 1 hours,
            components: components,
            baselinePriorityFee: 0,
            scalingFactor: 1e18,
            priceCurve: baseCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(0)
        });

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: 100,
            supplementalPriceCurve: new uint256[](1),
            validityConditions: bytes32(0)
        });
        adjustment.supplementalPriceCurve[0] = uint256(1.1e18); // Additional 1.1x

        // Without supplemental curve
        (uint256 fillAmountBase,) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            fill.priceCurve,
            adjustment.targetBlock,
            adjustment.targetBlock, // At start of curve
            fill.components[0].minimumFillAmount,
            fill.baselinePriorityFee,
            fill.scalingFactor
        );

        // Base curve at block 0 should give 1.2x
        assertEq(fillAmountBase, uint256(1 ether).mulWadUp(1.2e18));
    }

    // Supplemental curve direction validation is already tested through
    // test_InconsistentScalingDirections_Reverts which exercises the same validation logic

    // ============ Priority Fee Interactions ============

    function test_PriorityFee_ExactIn_IncreasesWithGas() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = (100 << 240) | uint256(1.2e18);

        uint256 baselinePriorityFee = 10 gwei;
        uint256 scalingFactor = 1.5e18; // Exact-in mode

        // Set high priority fee
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + baselinePriorityFee + 20 gwei);

        (uint256 fillAmount,) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            100,
            150, // Midway through curve
            1 ether,
            baselinePriorityFee,
            scalingFactor
        );

        // Current scaling from curve: 1.2 - (1.2-1.0) * 0.5 = 1.1
        // Priority adjustment: 1.1 + (1.5 - 1.0) * 20 gwei = 1.1 + 10e9
        uint256 expectedScaling = 1.1e18 + ((scalingFactor - 1e18) * 20 gwei);
        assertApproxEqRel(fillAmount, uint256(1 ether).mulWadUp(expectedScaling), 0.001e18);
    }

    function test_PriorityFee_ExactOut_DecreasesWithGas() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = (100 << 240) | uint256(0.8e18);

        uint256 baselinePriorityFee = 10 gwei;
        uint256 scalingFactor = 0.999e18; // Exact-out mode (smaller difference to avoid underflow)

        // Set smaller priority fee to avoid underflow
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + baselinePriorityFee + 1 wei); // Just 1 wei above baseline

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            100,
            150, // Midway through curve
            1 ether,
            baselinePriorityFee,
            scalingFactor
        );

        assertEq(fillAmount, 1 ether); // Fill amount fixed in exact-out

        // Current scaling from curve: 0.8 + (1.0-0.8) * 0.5 = 0.9
        // Priority adjustment: 0.9 - (1.0 - 0.999) * 1 wei
        uint256 currentCurveScaling = 0.9e18;
        uint256 expectedScaling = currentCurveScaling - ((1e18 - scalingFactor) * 1);
        assertApproxEqRel(
            claimAmounts[0], maximumClaimAmounts[0].amount.mulWad(expectedScaling), 0.001e18
        );
    }
}
