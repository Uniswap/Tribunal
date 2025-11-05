// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BatchCompact} from "the-compact/src/types/EIP712Types.sol";

/**
 * @title IDispatchCallback
 * @custom:security-contact security@uniswap.org
 * @notice Interface for contracts that can receive dispatch callbacks from Tribunal after fills.
 * @dev Implementers must return the correct function selector to confirm successful execution.
 */
interface IDispatchCallback {
    /**
     * @notice Callback function to be called by the Tribunal contract after a fill is completed.
     * @param chainId The chain ID the dispatch callback is intended to interact with.
     * @param compact The compact parameters from the fill.
     * @param mandateHash The mandate hash from the fill.
     * @param claimHash The claim hash of the compact that can be claimed on performing the fill.
     * @param claimant The bytes32 value representing the claimant (lock tag ++ address).
     * @param claimReductionScalingFactor The scaling factor applied to claim amounts (1e18 if no reduction).
     * @param claimAmounts The actual amounts of tokens claimed (after any reductions).
     * @param context Arbitrary context data provided by the filler.
     * @return This function selector to confirm successful execution.
     */
    function dispatchCallback(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes32 mandateHash,
        bytes32 claimHash,
        bytes32 claimant,
        uint256 claimReductionScalingFactor,
        uint256[] calldata claimAmounts,
        bytes calldata context
    ) external payable returns (bytes4);
}
