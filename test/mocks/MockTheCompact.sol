// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BatchClaim as CompactBatchClaim} from "the-compact/src/types/BatchClaims.sol";

contract MockTheCompact {
    function batchClaim(CompactBatchClaim calldata) external pure returns (bytes32) {
        return bytes32(uint256(0x5ab5d4a8ba29d5317682f2808ad60826cc75eb191581bea9f13d498a6f8e6311));
    }
}
