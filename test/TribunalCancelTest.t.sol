// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Mandate, Fill, Adjustment, RecipientCallback} from "../src/types/TribunalStructs.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";

contract TribunalCancelTest is Test {
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

    function test_cancelSuccessfully() public {
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            priceCurve: emptyPriceCurve,
            recipient: address(0xBEEF),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandateStruct = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandateStruct.fills[0] = fill;

        bytes32 mandateHash = tribunal.deriveMandateHash(mandateStruct);

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

        bytes32 claimHash = tribunal.deriveClaimHash(claim.compact, mandateHash);

        vm.prank(sponsor);
        vm.expectEmit(true, false, false, false, address(tribunal));
        emit Tribunal.Cancel(sponsor, claimHash);
        tribunal.cancel(claim, mandateHash);

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: vm.getBlockNumber(),
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        uint256 initialSenderBalance = address(this).balance;
        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        tribunal.fill{value: 2 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            0,
            fillHashes,
            bytes32(uint256(uint160(address(this))))
        );

        assertEq(address(0xBEEF).balance, 0 ether);
        assertEq(initialSenderBalance, address(this).balance);
    }

    function test_cancelRevertsOnInvalidSponsor(address attacker) public {
        vm.assume(attacker != sponsor);
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            priceCurve: emptyPriceCurve,
            recipient: address(0xBEEF),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandateStruct = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandateStruct.fills[0] = fill;

        bytes32 mandateHash = tribunal.deriveMandateHash(mandateStruct);

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

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotSponsor()"));
        tribunal.cancel(claim, mandateHash);
    }

    function test_cancelRevertsOnFilledClaim() public {
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            priceCurve: emptyPriceCurve,
            recipient: address(0xBEEF),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandateStruct = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandateStruct.fills[0] = fill;

        bytes32 mandateHash = tribunal.deriveMandateHash(mandateStruct);

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

        uint256 initialSenderBalance = address(this).balance;
        bytes32 claimHash = tribunal.deriveClaimHash(claim.compact, mandateHash);
        vm.expectEmit(true, true, true, true, address(tribunal));
        emit Tribunal.SingleChainFill(
            sponsor, address(this), claimHash, 1 ether, new uint256[](1), adjustment.targetBlock
        );
        tribunal.fill{value: 2 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            0,
            fillHashes,
            bytes32(uint256(uint160(address(this))))
        );

        assertEq(address(0xBEEF).balance, fill.minimumFillAmount);
        assertEq(address(this).balance, initialSenderBalance - fill.minimumFillAmount);

        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        tribunal.cancel(claim, mandateHash);
    }

    function test_cancelRevertsOnExpiredMandate(uint8 expires) public {
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(expires),
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            priceCurve: emptyPriceCurve,
            recipient: address(0xBEEF),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandateStruct = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandateStruct.fills[0] = fill;

        bytes32 mandateHash = tribunal.deriveMandateHash(mandateStruct);

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

        vm.warp(fill.expires + 1);

        vm.prank(sponsor);
        tribunal.cancel(claim, mandateHash); // Note: No revert expected for expiration in cancel
    }

    function test_cancelSuccessfullyChainExclusive() public {
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            priceCurve: emptyPriceCurve,
            recipient: address(0xBEEF),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandateStruct = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandateStruct.fills[0] = fill;

        bytes32 mandateHash = tribunal.deriveMandateHash(mandateStruct);

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(this),
            sponsor: sponsor,
            nonce: 0,
            expires: block.timestamp + 1 hours,
            commitments: commitments
        });

        bytes32 claimHash = tribunal.deriveClaimHash(compact, mandateHash);

        vm.prank(sponsor);
        vm.expectEmit(true, false, false, false, address(tribunal));
        emit Tribunal.Cancel(sponsor, claimHash);
        tribunal.cancelChainExclusive(compact, mandateHash);

        Tribunal.BatchClaim memory claim = Tribunal.BatchClaim({
            chainId: block.chainid,
            compact: compact,
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

        uint256 initialSenderBalance = address(this).balance;
        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        tribunal.fill{value: 2 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            0,
            fillHashes,
            bytes32(uint256(uint160(address(this))))
        );

        assertEq(address(0xBEEF).balance, 0 ether);
        assertEq(initialSenderBalance, address(this).balance);
    }
}
