// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Tribunal} from "../../src/Tribunal.sol";
import {ITribunal} from "../../src/interfaces/ITribunal.sol";
import {
    Mandate,
    FillParameters,
    FillComponent,
    RecipientCallback,
    Adjustment,
    BatchClaim
} from "../../src/types/TribunalStructs.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";

contract ReentrantReceiver {
    error NoProfit(uint256 balanceBefore, uint256 balanceAfter);

    Tribunal private immutable _TRIBUNAL;
    BatchClaim private _claim;
    FillParameters private _fillParams;

    constructor(Tribunal _tribunal) payable {
        _TRIBUNAL = _tribunal;

        // Initialize storage variables field by field to avoid memory-to-storage copy issues
        _claim.compact.arbiter = address(this);
        _claim.compact.sponsor = address(this);
        _claim.compact.nonce = 0;
        _claim.compact.expires = type(uint32).max;
        // commitments array is already empty by default

        // Initialize _fillParams fields directly
        _fillParams.chainId = block.chainid;
        _fillParams.tribunal = address(_TRIBUNAL);
        _fillParams.expires = type(uint32).max;
        _fillParams.baselinePriorityFee = 0;
        _fillParams.scalingFactor = 1e18;
        _fillParams.salt = bytes32(uint256(1));

        // Initialize components array by pushing to it
        _fillParams.components
            .push(
                FillComponent({
                    fillToken: address(0),
                    minimumFillAmount: 0,
                    recipient: address(this),
                    applyScaling: true
                })
            );
    }

    receive() external payable {
        Adjustment memory adjustment = Adjustment({
            adjuster: address(this),
            fillIndex: 0,
            targetBlock: block.number,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0),
            adjustmentAuthorization: new bytes(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = _TRIBUNAL.deriveFillHash(_fillParams);

        uint256 balanceBefore = address(this).balance;
        try _TRIBUNAL.fill(
            _claim.compact,
            _fillParams,
            adjustment,
            fillHashes,
            bytes32(uint256(uint160(address(this)))),
            0
        ) {
            if (address(this).balance < balanceBefore) {
                revert NoProfit(balanceBefore, address(this).balance);
            }
            _claim.compact.nonce++;
        } catch {}
    }

    function getMandate() public view returns (FillParameters memory) {
        return _fillParams;
    }

    function getClaim() public view returns (BatchClaim memory) {
        return _claim;
    }
}
