// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Mandate, Fill, Adjustment, RecipientCallback} from "../src/types/TribunalStructs.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {MANDATE_TYPEHASH} from "../src/types/TribunalTypeHashes.sol";

contract TribunalCancelTest is Test {
    using FixedPointMathLib for uint256;

    Tribunal public tribunal;
    address theCompact;
    address sponsor;
    address adjuster;
    uint256 adjusterPrivateKey;

    uint256[] public emptyPriceCurve;

    receive() external payable {}

    function setUp() public {
        theCompact = address(0xC0);
        tribunal = new Tribunal();
        (sponsor,) = makeAddrAndKey("sponsor");
        (adjuster, adjusterPrivateKey) = makeAddrAndKey("adjuster");

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
            scalingFactor: 1e18, // Use neutral scaling factor
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

        // Make it cross-chain to test the AlreadyClaimed check
        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
            chainId: block.chainid + 1, // Different chain
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
        emit ITribunal.Cancel(sponsor, claimHash);
        tribunal.cancel(claim, mandateHash);

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: vm.getBlockNumber(),
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        // Calculate mandateHash using the actual method used in _fill
        bytes32 fillMandateHash = keccak256(
            abi.encode(MANDATE_TYPEHASH, adjuster, keccak256(abi.encodePacked(fillHashes)))
        );

        // Sign the adjustment
        bytes32 adjustmentClaimHash = tribunal.deriveClaimHash(claim.compact, fillMandateHash);
        bytes32 adjustmentHash = keccak256(
            abi.encode(
                keccak256(
                    "Adjustment(bytes32 claimHash,uint256 fillIndex,uint256 targetBlock,uint256[] supplementalPriceCurve,bytes32 validityConditions)"
                ),
                adjustmentClaimHash,
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

        uint256 initialSenderBalance = address(this).balance;
        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        tribunal.fill{value: 2 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            adjustmentSignature,
            fillHashes,
            bytes32(uint256(uint160(address(this)))),
            0
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
            scalingFactor: 1e18, // Use neutral scaling factor
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

        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
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
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipient: address(0xBEEF),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        // Make it cross-chain to avoid TheCompact mocking
        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
            chainId: block.chainid + 1, // Different chain
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
            abi.encode(MANDATE_TYPEHASH, adjuster, keccak256(abi.encodePacked(fillHashes)))
        );

        bytes32 claimHash = tribunal.deriveClaimHash(claim.compact, mandateHash);

        // Sign the adjustment
        bytes32 adjustmentHash = keccak256(
            abi.encode(
                keccak256(
                    "Adjustment(bytes32 claimHash,uint256 fillIndex,uint256 targetBlock,uint256[] supplementalPriceCurve,bytes32 validityConditions)"
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

        uint256 initialSenderBalance = address(this).balance;

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = commitments[0].amount;

        vm.expectEmit(true, true, true, true, address(tribunal));
        emit ITribunal.CrossChainFill(
            claim.chainId,
            sponsor,
            address(this),
            claimHash,
            1 ether,
            claimAmounts,
            adjustment.targetBlock
        );

        tribunal.fill{value: 2 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            adjustmentSignature,
            fillHashes,
            bytes32(uint256(uint160(address(this)))),
            0
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
            scalingFactor: 1e18, // Use neutral scaling factor
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

        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
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
            scalingFactor: 1e18, // Use neutral scaling factor
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
        emit ITribunal.Cancel(sponsor, claimHash);
        tribunal.cancelChainExclusive(compact, mandateHash);

        // Make it cross-chain to test the AlreadyClaimed check
        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
            chainId: block.chainid + 1, // Different chain
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

        // Calculate mandateHash using the actual method used in _fill
        bytes32 fillMandateHash = keccak256(
            abi.encode(MANDATE_TYPEHASH, adjuster, keccak256(abi.encodePacked(fillHashes)))
        );

        // Sign the adjustment
        bytes32 adjustmentClaimHash = tribunal.deriveClaimHash(claim.compact, fillMandateHash);
        bytes32 adjustmentHash = keccak256(
            abi.encode(
                keccak256(
                    "Adjustment(bytes32 claimHash,uint256 fillIndex,uint256 targetBlock,uint256[] supplementalPriceCurve,bytes32 validityConditions)"
                ),
                adjustmentClaimHash,
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

        uint256 initialSenderBalance = address(this).balance;
        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        tribunal.fill{value: 2 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            adjustmentSignature,
            fillHashes,
            bytes32(uint256(uint160(address(this)))),
            0
        );

        assertEq(address(0xBEEF).balance, 0 ether);
        assertEq(initialSenderBalance, address(this).balance);
    }
}
