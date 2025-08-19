// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Tribunal} from "../../src/Tribunal.sol";
import {Mandate, Fill, RecipientCallback, Adjustment} from "../../src/types/TribunalStructs.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";

contract ReentrantReceiver {
    error NoProfit(uint256 balanceBefore, uint256 balanceAfter);

    Tribunal private immutable _TRIBUNAL;
    Tribunal.BatchClaim private _claim;
    Mandate private _mandate;

    constructor(Tribunal _tribunal) payable {
        _TRIBUNAL = _tribunal;
        _claim = Tribunal.BatchClaim({
            chainId: 1,
            compact: BatchCompact({
                arbiter: address(this),
                sponsor: address(this),
                nonce: 0,
                expires: type(uint32).max,
                commitments: new Lock[](0)
            }),
            sponsorSignature: new bytes(0),
            allocatorSignature: new bytes(0)
        });
        _mandate = Mandate({adjuster: address(this), fills: new Fill[](1)});
        _mandate.fills[0] = Fill({
            chainId: block.chainid,
            tribunal: address(_TRIBUNAL),
            expires: type(uint32).max,
            fillToken: address(0),
            minimumFillAmount: 0,
            baselinePriorityFee: 0,
            scalingFactor: 1e18,
            priceCurve: new uint256[](0),
            recipient: address(this),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });
    }

    receive() external payable {
        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: block.number,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = _TRIBUNAL.deriveFillHash(_mandate.fills[0]);

        uint256 quote = _TRIBUNAL.quote(
            _claim,
            _mandate.fills[0],
            address(this),
            adjustment,
            fillHashes,
            bytes32(uint256(uint160(address(this)))),
            block.number
        );
        uint256 balanceBefore = address(this).balance;
        try _TRIBUNAL.fill{value: quote}(
            _claim,
            _mandate.fills[0],
            address(this),
            adjustment,
            new bytes(0),
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

    function getMandate() public view returns (Fill memory) {
        return _mandate.fills[0];
    }

    function getClaim() public view returns (Tribunal.BatchClaim memory) {
        return _claim;
    }
}
