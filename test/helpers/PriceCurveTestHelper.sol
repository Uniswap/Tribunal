// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PriceCurveLib} from "../../src/lib/PriceCurveLib.sol";

contract PriceCurveTestHelper {
    using PriceCurveLib for uint256[];

    function getCalculatedValues(uint256[] memory priceCurve, uint256 blocksPassed)
        external
        pure
        returns (uint256)
    {
        return priceCurve.getCalculatedValues(blocksPassed);
    }
}
