// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DecayParameter, DecayParameterLib} from "../src/lib/DecayParameterLib.sol";

/**
 * @title Tester Contract
 * @dev Helper contract to expose library functions for testing
 */
contract DecayParameterTester {
    using DecayParameterLib for DecayParameter;

    function create(uint16 blockDuration, uint120 fillIncrease, uint120 claimDecrease)
        external
        pure
        returns (DecayParameter)
    {
        return DecayParameterLib.create(blockDuration, fillIncrease, claimDecrease);
    }

    function getCalculatedValues(uint256[] calldata parameters, uint256 blocksPassed)
        external
        pure
        returns (uint256 currentFillIncrease, uint256 currentClaimDecrease)
    {
        return DecayParameterLib.getCalculatedValues(parameters, blocksPassed);
    }

    function getComponents(DecayParameter param)
        external
        pure
        returns (uint256 blockDuration, uint256 fillIncrease, uint256 claimDecrease)
    {
        return param.getComponents();
    }
}

/**
 * @title DecayParameterLibTest
 * @dev Test suite for DecayParameterLib
 */
contract DecayParameterLibTest is Test {
    DecayParameterTester public tester;
    uint256[] public parameters;
    uint256[] public multiZeroParameters;

    function setUp() public {
        tester = new DecayParameterTester();

        // Set up the test parameters array as described in the example
        parameters.push(DecayParameter.unwrap(tester.create(5, 10, 20))); // Duration 5, fill 10, claim 20
        parameters.push(DecayParameter.unwrap(tester.create(5, 5, 10))); // Duration 5, fill 5, claim 10
        parameters.push(DecayParameter.unwrap(tester.create(0, 0, 5))); // Duration 0, fill 0, claim 5 (instant jump)
        parameters.push(DecayParameter.unwrap(tester.create(5, 10, 10))); // Duration 5, fill 10, claim 10

        // Set up test parameters with multiple zero-duration segments
        multiZeroParameters.push(DecayParameter.unwrap(tester.create(5, 10, 20))); // Duration 5, fill 10, claim 20
        multiZeroParameters.push(DecayParameter.unwrap(tester.create(0, 15, 15))); // Duration 0, fill 15, claim 15 (instant jump 1)
        multiZeroParameters.push(DecayParameter.unwrap(tester.create(0, 0, 0))); // Duration 0, fill 0, claim 0 (instant jump 2)
        multiZeroParameters.push(DecayParameter.unwrap(tester.create(5, 20, 20))); // Duration 5, fill 20, claim 20
    }

    function testGetCalculatedValues_AtStart() public view {
        // At block 0: return 10, 20 for fillIncrease, claimDecrease
        (uint256 fillIncrease, uint256 claimDecrease) = tester.getCalculatedValues(parameters, 0);
        assertEq(fillIncrease, 10, "Fill increase should be 10 at block 0");
        assertEq(claimDecrease, 20, "Claim decrease should be 20 at block 0");
    }

    function testGetCalculatedValues_AtBlock1() public view {
        // At block 1: return 9, 18
        (uint256 fillIncrease, uint256 claimDecrease) = tester.getCalculatedValues(parameters, 1);
        assertEq(fillIncrease, 9, "Fill increase should be 9 at block 1");
        assertEq(claimDecrease, 18, "Claim decrease should be 18 at block 1");
    }

    function testGetCalculatedValues_AtBlock4() public view {
        // At block 4: return 6, 12
        (uint256 fillIncrease, uint256 claimDecrease) = tester.getCalculatedValues(parameters, 4);
        assertEq(fillIncrease, 6, "Fill increase should be 6 at block 4");
        assertEq(claimDecrease, 12, "Claim decrease should be 12 at block 4");
    }

    function testGetCalculatedValues_AtBlock5() public view {
        // At block 5: return 5, 10
        (uint256 fillIncrease, uint256 claimDecrease) = tester.getCalculatedValues(parameters, 5);
        assertEq(fillIncrease, 5, "Fill increase should be 5 at block 5");
        assertEq(claimDecrease, 10, "Claim decrease should be 10 at block 5");
    }

    function testGetCalculatedValues_AtBlock6() public view {
        // At block 6: return 4, 9
        (uint256 fillIncrease, uint256 claimDecrease) = tester.getCalculatedValues(parameters, 6);
        assertEq(fillIncrease, 4, "Fill increase should be 4 at block 6");
        assertEq(claimDecrease, 9, "Claim decrease should be 9 at block 6");
    }

    function testGetCalculatedValues_AtBlock9() public view {
        // At block 9: return 1, 6
        (uint256 fillIncrease, uint256 claimDecrease) = tester.getCalculatedValues(parameters, 9);
        assertEq(fillIncrease, 1, "Fill increase should be 1 at block 9");
        assertEq(claimDecrease, 6, "Claim decrease should be 6 at block 9");
    }

    function testGetCalculatedValues_AtBlock10WithZeroDuration() public view {
        // At block 10: return 0, 5 (immediate jump due to duration 0)
        (uint256 fillIncrease, uint256 claimDecrease) = tester.getCalculatedValues(parameters, 10);
        assertEq(fillIncrease, 0, "Fill increase should be 0 at block 10 (zero duration jump)");
        assertEq(claimDecrease, 5, "Claim decrease should be 5 at block 10 (zero duration jump)");
    }

    function testGetCalculatedValues_AtBlock11() public view {
        // At block 11: return 2, 6
        (uint256 fillIncrease, uint256 claimDecrease) = tester.getCalculatedValues(parameters, 11);
        assertEq(fillIncrease, 2, "Fill increase should be 2 at block 11");
        assertEq(claimDecrease, 6, "Claim decrease should be 6 at block 11");
    }

    function testGetCalculatedValues_AtBlock14() public view {
        // At block 14: return 8, 9
        (uint256 fillIncrease, uint256 claimDecrease) = tester.getCalculatedValues(parameters, 14);
        assertEq(fillIncrease, 8, "Fill increase should be 8 at block 14");
        assertEq(claimDecrease, 9, "Claim decrease should be 9 at block 14");
    }

    function testGetCalculatedValues_ExceedingBlocks() public {
        // At block 15: revert (out of blocks)
        vm.expectRevert(DecayParameterLib.DecayBlocksExceeded.selector);
        tester.getCalculatedValues(parameters, 15);
    }

    function testGetCalculatedValues_EmptyParameters() public view {
        // Test with empty parameters array
        uint256[] memory emptyParams = new uint256[](0);
        (uint256 fillIncrease, uint256 claimDecrease) = tester.getCalculatedValues(emptyParams, 0);
        assertEq(fillIncrease, 0, "Fill increase should be 0 with empty parameters");
        assertEq(claimDecrease, 0, "Claim decrease should be 0 with empty parameters");
    }

    function testBitPacking() public view {
        // Test that bit packing and unpacking works correctly
        uint16 blockDuration = 42;
        uint120 fillIncrease = 12345;
        uint120 claimDecrease = 67890;

        DecayParameter param = tester.create(blockDuration, fillIncrease, claimDecrease);
        (uint256 extractedDuration, uint256 extractedFill, uint256 extractedClaim) =
            tester.getComponents(param);

        assertEq(extractedDuration, blockDuration, "Block duration should be preserved");
        assertEq(extractedFill, fillIncrease, "Fill increase should be preserved");
        assertEq(extractedClaim, claimDecrease, "Claim decrease should be preserved");
    }
}
