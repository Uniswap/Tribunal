// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import "../src/types/TribunalTypeHashes.sol";

contract TribunalTypeHashesTest is Test {
    // Expected hash values from Tribunal.sol
    bytes32 constant EXPECTED_MANDATE_TYPEHASH =
        0xd98eceb6e5c7770b3b664a99c269855402fe5255294a30970d25376caea662c6;
    bytes32 constant EXPECTED_MANDATE_FILL_TYPEHASH =
        0x1d0ee69a7bc1ac54d9a6b38f32ab156fbfe09a9098843d54f89e7b1033533d33;
    bytes32 constant EXPECTED_MANDATE_RECIPIENT_CALLBACK_TYPEHASH =
        0xb60a17eb6828a433f2f2fcbeb119166fa25e1fb6ae3866e33952bb74f5055031;
    bytes32 constant EXPECTED_MANDATE_BATCH_COMPACT_TYPEHASH =
        0x75d7205b7ec9e9b203d9161387d95a46c8440f4530dceab1bb28d4194a586227;
    bytes32 constant EXPECTED_MANDATE_LOCK_TYPEHASH =
        0xce4f0854d9091f37d9dfb64592eee0de534c6680a5444fd55739b61228a6e0b0;
    bytes32 constant EXPECTED_COMPACT_TYPEHASH_WITH_MANDATE =
        0xdbbdcf42471b4a26f7824df9f33f0a4f9bb4e7a66be6a31be8868a6cbbec0a7d;
    bytes32 constant EXPECTED_ADJUSTMENT_TYPEHASH =
        0xe829b2a82439f37ac7578a226e337d334e0ee0da2f05ab63891c19cb84714414;

    function test_MandateTypeHashMatchesKeccak() public pure {
        bytes32 computed = keccak256(bytes(MANDATE_TYPESTRING));
        assertEq(
            computed,
            MANDATE_TYPEHASH,
            "MANDATE_TYPEHASH should match keccak256 of MANDATE_TYPESTRING"
        );
        assertEq(
            MANDATE_TYPEHASH,
            EXPECTED_MANDATE_TYPEHASH,
            "MANDATE_TYPEHASH should match expected value from Tribunal.sol"
        );
    }

    function test_MandateFillTypeHashMatchesKeccak() public pure {
        bytes32 computed = keccak256(bytes(MANDATE_FILL_TYPESTRING));
        assertEq(
            computed,
            MANDATE_FILL_TYPEHASH,
            "MANDATE_FILL_TYPEHASH should match keccak256 of MANDATE_FILL_TYPESTRING"
        );
        assertEq(
            MANDATE_FILL_TYPEHASH,
            EXPECTED_MANDATE_FILL_TYPEHASH,
            "MANDATE_FILL_TYPEHASH should match expected value from Tribunal.sol"
        );
    }

    function test_MandateRecipientCallbackTypeHashMatchesKeccak() public pure {
        bytes32 computed = keccak256(bytes(MANDATE_RECIPIENT_CALLBACK_TYPESTRING));
        assertEq(
            computed,
            MANDATE_RECIPIENT_CALLBACK_TYPEHASH,
            "MANDATE_RECIPIENT_CALLBACK_TYPEHASH should match keccak256 of MANDATE_RECIPIENT_CALLBACK_TYPESTRING"
        );
        assertEq(
            MANDATE_RECIPIENT_CALLBACK_TYPEHASH,
            EXPECTED_MANDATE_RECIPIENT_CALLBACK_TYPEHASH,
            "MANDATE_RECIPIENT_CALLBACK_TYPEHASH should match expected value from Tribunal.sol"
        );
    }

    function test_MandateBatchCompactTypeHashMatchesKeccak() public pure {
        bytes32 computed = keccak256(bytes(MANDATE_BATCH_COMPACT_TYPESTRING));
        assertEq(
            computed,
            MANDATE_BATCH_COMPACT_TYPEHASH,
            "MANDATE_BATCH_COMPACT_TYPEHASH should match keccak256 of MANDATE_BATCH_COMPACT_TYPESTRING"
        );
        assertEq(
            MANDATE_BATCH_COMPACT_TYPEHASH,
            EXPECTED_MANDATE_BATCH_COMPACT_TYPEHASH,
            "MANDATE_BATCH_COMPACT_TYPEHASH should match expected value from Tribunal.sol"
        );
    }

    function test_MandateLockTypeHashMatchesKeccak() public pure {
        bytes32 computed = keccak256(bytes(MANDATE_LOCK_TYPESTRING));
        assertEq(
            computed,
            MANDATE_LOCK_TYPEHASH,
            "MANDATE_LOCK_TYPEHASH should match keccak256 of MANDATE_LOCK_TYPESTRING"
        );
        assertEq(
            MANDATE_LOCK_TYPEHASH,
            EXPECTED_MANDATE_LOCK_TYPEHASH,
            "MANDATE_LOCK_TYPEHASH should match expected value from Tribunal.sol"
        );
    }

    function test_CompactWithMandateTypeHashMatchesKeccak() public pure {
        bytes32 computed = keccak256(bytes(COMPACT_WITH_MANDATE_TYPESTRING));
        assertEq(
            computed,
            COMPACT_TYPEHASH_WITH_MANDATE,
            "COMPACT_TYPEHASH_WITH_MANDATE should match keccak256 of COMPACT_WITH_MANDATE_TYPESTRING"
        );
        assertEq(
            COMPACT_TYPEHASH_WITH_MANDATE,
            EXPECTED_COMPACT_TYPEHASH_WITH_MANDATE,
            "COMPACT_TYPEHASH_WITH_MANDATE should match expected value from Tribunal.sol"
        );
    }

    function test_AdjustmentTypeHashMatchesKeccak() public pure {
        bytes32 computed = keccak256(bytes(ADJUSTMENT_TYPESTRING));
        assertEq(
            computed,
            ADJUSTMENT_TYPEHASH,
            "ADJUSTMENT_TYPEHASH should match keccak256 of ADJUSTMENT_TYPESTRING"
        );
        assertEq(
            ADJUSTMENT_TYPEHASH,
            EXPECTED_ADJUSTMENT_TYPEHASH,
            "ADJUSTMENT_TYPEHASH should match expected value from Tribunal.sol"
        );
    }

    function test_TypeStringFormats() public pure {
        // Verify type strings are non-empty
        assertTrue(bytes(MANDATE_TYPESTRING).length > 0, "MANDATE_TYPESTRING should not be empty");
        assertTrue(
            bytes(MANDATE_FILL_TYPESTRING).length > 0, "MANDATE_FILL_TYPESTRING should not be empty"
        );
        assertTrue(
            bytes(MANDATE_RECIPIENT_CALLBACK_TYPESTRING).length > 0,
            "MANDATE_RECIPIENT_CALLBACK_TYPESTRING should not be empty"
        );
        assertTrue(
            bytes(MANDATE_BATCH_COMPACT_TYPESTRING).length > 0,
            "MANDATE_BATCH_COMPACT_TYPESTRING should not be empty"
        );
        assertTrue(
            bytes(MANDATE_LOCK_TYPESTRING).length > 0, "MANDATE_LOCK_TYPESTRING should not be empty"
        );
        assertTrue(
            bytes(COMPACT_WITH_MANDATE_TYPESTRING).length > 0,
            "COMPACT_WITH_MANDATE_TYPESTRING should not be empty"
        );
        assertTrue(
            bytes(ADJUSTMENT_TYPESTRING).length > 0, "ADJUSTMENT_TYPESTRING should not be empty"
        );
        assertTrue(bytes(WITNESS_TYPESTRING).length > 0, "WITNESS_TYPESTRING should not be empty");
    }

    function test_PrintTypeHashes() public view {
        console.log("MANDATE_TYPEHASH:");
        console.logBytes32(keccak256(bytes(MANDATE_TYPESTRING)));

        console.log("MANDATE_FILL_TYPEHASH:");
        console.logBytes32(keccak256(bytes(MANDATE_FILL_TYPESTRING)));

        console.log("MANDATE_RECIPIENT_CALLBACK_TYPEHASH:");
        console.logBytes32(keccak256(bytes(MANDATE_RECIPIENT_CALLBACK_TYPESTRING)));

        console.log("MANDATE_BATCH_COMPACT_TYPEHASH:");
        console.logBytes32(keccak256(bytes(MANDATE_BATCH_COMPACT_TYPESTRING)));

        console.log("MANDATE_LOCK_TYPEHASH:");
        console.logBytes32(keccak256(bytes(MANDATE_LOCK_TYPESTRING)));

        console.log("COMPACT_TYPEHASH_WITH_MANDATE:");
        console.logBytes32(keccak256(bytes(COMPACT_WITH_MANDATE_TYPESTRING)));

        console.log("ADJUSTMENT_TYPEHASH:");
        console.logBytes32(keccak256(bytes(ADJUSTMENT_TYPESTRING)));
    }
}
