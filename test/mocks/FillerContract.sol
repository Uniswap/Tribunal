// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ITribunalCallback} from "../../src/interfaces/ITribunalCallback.sol";
import {Lock} from "the-compact/src/types/EIP712Types.sol";
import {FillRequirement} from "../../src/types/TribunalStructs.sol";

contract FillerContract is ITribunalCallback {
    receive() external payable {}

    // Implement ITribunalCallback
    function tribunalCallback(
        bytes32,
        Lock[] calldata,
        uint256[] calldata,
        FillRequirement[] calldata
    ) external {
        // Empty implementation - just need to be callable
    }
}
