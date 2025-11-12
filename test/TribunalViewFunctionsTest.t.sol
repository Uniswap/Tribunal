// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {
    Mandate,
    FillParameters,
    FillComponent,
    RecipientCallback,
    DispositionDetails
} from "../src/types/TribunalStructs.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";

contract TribunalViewFunctionsTest is Test {
    Tribunal public tribunal;

    address public adjuster = address(0x3333);
    uint256[] public emptyPriceCurve;

    function setUp() public {
        tribunal = new Tribunal();
        emptyPriceCurve = new uint256[](0);
    }

    function test_getDispositionDetails() public view {
        // Test with array of claim hashes
        bytes32[] memory claimHashes = new bytes32[](2);
        claimHashes[0] = bytes32(uint256(1));
        claimHashes[1] = bytes32(uint256(2));

        DispositionDetails[] memory details = tribunal.getDispositionDetails(claimHashes);

        assertEq(details.length, 2, "Should return two disposition details");
        // Unfilled claims should have zero claimant and 1e18 scaling factor
        assertEq(details[0].claimant, bytes32(0), "Unfilled claim should have zero claimant");
        assertEq(details[0].scalingFactor, 1e18, "Unfilled claim should have 1e18 scaling factor");
    }

    function test_extsload_single() public view {
        // Test single slot reading
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = bytes32(uint256(0)); // Read from slot 0

        bytes32[] memory values = tribunal.extsload(slots);
        assertEq(values.length, 1, "Should return one value");
    }

    function test_extsload_multiple() public view {
        // Test multiple slot reading
        bytes32[] memory slots = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            slots[i] = bytes32(i);
        }

        bytes32[] memory values = tribunal.extsload(slots);
        assertEq(values.length, 5, "Should return five values");
    }

    function test_reentrancyGuardStatus() public view {
        address caller = tribunal.reentrancyGuardStatus();
        assertEq(caller, address(0), "Reentrancy guard should be in unlocked state");
    }

    function test_deriveFillsHash() public view {
        FillComponent[] memory components1 = new FillComponent[](1);
        components1[0] = FillComponent({
            fillToken: address(0x1234),
            minimumFillAmount: 1 ether,
            recipient: address(0x5678),
            applyScaling: true
        });

        FillComponent[] memory components2 = new FillComponent[](1);
        components2[0] = FillComponent({
            fillToken: address(0x9ABC),
            minimumFillAmount: 2 ether,
            recipient: address(0xDEF0),
            applyScaling: false
        });

        FillParameters[] memory fills = new FillParameters[](2);
        fills[0] = FillParameters({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: block.timestamp + 1 days,
            components: components1,
            baselinePriorityFee: 0,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(0)
        });

        fills[1] = FillParameters({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: block.timestamp + 1 days,
            components: components2,
            baselinePriorityFee: 0,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        bytes32 fillsHash = tribunal.deriveFillsHash(fills);
        assertTrue(fillsHash != bytes32(0), "Fills hash should not be zero");

        // Verify consistency
        bytes32 fillsHash2 = tribunal.deriveFillsHash(fills);
        assertEq(fillsHash, fillsHash2, "Hash should be consistent");
    }

    function test_deriveFillComponentHash() public view {
        FillComponent memory component = FillComponent({
            fillToken: address(0x1234),
            minimumFillAmount: 1 ether,
            recipient: address(0x5678),
            applyScaling: true
        });

        bytes32 componentHash = tribunal.deriveFillComponentHash(component);
        assertTrue(componentHash != bytes32(0), "Component hash should not be zero");
    }

    function test_deriveRecipientCallbackHash_empty() public view {
        // Test with empty array
        RecipientCallback[] memory emptyCallbacks = new RecipientCallback[](0);
        bytes32 emptyHash = tribunal.deriveRecipientCallbackHash(emptyCallbacks);
        assertEq(
            emptyHash,
            bytes32(0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470),
            "Empty callback should have zero hash"
        );
    }

    function test_deriveRecipientCallbackHash_withCallback() public view {
        // Test with actual callback
        RecipientCallback[] memory callbacks = new RecipientCallback[](1);

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0x1234), amount: 1 ether});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(this),
            sponsor: address(0x5678),
            nonce: 0,
            expires: uint256(block.timestamp + 1 days),
            commitments: commitments
        });

        callbacks[0] = RecipientCallback({
            chainId: block.chainid,
            compact: compact,
            mandateHash: bytes32(uint256(1)),
            context: abi.encode("test")
        });

        bytes32 callbackHash = tribunal.deriveRecipientCallbackHash(callbacks);
        assertTrue(callbackHash != bytes32(0), "Callback hash should not be zero");
    }

    function test_deriveMandateHash() public view {
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(0xDEAD),
            minimumFillAmount: 1 ether,
            recipient: address(0xCAFE),
            applyScaling: true
        });

        FillParameters[] memory fills = new FillParameters[](1);
        fills[0] = FillParameters({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: block.timestamp + 1 days,
            components: components,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: fills});

        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);
        assertTrue(mandateHash != bytes32(0), "Mandate hash should not be zero");
    }

    function test_deriveClaimHash() public view {
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(0xDEAD),
            minimumFillAmount: 1 ether,
            recipient: address(0xCAFE),
            applyScaling: true
        });

        FillParameters[] memory fills = new FillParameters[](1);
        fills[0] = FillParameters({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: block.timestamp + 1 days,
            components: components,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: fills});

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0xDEAD), amount: 1 ether});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(this),
            sponsor: address(0x1234),
            nonce: 0,
            expires: block.timestamp + 1 hours,
            commitments: commitments
        });

        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);
        bytes32 claimHash = tribunal.deriveClaimHash(compact, mandateHash);

        assertTrue(claimHash != bytes32(0), "Claim hash should not be zero");
    }
}
