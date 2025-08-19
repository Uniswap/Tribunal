// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import "../src/types/TribunalTypeHashes.sol";

contract TribunalTypeHashesTest is Test {
    // Expected hash values from Tribunal.sol
    bytes32 constant EXPECTED_MANDATE_TYPEHASH =
        0x78eb489c4f76cd1d9bc735e1f4e8369b94ed75b11b35b0d5882f9c4c856a7a90;
    bytes32 constant EXPECTED_MANDATE_FILL_TYPEHASH =
        0x02ccd0f55bde7e5174b479837dce09e4f95101b3b6dfc43be8d6d42a9bd66590;
    bytes32 constant EXPECTED_MANDATE_RECIPIENT_CALLBACK_TYPEHASH =
        0x4fc45936139e9bc61053b9f1f238d4205ccd3dddaf02907ca21557ffd35160ae;
    bytes32 constant EXPECTED_MANDATE_BATCH_COMPACT_TYPEHASH =
        0xd1b7b490818c27a08c0bf3264fa04437fb7d4e669ade6acb8e5dde31e2d0b1c2;
    bytes32 constant EXPECTED_MANDATE_LOCK_TYPEHASH =
        0xce4f0854d9091f37d9dfb64592eee0de534c6680a5444fd55739b61228a6e0b0;
    bytes32 constant EXPECTED_COMPACT_TYPEHASH_WITH_MANDATE =
        0xab0a4c35b998b2b78c7b8f899e1423371e4fbed77d7c8e4fc3b03816cea512a5;
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
