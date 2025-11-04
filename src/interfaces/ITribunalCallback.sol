// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Lock} from "the-compact/src/types/EIP712Types.sol";
import {FillRequirement} from "../types/TribunalStructs.sol";

/**
 * @title ITribunalCallback
 * @custom:security-contact security@uniswap.org
 * @notice Interface for filler contracts that can receive callbacks from Tribunal during single-chain fills.
 * @dev Called after claiming tokens from The Compact but before transferring fill tokens to the recipient and
 * potentially triggering a recipient callback.
 */
interface ITribunalCallback {
    /**
     * @notice Callback function to be called by the Tribunal contract to the filler.
     * @dev At this point, the filler has already received the claimed tokens and must
     * supply the actual fill amounts of each fill token to Tribunal before exiting the callback.
     * @param claimHash The claim hash of the associated compact that has been claimed.
     * @param commitments The resource lock commitments provided by the sponsor.
     * @param claimedAmounts The actual amounts claimed to complete the fill.
     * @param fillRequirements Array of fill requirements specifying tokens, minimum amounts, and realized amounts.
     */
    function tribunalCallback(
        bytes32 claimHash,
        Lock[] calldata commitments,
        uint256[] calldata claimedAmounts,
        FillRequirement[] calldata fillRequirements
    ) external;
}
