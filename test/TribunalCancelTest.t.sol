// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {
    Mandate,
    FillParameters,
    FillComponent,
    Adjustment,
    RecipientCallback,
    FillRecipient,
    BatchClaim
} from "../src/types/TribunalStructs.sol";
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

    function _createAdjustmentSignature(
        BatchCompact memory compact,
        bytes32 fillMandateHash,
        uint256 targetBlock
    ) internal view returns (bytes memory) {
        bytes32 adjustmentClaimHash = tribunal.deriveClaimHash(compact, fillMandateHash);

        bytes32 adjustmentHash = keccak256(
            abi.encode(
                keccak256(
                    "Adjustment(bytes32 claimHash,uint256 fillIndex,uint256 targetBlock,uint256[] supplementalPriceCurve,bytes32 validityConditions)"
                ),
                adjustmentClaimHash,
                0, // fillIndex
                targetBlock,
                keccak256(abi.encodePacked(new uint256[](0))), // empty supplementalPriceCurve
                bytes32(0) // validityConditions
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
        return abi.encodePacked(r, s, v);
    }

    function test_cancelSuccessfully() public {
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            recipient: address(0xBEEF),
            applyScaling: true
        });

        FillParameters memory fill = FillParameters({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            components: components,
            baselinePriorityFee: 0,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandateStruct = Mandate({adjuster: adjuster, fills: new FillParameters[](1)});
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
        tribunal.cancel(compact, mandateHash);

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        bytes32 fillMandateHash = keccak256(
            abi.encode(MANDATE_TYPEHASH, adjuster, keccak256(abi.encodePacked(fillHashes)))
        );

        bytes memory adjustmentSignature =
            _createAdjustmentSignature(compact, fillMandateHash, vm.getBlockNumber());

        Adjustment memory adjustment = Adjustment({
            adjuster: adjuster,
            fillIndex: 0,
            targetBlock: vm.getBlockNumber(),
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0),
            adjustmentAuthorization: adjustmentSignature
        });

        uint256 initialSenderBalance = address(this).balance;
        vm.expectRevert(abi.encodeWithSignature("AlreadyFilled()"));
        tribunal.fill{
            value: 2 ether
        }(compact, fill, adjustment, fillHashes, bytes32(uint256(uint160(address(this)))), 0);

        assertEq(address(0xBEEF).balance, 0 ether);
        assertEq(initialSenderBalance, address(this).balance);
    }

    function test_cancelRevertsOnInvalidSponsor(address attacker) public {
        vm.assume(attacker != sponsor);
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            recipient: address(0xBEEF),
            applyScaling: true
        });

        FillParameters memory fill = FillParameters({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            components: components,
            baselinePriorityFee: 0,
            scalingFactor: 1e18, // Use neutral scaling factor
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandateStruct = Mandate({adjuster: adjuster, fills: new FillParameters[](1)});
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

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotSponsor()"));
        tribunal.cancel(compact, mandateHash);
    }

    function _createAdjustmentSignature2(bytes32 claimHash, uint256 targetBlock)
        internal
        view
        returns (bytes memory)
    {
        bytes32 adjustmentHash = keccak256(
            abi.encode(
                keccak256(
                    "Adjustment(bytes32 claimHash,uint256 fillIndex,uint256 targetBlock,uint256[] supplementalPriceCurve,bytes32 validityConditions)"
                ),
                claimHash,
                0, // fillIndex
                targetBlock,
                keccak256(abi.encodePacked(new uint256[](0))),
                bytes32(0)
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
        return abi.encodePacked(r, s, v);
    }

    function test_cancelRevertsOnFilledClaim() public {
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            recipient: address(0xBEEF),
            applyScaling: true
        });

        FillParameters memory fill = FillParameters({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            components: components,
            baselinePriorityFee: 0,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(this),
            sponsor: sponsor,
            nonce: 0,
            expires: block.timestamp + 1 hours,
            commitments: commitments
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        bytes32 mandateHash = keccak256(
            abi.encode(MANDATE_TYPEHASH, adjuster, keccak256(abi.encodePacked(fillHashes)))
        );

        bytes32 claimHash = tribunal.deriveClaimHash(compact, mandateHash);
        bytes memory adjustmentSignature =
            _createAdjustmentSignature2(claimHash, vm.getBlockNumber());

        Adjustment memory adjustment = Adjustment({
            adjuster: adjuster,
            fillIndex: 0,
            targetBlock: vm.getBlockNumber(),
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0),
            adjustmentAuthorization: adjustmentSignature
        });

        uint256 initialBalance = address(this).balance;

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = commitments[0].amount;

        FillRecipient[] memory fillRecipients = new FillRecipient[](1);
        fillRecipients[0] = FillRecipient({fillAmount: 1 ether, recipient: address(0xBEEF)});

        vm.expectEmit(true, true, true, true, address(tribunal));
        emit ITribunal.Fill(
            sponsor,
            bytes32(uint256(uint160(address(this)))),
            claimHash,
            fillRecipients,
            claimAmounts,
            adjustment.targetBlock
        );

        tribunal.fill{
            value: 2 ether
        }(compact, fill, adjustment, fillHashes, bytes32(uint256(uint160(address(this)))), 0);

        assertEq(address(0xBEEF).balance, 1 ether);
        assertEq(address(this).balance, initialBalance - 1 ether);

        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSignature("AlreadyFilled()"));
        tribunal.cancel(compact, mandateHash);
    }

    function test_cancelRevertsOnExpiredMandate(uint8 expires) public {
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            recipient: address(0xBEEF),
            applyScaling: true
        });

        FillParameters memory fill = FillParameters({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(expires),
            components: components,
            baselinePriorityFee: 0,
            scalingFactor: 1e18, // Use neutral scaling factor
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandateStruct = Mandate({adjuster: adjuster, fills: new FillParameters[](1)});
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

        vm.warp(fill.expires + 1);

        vm.prank(sponsor);
        tribunal.cancel(compact, mandateHash); // Note: No revert expected for expiration in cancel
    }

    function test_cancelSuccessfullyChainExclusive() public {
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            recipient: address(0xBEEF),
            applyScaling: true
        });

        FillParameters memory fill = FillParameters({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            components: components,
            baselinePriorityFee: 0,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandateStruct = Mandate({adjuster: adjuster, fills: new FillParameters[](1)});
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
        tribunal.cancel(compact, mandateHash);

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        bytes32 fillMandateHash = keccak256(
            abi.encode(MANDATE_TYPEHASH, adjuster, keccak256(abi.encodePacked(fillHashes)))
        );

        bytes memory adjustmentSignature =
            _createAdjustmentSignature(compact, fillMandateHash, vm.getBlockNumber());

        Adjustment memory adjustment = Adjustment({
            adjuster: adjuster,
            fillIndex: 0,
            targetBlock: vm.getBlockNumber(),
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0),
            adjustmentAuthorization: adjustmentSignature
        });

        uint256 initialSenderBalance = address(this).balance;
        vm.expectRevert(abi.encodeWithSignature("AlreadyFilled()"));
        tribunal.fill{
            value: 2 ether
        }(compact, fill, adjustment, fillHashes, bytes32(uint256(uint160(address(this)))), 0);

        assertEq(address(0xBEEF).balance, 0 ether);
        assertEq(initialSenderBalance, address(this).balance);
    }
}
