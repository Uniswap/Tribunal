// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Mandate_BatchCompact} from "../types/TribunalStructs.sol";

interface IRecipientCallback {
    /// @notice Callback function to be called by the Tribunal contract to the recipient.
    /// @dev At this point, the filler has received the fillToken with an amount of actualFillAmount.
    /// @param claimHash The claim hash of the compact that has been claimed.
    /// @param mandateHash The mandate hash of the compact that has been claimed.
    /// @param fillToken The reward token of the fill.
    /// @param fillAmount The actual fill amount that is provided.
    /// @param compact The new compact and mandate hash associated with the callback.
    /// @param context Arbitrary context associated with the callback.
    function tribunalCallback(
        uint256 chainId,
        bytes32 claimHash,
        bytes32 mandateHash,
        address fillToken,
        uint256 fillAmount,
        Mandate_BatchCompact compact,
        bytes calldata context
    ) external;
}
