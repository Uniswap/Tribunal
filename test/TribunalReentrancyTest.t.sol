// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrantReceiver} from "./mocks/ReentrantReceiver.sol";
import {Mandate, Fill, Adjustment, RecipientCallback} from "../src/types/TribunalStructs.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";

contract TribunalReentrancyTest is Test {
    using FixedPointMathLib for uint256;

    Tribunal public tribunal;
    address theCompact;
    address sponsor;
    address adjuster;

    uint256[] public emptyPriceCurve;

    receive() external payable {}

    function setUp() public {
        theCompact = address(0xC0);
        tribunal = new Tribunal(theCompact);
        (sponsor,) = makeAddrAndKey("sponsor");
        (adjuster,) = makeAddrAndKey("adjuster");

        emptyPriceCurve = new uint256[](0);
    }

    function test_FillWithReentrancyAttack() public {
        ReentrantReceiver reentrantReceiver = new ReentrantReceiver{value: 10 ether}(tribunal);

        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            priceCurve: emptyPriceCurve,
            recipient: address(reentrantReceiver),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        Tribunal.BatchClaim memory claim = Tribunal.BatchClaim({
            chainId: block.chainid,
            compact: BatchCompact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: new bytes(0),
            allocatorSignature: new bytes(0)
        });

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: vm.getBlockNumber(),
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        uint256 initialRecipientBalance = address(reentrantReceiver).balance;

        uint256 initialSenderBalance = address(this).balance;

        Tribunal.BatchClaim memory reentrantClaim = reentrantReceiver.getClaim();
        Fill memory reentrantFill = reentrantReceiver.getMandate();
        vm.expectCall(
            address(tribunal),
            abi.encodeCall(
                Tribunal.fill,
                (
                    reentrantClaim,
                    reentrantFill,
                    address(reentrantReceiver),
                    adjustment,
                    new bytes(0),
                    0,
                    fillHashes,
                    bytes32(uint256(uint160(address(reentrantReceiver))))
                )
            )
        );
        tribunal.fill{value: 5 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            0,
            fillHashes,
            bytes32(uint256(uint160(address(this))))
        );

        assertEq(
            address(reentrantReceiver).balance, initialRecipientBalance + fill.minimumFillAmount
        );
        assertEq(address(this).balance, initialSenderBalance - fill.minimumFillAmount);
    }
}
