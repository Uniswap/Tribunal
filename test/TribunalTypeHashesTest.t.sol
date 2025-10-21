// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import "../src/types/TribunalTypeHashes.sol";

contract TribunalTypeHashesTest is Test {
    function test_MandateTypeHashMatchesKeccak() public pure {
        bytes32 computed = keccak256(bytes(MANDATE_TYPESTRING));
        assertEq(
            computed,
            MANDATE_TYPEHASH,
            "MANDATE_TYPEHASH constant should match keccak256 of MANDATE_TYPESTRING"
        );
    }

    function test_MandateFillTypeHashMatchesKeccak() public pure {
        bytes32 computed = keccak256(bytes(MANDATE_FILL_TYPESTRING));
        assertEq(
            computed,
            MANDATE_FILL_TYPEHASH,
            "MANDATE_FILL_TYPEHASH constant should match keccak256 of MANDATE_FILL_TYPESTRING"
        );
    }

    function test_MandateFillComponentTypeHashMatchesKeccak() public pure {
        bytes32 computed = keccak256(bytes(MANDATE_FILL_COMPONENT_TYPESTRING));
        assertEq(
            computed,
            MANDATE_FILL_COMPONENT_TYPEHASH,
            "MANDATE_FILL_COMPONENT_TYPEHASH constant should match keccak256 of MANDATE_FILL_COMPONENT_TYPESTRING"
        );
    }

    function test_MandateRecipientCallbackTypeHashMatchesKeccak() public pure {
        bytes32 computed = keccak256(bytes(MANDATE_RECIPIENT_CALLBACK_TYPESTRING));
        assertEq(
            computed,
            MANDATE_RECIPIENT_CALLBACK_TYPEHASH,
            "MANDATE_RECIPIENT_CALLBACK_TYPEHASH constant should match keccak256 of MANDATE_RECIPIENT_CALLBACK_TYPESTRING"
        );
    }

    function test_MandateBatchCompactTypeHashMatchesKeccak() public pure {
        bytes32 computed = keccak256(bytes(MANDATE_BATCH_COMPACT_TYPESTRING));
        assertEq(
            computed,
            MANDATE_BATCH_COMPACT_TYPEHASH,
            "MANDATE_BATCH_COMPACT_TYPEHASH constant should match keccak256 of MANDATE_BATCH_COMPACT_TYPESTRING"
        );
    }

    function test_MandateLockTypeHashMatchesKeccak() public pure {
        bytes32 computed = keccak256(bytes(MANDATE_LOCK_TYPESTRING));
        assertEq(
            computed,
            MANDATE_LOCK_TYPEHASH,
            "MANDATE_LOCK_TYPEHASH constant should match keccak256 of MANDATE_LOCK_TYPESTRING"
        );
    }

    function test_CompactWithMandateTypeHashMatchesKeccak() public pure {
        bytes32 computed = keccak256(bytes(COMPACT_WITH_MANDATE_TYPESTRING));
        assertEq(
            computed,
            COMPACT_TYPEHASH_WITH_MANDATE,
            "COMPACT_TYPEHASH_WITH_MANDATE constant should match keccak256 of COMPACT_WITH_MANDATE_TYPESTRING"
        );
    }

    function test_AdjustmentTypeHashMatchesKeccak() public pure {
        bytes32 computed = keccak256(bytes(ADJUSTMENT_TYPESTRING));
        assertEq(
            computed,
            ADJUSTMENT_TYPEHASH,
            "ADJUSTMENT_TYPEHASH constant should match keccak256 of ADJUSTMENT_TYPESTRING"
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
}
