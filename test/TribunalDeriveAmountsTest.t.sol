// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Mandate, Fill, Adjustment, RecipientCallback} from "../src/types/TribunalStructs.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";

contract TribunalDeriveAmountsTest is Test {
    using FixedPointMathLib for uint256;

    Tribunal public tribunal;
    address theCompact;

    uint256[] public emptyPriceCurve;

    receive() external payable {}

    function setUp() public {
        theCompact = address(0xC0);
        tribunal = new Tribunal(theCompact);

        emptyPriceCurve = new uint256[](0);
    }

    function test_DeriveAmounts_NoPriorityFee() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 100 ether});

        uint256 minimumFillAmount = 95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 1e18;

        vm.fee(baselinePriorityFee);
        vm.txGasPrice(baselinePriorityFee + 1 wei);

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            emptyPriceCurve,
            0,
            vm.getBlockNumber(),
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );

        assertEq(fillAmount, minimumFillAmount);
        assertEq(claimAmounts[0], maximumClaimAmounts[0].amount);
    }

    function test_DeriveAmounts_ExactOut() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256 minimumFillAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 5e17;

        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + baselinePriorityFee + 2 wei);

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            emptyPriceCurve,
            0,
            vm.getBlockNumber(),
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );

        assertEq(fillAmount, minimumFillAmount);

        uint256 scalingMultiplier = 1e18 - ((1e18 - scalingFactor) * 2);
        uint256 expectedClaimAmount = maximumClaimAmounts[0].amount.mulWad(scalingMultiplier);
        assertEq(claimAmounts[0], expectedClaimAmount);
    }

    function test_DeriveAmounts_ExactIn() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256 minimumFillAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 15e17;

        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + baselinePriorityFee + 2 wei);

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            emptyPriceCurve,
            0,
            vm.getBlockNumber(),
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );

        assertEq(claimAmounts[0], maximumClaimAmounts[0].amount);

        uint256 scalingMultiplier = 1e18 + ((scalingFactor - 1e18) * 2);
        uint256 expectedFillAmount = minimumFillAmount.mulWadUp(scalingMultiplier);
        assertEq(fillAmount, expectedFillAmount);
    }

    function test_DeriveAmounts_ExtremePriorityFee() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256 minimumFillAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 15e17;

        uint256 baseFee = 1 gwei;
        vm.fee(baseFee);
        vm.txGasPrice(baseFee + baselinePriorityFee + 10 wei);

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            emptyPriceCurve,
            0,
            vm.getBlockNumber(),
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );

        assertEq(claimAmounts[0], maximumClaimAmounts[0].amount);

        uint256 scalingMultiplier = 1e18 + ((scalingFactor - 1e18) * 10);
        uint256 expectedFillAmount = minimumFillAmount.mulWadUp(scalingMultiplier);
        assertEq(fillAmount, expectedFillAmount);
    }

    function test_DeriveAmounts_RealisticExactIn() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256 minimumFillAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 1000000000100000000;

        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + baselinePriorityFee + 5 gwei);

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            emptyPriceCurve,
            0,
            vm.getBlockNumber(),
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );

        assertEq(claimAmounts[0], maximumClaimAmounts[0].amount);

        uint256 scalingMultiplier = 1e18 + ((scalingFactor - 1e18) * 5 gwei);
        uint256 expectedFillAmount = minimumFillAmount.mulWadUp(scalingMultiplier);
        assertEq(fillAmount, expectedFillAmount);
    }

    function test_DeriveAmounts_RealisticExactOut() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256 minimumFillAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 999999999900000000;

        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + baselinePriorityFee + 5 gwei);

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            emptyPriceCurve,
            0,
            vm.getBlockNumber(),
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );

        assertEq(fillAmount, minimumFillAmount);

        uint256 scalingMultiplier = 1e18 - ((1e18 - scalingFactor) * 5 gwei);
        uint256 expectedClaimAmount = maximumClaimAmounts[0].amount.mulWad(scalingMultiplier);
        assertEq(claimAmounts[0], expectedClaimAmount);
    }

    function test_DeriveAmounts_WithPriceCurve() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256 minimumFillAmount = 0.95 ether;
        uint256 baselinePriorityFee = 0;
        uint256 scalingFactor = 1e18;

        uint256 targetBlock = vm.getBlockNumber();
        uint256 fillBlock = targetBlock + 5;

        uint256[] memory priceCurve = new uint256[](2);
        priceCurve[0] = (3 << 240) | uint256(8e17); // 0.8 * 10^18 (scaling down)
        priceCurve[1] = (10 << 240) | uint256(6e17); // 0.6 * 10^18 (scaling down more)

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            targetBlock,
            fillBlock,
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );

        // With exact-out mode and price curve scaling down
        assertEq(fillAmount, minimumFillAmount); // Fill amount stays the same

        // Calculate expected claim amount based on interpolation at block 5
        // We're 5 blocks in, with segment ending at block 3+10=13
        // So we're 5-3=2 blocks into a 10-block segment
        // Interpolating from 0.6 to 0 (last segment ends at 0)
        // scalingMultiplier = 0.6 - (0.6 * 2/10) = 0.6 * 0.8 = 0.48
        uint256 expectedScaling = 48e16; // 0.48 * 10^18
        uint256 expectedClaimAmount = maximumClaimAmounts[0].amount.mulWad(expectedScaling);
        assertEq(claimAmounts[0], expectedClaimAmount);
    }

    function test_DeriveAmounts_InvalidTargetBlockDesignation() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = 1e18;

        vm.expectRevert(abi.encodeWithSignature("InvalidTargetBlockDesignation()"));
        tribunal.deriveAmounts(
            maximumClaimAmounts, priceCurve, 0, vm.getBlockNumber(), 1 ether, 0, 1e18
        );
    }
}
