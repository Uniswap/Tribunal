// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() {
        _mint(msg.sender, 1000000e18);
    }

    function name() public pure override returns (string memory) {
        return "Mock Token";
    }

    function symbol() public pure override returns (string memory) {
        return "MOCK";
    }
}
