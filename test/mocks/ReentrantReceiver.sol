// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Tribunal} from "../../src/Tribunal.sol";
import {Mandate, Fill, RecipientCallback} from "../../src/types/TribunalStructs.sol";
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
        _mandate = Fill({
            recipient: address(this),
            expires: type(uint32).max,
            fillToken: address(0),
            minimumFillAmount: 0,
            baselinePriorityFee: 0,
            scalingFactor: 1e18,
            priceCurve: new uint256[](0),
            recipientCallback: new RecipientCallback[],
            salt: bytes32(uint256(1))
        });
    }

    receive() external payable {
        uint256 quote = _TRIBUNAL.quote(_claim, _mandate, address(this));
        uint256 balanceBefore = address(this).balance;
        try _TRIBUNAL.fill{value: quote}(_claim, _mandate, address(this)) {
            if (address(this).balance < balanceBefore) {
                revert NoProfit(balanceBefore, address(this).balance);
            }
            _claim.compact.nonce++;
        } catch {}
    }

    function getClaim() public view returns (Tribunal.BatchClaim memory) {
        return _claim;
    }

    function getMandate() public view returns (Mandate memory) {
        return _mandate;
    }
}
