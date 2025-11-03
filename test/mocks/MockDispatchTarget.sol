// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BatchCompact} from "the-compact/src/types/EIP712Types.sol";
import {IDispatchCallback} from "../../src/interfaces/IDispatchCallback.sol";

contract MockDispatchTarget is IDispatchCallback {
    enum Mode {
        Success,
        Revert,
        WrongSelector
    }

    Mode public mode;

    // Expected values for validation
    uint256 public expectedChainId;
    BatchCompact public expectedCompact;
    bytes32 public expectedMandateHash;
    bytes32 public expectedClaimHash;
    bytes32 public expectedClaimant;
    uint256 public expectedClaimReductionScalingFactor;
    uint256[] public expectedClaimAmounts;
    bytes public expectedContext;

    // Received values
    uint256 public receivedChainId;
    BatchCompact public receivedCompact;
    bytes32 public receivedMandateHash;
    bytes32 public receivedClaimHash;
    bytes32 public receivedClaimant;
    uint256 public receivedClaimReductionScalingFactor;
    uint256[] public receivedClaimAmounts;
    bytes public receivedContext;
    uint256 public receivedValue;

    // Track if callback was called
    bool public callbackCalled;

    function setMode(Mode _mode) external {
        mode = _mode;
    }

    function setExpectedValues(
        uint256 _chainId,
        BatchCompact calldata _compact,
        bytes32 _mandateHash,
        bytes32 _claimHash,
        bytes32 _claimant,
        uint256 _claimReductionScalingFactor,
        uint256[] calldata _claimAmounts,
        bytes calldata _context
    ) external {
        expectedChainId = _chainId;
        expectedCompact = _compact;
        expectedMandateHash = _mandateHash;
        expectedClaimHash = _claimHash;
        expectedClaimant = _claimant;
        expectedClaimReductionScalingFactor = _claimReductionScalingFactor;
        delete expectedClaimAmounts;
        for (uint256 i = 0; i < _claimAmounts.length; i++) {
            expectedClaimAmounts.push(_claimAmounts[i]);
        }
        expectedContext = _context;
    }

    function dispatchCallback(
        uint256 chainId,
        BatchCompact calldata compact,
        bytes32 mandateHash,
        bytes32 claimHash,
        bytes32 claimant,
        uint256 claimReductionScalingFactor,
        uint256[] calldata claimAmounts,
        bytes calldata context
    ) external payable returns (bytes4) {
        callbackCalled = true;
        receivedValue = msg.value;

        // Store received values
        receivedChainId = chainId;
        receivedCompact = compact;
        receivedMandateHash = mandateHash;
        receivedClaimHash = claimHash;
        receivedClaimant = claimant;
        receivedClaimReductionScalingFactor = claimReductionScalingFactor;
        delete receivedClaimAmounts;
        for (uint256 i = 0; i < claimAmounts.length; i++) {
            receivedClaimAmounts.push(claimAmounts[i]);
        }
        receivedContext = context;

        // Validate received values match expected (only if expected values were set)
        if (expectedChainId != 0) {
            require(chainId == expectedChainId, "ChainId mismatch");
            require(compact.sponsor == expectedCompact.sponsor, "Sponsor mismatch");
            require(compact.nonce == expectedCompact.nonce, "Nonce mismatch");
            require(compact.expires == expectedCompact.expires, "Expires mismatch");
            require(compact.arbiter == expectedCompact.arbiter, "Arbiter mismatch");
            require(
                compact.commitments.length == expectedCompact.commitments.length,
                "Commitments length mismatch"
            );
            require(mandateHash == expectedMandateHash, "MandateHash mismatch");
            require(claimHash == expectedClaimHash, "ClaimHash mismatch");
            require(claimant == expectedClaimant, "Claimant mismatch");
            require(
                claimReductionScalingFactor == expectedClaimReductionScalingFactor,
                "ClaimReductionScalingFactor mismatch"
            );
            require(
                claimAmounts.length == expectedClaimAmounts.length, "ClaimAmounts length mismatch"
            );
            for (uint256 i = 0; i < claimAmounts.length; i++) {
                require(claimAmounts[i] == expectedClaimAmounts[i], "ClaimAmount mismatch");
            }
            require(keccak256(context) == keccak256(expectedContext), "Context mismatch");
        }

        if (mode == Mode.Revert) {
            revert("MockDispatchTarget: forced revert");
        } else if (mode == Mode.WrongSelector) {
            return bytes4(0xdeadbeef);
        }

        return IDispatchCallback.dispatchCallback.selector;
    }

    function reset() external {
        callbackCalled = false;
        receivedValue = 0;
        delete receivedClaimAmounts;
        delete expectedClaimAmounts;
    }
}
