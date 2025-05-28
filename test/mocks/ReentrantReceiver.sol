// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Tribunal} from "../../src/Tribunal.sol";

contract ReentrantReceiver {
    error NoProfit(uint256 balanceBefore, uint256 balanceAfter);

    Tribunal private immutable _TRIBUNAL;
    Tribunal.Claim private _claim;
    Tribunal.Mandate private _mandate;

    constructor(Tribunal _tribunal) payable {
        _TRIBUNAL = _tribunal;
        _claim = Tribunal.Claim({
            chainId: 1,
            compact: Tribunal.Compact({
                arbiter: address(this),
                sponsor: address(this),
                nonce: 0,
                expires: type(uint32).max,
                id: 0,
                amount: 0
            }),
            sponsorSignature: new bytes(0),
            allocatorSignature: new bytes(0)
        });
        _mandate = Tribunal.Mandate({
            recipient: address(this),
            expires: type(uint32).max,
            token: address(0),
            minimumAmount: 0,
            baselinePriorityFee: 0,
            scalingFactor: 1e18,
            decayCurve: new uint256[](0),
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

    function getClaim() public view returns (Tribunal.Claim memory) {
        return _claim;
    }

    function getMandate() public view returns (Tribunal.Mandate memory) {
        return _mandate;
    }
}
