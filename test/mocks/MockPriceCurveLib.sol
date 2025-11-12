// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PriceCurveLib, PriceCurveElement} from "../../src/lib/PriceCurveLib.sol";

/**
 * @title MockPriceCurveLib
 * @dev Mock contract to expose internal PriceCurveLib functions for testing,
 *      particularly the memory version of applySupplementalPriceCurve
 */
contract MockPriceCurveLib {
    using PriceCurveLib for uint256[];

    /**
     * @dev Expose the memory version of applySupplementalPriceCurve for testing
     */
    function applyMemorySupplementalPriceCurve(
        uint256[] memory parameters,
        uint256[] memory supplementalParameters
    ) external pure returns (uint256[] memory) {
        return parameters.applyMemorySupplementalPriceCurve(supplementalParameters);
    }

    /**
     * @dev Expose the calldata version of applySupplementalPriceCurve for testing
     */
    function applySupplementalPriceCurve(
        uint256[] calldata parameters,
        uint256[] calldata supplementalParameters
    ) external pure returns (uint256[] memory) {
        return parameters.applySupplementalPriceCurve(supplementalParameters);
    }

    /**
     * @dev Expose getCalculatedValues for testing
     */
    function getCalculatedValues(uint256[] memory parameters, uint256 blocksPassed)
        external
        pure
        returns (uint256)
    {
        return parameters.getCalculatedValues(blocksPassed);
    }

    /**
     * @dev Expose sharesScalingDirection for testing
     */
    function sharesScalingDirection(uint256 a, uint256 b) external pure returns (bool) {
        return PriceCurveLib.sharesScalingDirection(a, b);
    }

    /**
     * @dev Expose create function for testing
     */
    function create(uint16 blockDuration, uint240 scalingFactor)
        external
        pure
        returns (PriceCurveElement)
    {
        return PriceCurveLib.create(blockDuration, scalingFactor);
    }

    /**
     * @dev Expose getComponents for testing
     */
    function getComponents(PriceCurveElement element)
        external
        pure
        returns (uint256 blockDuration, uint256 scalingFactor)
    {
        return PriceCurveLib.getComponents(element);
    }
}
