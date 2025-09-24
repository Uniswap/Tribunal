// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IArbSys} from "./interfaces/IArbSys.sol";

/// @title BlockNumberish
/// A helper contract to get the current block number on different chains
contract BlockNumberish {
    uint256 private constant ARB_CHAIN_ID = 42161;
    address private constant ARB_SYS_ADDRESS = 0x0000000000000000000000000000000000000064;

    function _getBlockNumberish() internal view returns (uint256) {
        // Set the function to use based on chainid
        if (block.chainid == ARB_CHAIN_ID) {
            return IArbSys(ARB_SYS_ADDRESS).arbBlockNumber();
        } else {
            return block.number;
        }
    }
}
