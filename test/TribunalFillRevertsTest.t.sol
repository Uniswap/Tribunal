// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Mandate, Fill, FillComponent, Adjustment, RecipientCallback} from "../src/types/TribunalStructs.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {MANDATE_TYPEHASH, ADJUSTMENT_TYPEHASH} from "../src/types/TribunalTypeHashes.sol";

contract TribunalFillRevertsTest is Test {
    using FixedPointMathLib for uint256;

    Tribunal public tribunal;
    address theCompact;
    address sponsor;
    address adjuster;
    uint256 adjusterPrivateKey;

    uint256[] public emptyPriceCurve;

    receive() external payable {}

    function signAdjustment(Adjustment memory adjustment, bytes32 claimHash, uint256 privateKey)
        internal
        view
        returns (bytes memory)
    {
        bytes32 adjustmentHash = keccak256(
            abi.encode(
                ADJUSTMENT_TYPEHASH,
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function setUp() public {
        theCompact = address(0xC0);
        tribunal = new Tribunal();
        (sponsor,) = makeAddrAndKey("sponsor");
        (adjuster, adjusterPrivateKey) = makeAddrAndKey("adjuster");

        emptyPriceCurve = new uint256[](0);
    }

    function test_fillRevertsOnInvalidTargetBlock() public {
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            recipient: address(0xBEEF),
            applyScaling: true
        });
        
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            components: components,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

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

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: vm.getBlockNumber() + 100,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        vm.expectRevert(
            abi.encodeWithSignature(
                "InvalidTargetBlock(uint256,uint256)",
                vm.getBlockNumber(),
                vm.getBlockNumber() + 100
            )
        );
        tribunal.fill{value: 1 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            fillHashes,
            bytes32(uint256(uint160(address(this)))),
            0
        );
    }

    function test_FillRevertsOnExpiredMandate() public {
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(0xDEAD),
            minimumFillAmount: 1 ether,
            recipient: address(0xCAFE),
            applyScaling: true
        });
        
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: 1703116800,
            components: components,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0xDEAD), amount: 1 ether});

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

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: vm.getBlockNumber(),
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        vm.warp(fill.expires + 1);

        vm.expectRevert(abi.encodeWithSignature("Expired(uint256)", fill.expires));
        tribunal.fill(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            fillHashes,
            bytes32(uint256(uint160(address(this)))),
            0
        );
    }

    function test_FillRevertsOnReusedClaim() public {
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            recipient: address(0xCAFE),
            applyScaling: true
        });
        
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: 1703116800,
            components: components,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        // Use a different chainId to make it a cross-chain fill
        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
            chainId: block.chainid + 1,
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

        // Calculate mandateHash and claimHash for signature
        // Note: The fill function uses _deriveMandateHash internally with fillHashes
        bytes32 mandateHash = keccak256(
            abi.encode(MANDATE_TYPEHASH, adjuster, keccak256(abi.encodePacked(fillHashes)))
        );
        bytes32 claimHash = tribunal.deriveClaimHash(claim.compact, mandateHash);

        // Sign the adjustment
        bytes memory adjustmentSignature = signAdjustment(adjustment, claimHash, adjusterPrivateKey);

        // Send ETH with the first fill
        tribunal.fill{value: 1 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            adjustmentSignature,
            fillHashes,
            bytes32(uint256(uint160(address(this)))),
            0
        );

        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        tribunal.fill{value: 1 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            adjustmentSignature,
            fillHashes,
            bytes32(uint256(uint160(address(this)))),
            0
        );
    }

    function test_FillRevertsOnInvalidGasPrice() public {
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(0xDEAD),
            minimumFillAmount: 1 ether,
            recipient: address(0xCAFE),
            applyScaling: true
        });
        
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: 1703116800,
            components: components,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0xDEAD), amount: 1 ether});

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

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: vm.getBlockNumber(),
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        vm.fee(2 gwei);
        vm.txGasPrice(1 gwei);

        vm.expectRevert(abi.encodeWithSignature("InvalidGasPrice()"));
        tribunal.fill(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            fillHashes,
            bytes32(uint256(uint160(address(this)))),
            0
        );
    }
}
