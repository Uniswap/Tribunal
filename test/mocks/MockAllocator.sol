// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOnChainAllocation} from "the-compact/src/interfaces/IOnChainAllocation.sol";

/**
 * @title MockAllocator
 * @notice Mock allocator contract for testing _handleOnChainAllocation
 * @dev Validates that expected calldata is received in prepareAllocation and executeAllocation
 */
contract MockAllocator is IOnChainAllocation {
    // Storage for validation
    struct PrepareAllocationCall {
        address recipient;
        uint256[2][] idsAndAmounts;
        address arbiter;
        uint256 expires;
        bytes32 typehash;
        bytes32 witness;
        bytes orderData;
        bool wasCalled;
    }

    struct ExecuteAllocationCall {
        address recipient;
        uint256[2][] idsAndAmounts;
        address arbiter;
        uint256 expires;
        bytes32 typehash;
        bytes32 witness;
        bytes orderData;
        bool wasCalled;
    }

    PrepareAllocationCall public lastPrepareCall;
    ExecuteAllocationCall public lastExecuteCall;

    uint256 public nonceToReturn;
    bool public shouldRevertOnPrepare;
    bool public shouldRevertOnExecute;

    constructor() {
        nonceToReturn = 1; // Default nonce
    }

    /**
     * @notice Sets the nonce to return from prepareAllocation
     */
    function setNonceToReturn(uint256 _nonce) external {
        nonceToReturn = _nonce;
    }

    /**
     * @notice Configure revert behavior
     */
    function setShouldRevert(bool _shouldRevertOnPrepare, bool _shouldRevertOnExecute) external {
        shouldRevertOnPrepare = _shouldRevertOnPrepare;
        shouldRevertOnExecute = _shouldRevertOnExecute;
    }

    /**
     * @notice Reset call tracking
     */
    function reset() external {
        delete lastPrepareCall;
        delete lastExecuteCall;
    }

    /**
     * @notice Get prepare call data
     */
    function getPrepareCall()
        external
        view
        returns (
            address recipient,
            address arbiter,
            uint256 expires,
            bytes32 typehash,
            bytes32 witness,
            bytes memory orderData,
            bool wasCalled
        )
    {
        return (
            lastPrepareCall.recipient,
            lastPrepareCall.arbiter,
            lastPrepareCall.expires,
            lastPrepareCall.typehash,
            lastPrepareCall.witness,
            lastPrepareCall.orderData,
            lastPrepareCall.wasCalled
        );
    }

    /**
     * @notice Get execute call data
     */
    function getExecuteCall()
        external
        view
        returns (
            address recipient,
            address arbiter,
            uint256 expires,
            bytes32 typehash,
            bytes32 witness,
            bytes memory orderData,
            bool wasCalled
        )
    {
        return (
            lastExecuteCall.recipient,
            lastExecuteCall.arbiter,
            lastExecuteCall.expires,
            lastExecuteCall.typehash,
            lastExecuteCall.witness,
            lastExecuteCall.orderData,
            lastExecuteCall.wasCalled
        );
    }

    /**
     * @notice Get prepare call idsAndAmounts
     */
    function getPrepareIdsAndAmounts() external view returns (uint256[2][] memory) {
        return lastPrepareCall.idsAndAmounts;
    }

    /**
     * @notice Get execute call idsAndAmounts
     */
    function getExecuteIdsAndAmounts() external view returns (uint256[2][] memory) {
        return lastExecuteCall.idsAndAmounts;
    }

    /**
     * @inheritdoc IOnChainAllocation
     */
    function prepareAllocation(
        address recipient,
        uint256[2][] calldata idsAndAmounts,
        address arbiter,
        uint256 expires,
        bytes32 typehash,
        bytes32 witness,
        bytes calldata orderData
    ) external override returns (uint256 nonce) {
        if (shouldRevertOnPrepare) {
            revert InvalidPreparation();
        }

        // Store the call data for validation
        lastPrepareCall.recipient = recipient;
        lastPrepareCall.arbiter = arbiter;
        lastPrepareCall.expires = expires;
        lastPrepareCall.typehash = typehash;
        lastPrepareCall.witness = witness;
        lastPrepareCall.orderData = orderData;
        lastPrepareCall.wasCalled = true;

        // Copy idsAndAmounts array
        delete lastPrepareCall.idsAndAmounts;
        for (uint256 i = 0; i < idsAndAmounts.length; i++) {
            lastPrepareCall.idsAndAmounts.push(idsAndAmounts[i]);
        }

        return nonceToReturn;
    }

    /**
     * @inheritdoc IOnChainAllocation
     */
    function executeAllocation(
        address recipient,
        uint256[2][] calldata idsAndAmounts,
        address arbiter,
        uint256 expires,
        bytes32 typehash,
        bytes32 witness,
        bytes calldata orderData
    ) external override {
        if (shouldRevertOnExecute) {
            revert("MockAllocator: executeAllocation reverted");
        }

        // Store the call data for validation
        lastExecuteCall.recipient = recipient;
        lastExecuteCall.arbiter = arbiter;
        lastExecuteCall.expires = expires;
        lastExecuteCall.typehash = typehash;
        lastExecuteCall.witness = witness;
        lastExecuteCall.orderData = orderData;
        lastExecuteCall.wasCalled = true;

        // Copy idsAndAmounts array
        delete lastExecuteCall.idsAndAmounts;
        for (uint256 i = 0; i < idsAndAmounts.length; i++) {
            lastExecuteCall.idsAndAmounts.push(idsAndAmounts[i]);
        }

        // Emit event
        emit Allocated(recipient, new Lock[](0), nonceToReturn, expires, witness);
    }

    /**
     * @notice Helper to verify prepareAllocation was called with expected params
     */
    function verifyPrepareAllocationCall(
        address expectedRecipient,
        uint256[2][] memory expectedIdsAndAmounts,
        address expectedArbiter,
        uint256 expectedExpires,
        bytes32 expectedTypehash,
        bytes32 expectedWitness,
        bytes memory expectedOrderData
    ) external view returns (bool) {
        if (!lastPrepareCall.wasCalled) return false;
        if (lastPrepareCall.recipient != expectedRecipient) return false;
        if (lastPrepareCall.arbiter != expectedArbiter) return false;
        if (lastPrepareCall.expires != expectedExpires) return false;
        if (lastPrepareCall.typehash != expectedTypehash) return false;
        if (lastPrepareCall.witness != expectedWitness) return false;
        if (keccak256(lastPrepareCall.orderData) != keccak256(expectedOrderData)) return false;
        if (lastPrepareCall.idsAndAmounts.length != expectedIdsAndAmounts.length) return false;

        for (uint256 i = 0; i < expectedIdsAndAmounts.length; i++) {
            if (lastPrepareCall.idsAndAmounts[i][0] != expectedIdsAndAmounts[i][0]) return false;
            if (lastPrepareCall.idsAndAmounts[i][1] != expectedIdsAndAmounts[i][1]) return false;
        }

        return true;
    }

    /**
     * @notice Helper to verify executeAllocation was called with expected params
     */
    function verifyExecuteAllocationCall(
        address expectedRecipient,
        uint256[2][] memory expectedIdsAndAmounts,
        address expectedArbiter,
        uint256 expectedExpires,
        bytes32 expectedTypehash,
        bytes32 expectedWitness,
        bytes memory expectedOrderData
    ) external view returns (bool) {
        if (!lastExecuteCall.wasCalled) return false;
        if (lastExecuteCall.recipient != expectedRecipient) return false;
        if (lastExecuteCall.arbiter != expectedArbiter) return false;
        if (lastExecuteCall.expires != expectedExpires) return false;
        if (lastExecuteCall.typehash != expectedTypehash) return false;
        if (lastExecuteCall.witness != expectedWitness) return false;
        if (keccak256(lastExecuteCall.orderData) != keccak256(expectedOrderData)) return false;
        if (lastExecuteCall.idsAndAmounts.length != expectedIdsAndAmounts.length) return false;

        for (uint256 i = 0; i < expectedIdsAndAmounts.length; i++) {
            if (lastExecuteCall.idsAndAmounts[i][0] != expectedIdsAndAmounts[i][0]) return false;
            if (lastExecuteCall.idsAndAmounts[i][1] != expectedIdsAndAmounts[i][1]) return false;
        }

        return true;
    }

    // ============ IAllocator Functions ============
    // These are required by the interface but not used in our tests

    function attest(address, address, address, uint256, uint256)
        external
        pure
        override
        returns (bytes4)
    {
        return this.attest.selector;
    }

    function authorizeClaim(
        bytes32,
        address,
        address,
        uint256,
        uint256,
        uint256[2][] calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.authorizeClaim.selector;
    }

    function isClaimAuthorized(
        bytes32,
        address,
        address,
        uint256,
        uint256,
        uint256[2][] calldata,
        bytes calldata
    ) external pure override returns (bool) {
        return true;
    }
}

// Import Lock type for the event
import {Lock} from "the-compact/src/types/EIP712Types.sol";
