// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Lock} from "the-compact/src/types/EIP712Types.sol";

interface ITribunalCallback {
    /// @notice Callback function to be called by the Tribunal contract to the filler.
    /// @dev At this point, the filler has received the fillToken with an amount of actualFillAmount.
    /// @param claimHash The claim hash of the associated compact that has been claimed.
    /// @param commitments The commitments that need to be filled.
    /// @param claimedAmounts The actual amounts required to complete the fill.
    /// @param fillToken The reward token of the fill.
    /// @param minimumFillAmount The minimum fill amount that was offered.
    /// @param actualFillAmount The actual fill amount that is provided.
    function tribunalCallback(
        bytes32 claimHash,
        Lock[] calldata commitments,
        uint256[] calldata claimedAmounts,
        address fillToken,
        uint256 minimumFillAmount,
        uint256 actualFillAmount
    ) external;
}
