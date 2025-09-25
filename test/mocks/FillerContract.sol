// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ITribunalCallback} from "../../src/interfaces/ITribunalCallback.sol";
import {Lock} from "the-compact/src/types/EIP712Types.sol";

contract FillerContract is ITribunalCallback {
    receive() external payable {}

    // Implement ITribunalCallback
    function tribunalCallback(
        bytes32,
        Lock[] calldata,
        uint256[] calldata,
        address,
        uint256,
        uint256
    ) external {
        // Empty implementation - just need to be callable
    }
}
