// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrantReceiver} from "./mocks/ReentrantReceiver.sol";
import {MockTheCompact} from "./mocks/MockTheCompact.sol";
import {ITribunalCallback} from "../src/Interfaces/ITribunalCallback.sol";
import {Mandate, Fill, Adjustment, RecipientCallback} from "../src/types/TribunalStructs.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";

contract TribunalReentrancyTest is Test, ITribunalCallback {
    using FixedPointMathLib for uint256;

    Tribunal public tribunal;
    address theCompact;
    address sponsor;
    address adjuster;
    uint256 adjusterPrivateKey;

    uint256[] public emptyPriceCurve;

    receive() external payable {}

    function setUp() public {
        MockTheCompact mockCompact = new MockTheCompact();
        theCompact = address(mockCompact);
        tribunal = new Tribunal(theCompact);
        (sponsor,) = makeAddrAndKey("sponsor");
        (adjuster, adjusterPrivateKey) = makeAddrAndKey("adjuster");

        emptyPriceCurve = new uint256[](0);
    }

    // Implement ITribunalCallback
    function tribunalCallback(
        bytes32,
        Lock[] calldata,
        uint256[] calldata,
        address,
        uint256,
        uint256
    ) external {
        // Empty implementation for testing
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
            scalingFactor: 1e18, // Use neutral scaling factor
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

        // Calculate mandateHash using the actual method used in _fill
        bytes32 mandateHash = keccak256(
            abi.encode(
                keccak256(
                    "Mandate(uint256 chainId,address tribunal,address adjuster,bytes32 fills)"
                ),
                block.chainid,
                address(tribunal),
                adjuster,
                keccak256(abi.encodePacked(fillHashes))
            )
        );

        // For same-chain fills, the claimHash will be what MockTheCompact returns
        bytes32 claimHash = bytes32(uint256(0x5ab5d4a8ba29d5317682f2808ad60826cc75eb191581bea9f13d498a6f8e6311));

        // Sign the adjustment
        bytes32 adjustmentHash = keccak256(
            abi.encode(
                keccak256(
                    "Adjustment(bytes32 claimHash,uint256 fillIndex,uint256 targetBlock,bytes32 supplementalPriceCurve,bytes32 validityConditions)"
                ),
                claimHash,
                adjustment.fillIndex,
                adjustment.targetBlock,
                keccak256(abi.encodePacked(adjustment.supplementalPriceCurve)),
                adjustment.validityConditions
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Tribunal"),
                keccak256("1"),
                block.chainid,
                address(tribunal)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, adjustmentHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adjusterPrivateKey, digest);
        bytes memory adjustmentSignature = abi.encodePacked(r, s, v);

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
            adjustmentSignature,
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
