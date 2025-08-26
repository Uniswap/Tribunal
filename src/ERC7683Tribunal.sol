// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibBytes} from "solady/utils/LibBytes.sol";

import {IDestinationSettler} from "./Interfaces/IDestinationSettler.sol";
import {Tribunal} from "./Tribunal.sol";
import {ITribunal} from "./interfaces/ITribunal.sol";
import {Mandate, Fill, Adjustment} from "./types/TribunalStructs.sol";
import {BatchCompact} from "the-compact/src/types/EIP712Types.sol";

/// @title ERC7683Tribunal
/// @notice A contract that enables the tribunal compatibility with the ERC7683 destination settler interface.
contract ERC7683Tribunal is Tribunal, IDestinationSettler {
    // ======== Constructor ========
    constructor(address compact) Tribunal(compact) {}

    // ======== External Functions ========
    /**
     * @notice Attempt to fill a cross-chain swap using ERC7683 interface.
     * @dev Unused initial parameter included for EIP7683 interface compatibility.
     * @param originData The encoded Claim and Mandate data.
     * @param fillerData The encoded claimant address.
     */
    function fill(bytes32, bytes calldata originData, bytes calldata fillerData)
        external
        payable
        nonReentrant
    {
        (
            BatchClaim calldata claim,
            Fill calldata mandate,
            bytes32[] calldata fillHashes,
            address adjuster,
            Adjustment calldata adjustment,
            bytes calldata adjustmentAuthorization,
            bytes32 claimant,
            uint256 fillBlock
        ) = _parseCalldata(originData, fillerData);

        uint256 currentBlock = _getBlockNumberish();

        assembly ("memory-safe") {
            fillBlock := xor(fillBlock, mul(iszero(fillBlock), currentBlock))
        }

        if (fillBlock != currentBlock) {
            revert InvalidFillBlock();
        }

        _fill(
            claim.chainId,
            claim.compact,
            claim.sponsorSignature,
            claim.allocatorSignature,
            mandate,
            adjuster,
            adjustment,
            adjustmentAuthorization,
            claimant,
            fillBlock,
            fillHashes
        );
    }

    /**
     * @notice Get a quote for any native tokens supplied to pay for dispensation (i.e. cost to trigger settlement).
     * @dev Unused initial parameter included for EIP7683 interface compatibility.
     * @param originData The encoded Claim and Mandate data.
     * @param fillerData The encoded claimant address.
     * @return dispensation The suggested dispensation amount.
     */
    function quote(bytes32, bytes calldata originData, bytes calldata fillerData)
        external
        view
        returns (uint256 dispensation)
    {
        (
            BatchClaim calldata claim,
            Fill calldata mandate,
            bytes32[] calldata fillHashes,
            address adjuster,
            Adjustment calldata adjustment,
            ,
            bytes32 claimant,
            uint256 fillBlock
        ) = _parseCalldata(originData, fillerData);

        return _quote(
            claim.chainId,
            claim.compact,
            claim.sponsorSignature,
            claim.allocatorSignature,
            mandate,
            adjuster,
            adjustment,
            fillBlock,
            claimant,
            fillHashes
        );
    }

    /**
     * @notice Encode the filler data for the fill function.
     * @param adjustment The adjustment struct, including the adjustments to the order.
     * @param adjustmentAuthorization The adjustment authorization bytes confirming the adjustment.
     * @param claimant The claimant address that will receive the reward tokens. The first 12 bytes will be as the Lock tag for retrieval instructions.
     * @param fillBlock The fill block at which the filler should be executed.
     * @return fillerData The filler data.
     */
    function getFillerData(
        Adjustment calldata adjustment,
        bytes calldata adjustmentAuthorization,
        bytes32 claimant,
        uint256 fillBlock
    ) internal pure returns (bytes memory fillerData) {
        fillerData = abi.encode(adjustment, adjustmentAuthorization, claimant, fillBlock);
    }

    /**
     * @notice Parses the calldata to extract the necessary parameters without copying to memory.
     * @param originData The encoded Claim and Mandate data.
     * @param fillerData The encoded claimant address.
     * @return claim The Claim struct.
     * @return mandate The Mandate struct.
     * @return fillHashes The fillHashes array.
     * @return adjuster The adjuster address.
     * @return adjustment The Adjustment struct.
     * @return adjustmentAuthorization The adjustmentAuthorization bytes.
     * @return claimant The claimant address.
     * @return fillBlock The fillBlock.
     */
    function _parseCalldata(bytes calldata originData, bytes calldata fillerData)
        internal
        pure
        returns (
            BatchClaim calldata claim,
            Fill calldata mandate,
            bytes32[] calldata fillHashes,
            address adjuster,
            Adjustment calldata adjustment,
            bytes calldata adjustmentAuthorization,
            bytes32 claimant,
            uint256 fillBlock
        )
    {
        /*
         * Need 31 words in originData at minimum:
         *  - 1 word for offset to claim (dynamic struct).
         *  - 1 word for offset to the main fill (dynamic struct).
         *  - 1 word for adjuster address.
         *  - 1 word for offset to fillHashes.
         *  - 5 words for fixed claim fields (chainId, BatchCompact.arbiter, BatchCompact.sponsor, BatchCompact.nonce, BatchCompact.expires).
         *  - 9 words for fixed mandate fields.
         *  - 1 word for offset to claim.BatchCompact
         *  - 5 words for dynamic offsets (BatchCompact.commitments, sponsorSignature, allocatorSignature, Fill.priceCurve and Fill.recipientCallback).
         *  - 5 words for lengths of dynamics (assuming empty).
         *  - 2 words for fillHashes length & at least a single word for fill hash.
         * Also ensure no funny business with the claim pointer (should be 0x80).
         * 
         * Need 10 words in fillerData at minimum:
         *  - 1 word for offset to adjustment (dynamic struct).
         *  - 1 word for offset to adjustmentAuthorization.
         *  - 1 word for claimant.
         *  - 1 word for fillBlock.
         *  - 3 word for fixed adjustment fields (fillIndex, targetBlock, validityConditions).
         *  - 1 word for supplementalPriceCurve offset.
         *  - 2 words for adjustmentAuthorization and supplementalPriceCurve length (assuming empty).
         * Also ensure no funny business with the adjustment pointer (should be 0x80).
         */
        assembly ("memory-safe") {
            if or(
                or(lt(originData.length, 0x3E0), xor(calldataload(originData.offset), 0x80)),
                or(lt(fillerData.length, 0x140), xor(calldataload(fillerData.offset), 0x80))
            ) { revert(0, 0) }
        }

        // Get the claim, fill, adjuster, and fillHashes encoded as bytes arrays with bounds checks from the originData.
        bytes calldata encodedClaim = LibBytes.dynamicStructInCalldata(originData, 0x00);
        bytes calldata encodedFill = LibBytes.dynamicStructInCalldata(originData, 0x20);
        bytes32 encodedAdjuster = LibBytes.loadCalldata(originData, 0x40);
        bytes calldata encodedFillHashes = LibBytes.bytesInCalldata(originData, 0x60);

        // Get the adjustment, adjustmentAuthorization, claimant and fillBlock encoded as bytes arrays with bounds checks from the fillerData.
        bytes calldata encodedAdjustment = LibBytes.dynamicStructInCalldata(fillerData, 0x00);
        adjustmentAuthorization = LibBytes.bytesInCalldata(fillerData, 0x20);
        bytes32 encodedClaimant = LibBytes.loadCalldata(fillerData, 0x40);
        bytes32 encodedFillBlock = LibBytes.loadCalldata(fillerData, 0x60);

        // Extract static structs and other static variables directly.
        // Note: This doesn't sanitize struct elements; that should happen downstream.
        assembly ("memory-safe") {
            // originData
            claim := encodedClaim.offset
            mandate := encodedFill.offset
            adjuster := encodedAdjuster
            fillHashes.offset := encodedFillHashes.offset
            fillHashes.length := encodedFillHashes.length

            // fillerData
            adjustment := encodedAdjustment.offset
            claimant := encodedClaimant
            fillBlock := encodedFillBlock
        }
    }
}
