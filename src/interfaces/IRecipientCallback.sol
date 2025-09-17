// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BatchCompact} from "../types/TribunalStructs.sol";

interface IRecipientCallback {
    /**
     * @notice Callback function to be called by the Tribunal contract to the recipient.
     * @param chainId The target chain ID communicated as part of the callback.
     * @param sourceClaimHash The claim hash of the compact that has been claimed.
     * @param sourceMandateHash The mandate hash of the compact that has been claimed.
     * @param fillToken The reward token of the fill.
     * @param fillAmount The actual fill amount that is provided.
     * @param targetCompact The new compact associated with the callback.
     * @param targetMandateHash The mandate hash associated with the new compact.
     * @param context Arbitrary context associated with the callback.
     * @return This function selector to confirm successful execution.
     */
    function tribunalCallback(
        uint256 chainId,
        bytes32 sourceClaimHash,
        bytes32 sourceMandateHash,
        address fillToken,
        uint256 fillAmount,
        BatchCompact calldata targetCompact,
        bytes32 targetMandateHash,
        bytes calldata context
    ) external returns (bytes4);
}
