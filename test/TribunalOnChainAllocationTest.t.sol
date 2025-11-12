// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {ERC7683Tribunal} from "../src/ERC7683Tribunal.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAllocator} from "./mocks/MockAllocator.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {COMPACT_TYPEHASH_WITH_MANDATE} from "../src/types/TribunalTypeHashes.sol";
import {DeployTheCompact} from "./helpers/DeployTheCompact.sol";
import {TheCompact} from "../lib/the-compact/src/TheCompact.sol";
import {ITheCompact} from "the-compact/src/interfaces/ITheCompact.sol";

/**
 * @title TribunalOnChainAllocationTest
 * @notice Tests for the _handleOnChainAllocation internal function
 * @dev Tests proper calldata validation and interaction with allocator and TheCompact
 */
contract TribunalOnChainAllocationTest is Test, DeployTheCompact {
    ERC7683Tribunal public tribunal;
    MockERC20 public token;
    MockAllocator public allocator;
    TheCompact public theCompact;

    address public sponsor;
    address public arbiter;
    address public recipient;

    // Expected values for validation
    bytes32 public constant EXPECTED_TYPEHASH = COMPACT_TYPEHASH_WITH_MANDATE;
    bytes32 public mandateHash = keccak256("test mandate");
    bytes public context = abi.encode("test context");

    uint256 public lockId;
    bytes12 public lockTag;

    function setUp() public {
        // Deploy TheCompact
        theCompact = deployTheCompact();

        // Deploy contracts
        tribunal = new ERC7683Tribunal();
        token = new MockERC20();
        allocator = new MockAllocator();

        // Setup addresses
        sponsor = makeAddr("Sponsor");
        arbiter = makeAddr("Arbiter");
        recipient = makeAddr("Recipient");

        // Setup token - mint to sponsor first
        token.mint(sponsor, 100 ether);

        // Register allocator and deposit into TheCompact to establish the lock
        vm.startPrank(sponsor);
        token.approve(address(theCompact), 10 ether);

        // Register the allocator on TheCompact and create a lock
        uint96 allocatorId = theCompact.__registerAllocator(address(allocator), "");
        lockTag = bytes12(allocatorId);
        lockId = uint256(bytes32(lockTag)) | uint256(uint160(address(token)));

        // Then make a deposit
        theCompact.depositERC20(address(token), lockTag, 10 ether, sponsor);
        vm.stopPrank();

        // Now mint tokens to tribunal for testing
        token.mint(address(tribunal), 100 ether);

        // Configure allocator
        allocator.setNonceToReturn(123);
    }

    /**
     * @notice Test _handleOnChainAllocation calls prepareAllocation with correct parameters
     */
    function test_HandleOnChainAllocation_PreparesCorrectly() public {
        uint256 amount = 10 ether;
        uint256 expires = block.timestamp + 1 days;

        // Create compact with nonce = 0 (triggers on-chain allocation)
        BatchCompact memory compact = _getBatchCompact(amount, address(token), 0, expires);

        // Transfer tokens to tribunal and call settleOrRegister
        vm.deal(address(tribunal), amount);

        bytes32 sourceClaimHash = bytes32(uint256(1));

        vm.prank(sponsor);
        bytes32 registeredClaimHash =
            tribunal.settleOrRegister(sourceClaimHash, compact, mandateHash, recipient, context);

        // Get prepare call data
        (
            address prepRecipient,
            address prepArbiter,
            uint256 prepExpires,
            bytes32 prepTypehash,
            bytes32 prepWitness,
            bytes memory prepOrderData,
            bool prepWasCalled
        ) = allocator.getPrepareCall();

        // Verify prepareAllocation was called
        assertTrue(prepWasCalled, "prepareAllocation should be called");

        // Verify parameters
        assertEq(prepRecipient, sponsor, "Incorrect recipient");
        assertEq(prepArbiter, arbiter, "Incorrect arbiter");
        assertEq(prepExpires, expires, "Incorrect expires");
        assertEq(prepTypehash, EXPECTED_TYPEHASH, "Incorrect typehash");
        assertEq(prepWitness, mandateHash, "Incorrect witness");
        assertEq(keccak256(prepOrderData), keccak256(context), "Incorrect context");

        // Verify idsAndAmounts
        uint256[2][] memory prepareIds = allocator.getPrepareIdsAndAmounts();
        assertEq(prepareIds.length, 1, "Should have 1 id/amount pair");
        assertEq(prepareIds[0][0], lockId, "Incorrect lock id");
        assertGt(prepareIds[0][1], 0, "Amount should be > 0");

        // Verify claim hash returned
        assertTrue(registeredClaimHash != bytes32(0), "Should return non-zero claim hash");
    }

    /**
     * @notice Test _handleOnChainAllocation calls executeAllocation with correct parameters
     */
    function test_HandleOnChainAllocation_ExecutesCorrectly() public {
        uint256 amount = 5 ether;
        uint256 expires = block.timestamp + 1 days;

        BatchCompact memory compact = _getBatchCompact(amount, address(token), 0, expires);

        vm.deal(address(tribunal), amount);

        vm.prank(sponsor);
        tribunal.settleOrRegister(bytes32(uint256(1)), compact, mandateHash, recipient, context);

        // Get both prepare and execute call data
        (
            address prepRecipient,
            address prepArbiter,
            uint256 prepExpires,
            bytes32 prepTypehash,
            bytes32 prepWitness,
            ,

        ) = allocator.getPrepareCall();

        (
            address execRecipient,
            address execArbiter,
            uint256 execExpires,
            bytes32 execTypehash,
            bytes32 execWitness,
            ,
            bool execWasCalled
        ) = allocator.getExecuteCall();

        // Verify executeAllocation was called
        assertTrue(execWasCalled, "executeAllocation should be called");

        // Verify parameters match prepareAllocation
        assertEq(execRecipient, prepRecipient, "Execute recipient should match prepare");
        assertEq(execArbiter, prepArbiter, "Execute arbiter should match prepare");
        assertEq(execExpires, prepExpires, "Execute expires should match prepare");
        assertEq(execTypehash, prepTypehash, "Execute typehash should match prepare");
        assertEq(execWitness, prepWitness, "Execute witness should match prepare");
    }

    /**
     * @notice Test with native token (address(0))
     */
    function test_HandleOnChainAllocation_NativeToken() public {
        uint256 amount = 2 ether;
        uint256 expires = block.timestamp + 1 days;

        // Create compact with native token
        BatchCompact memory compact = _getBatchCompact(amount, address(0), 0, expires);

        // Fund tribunal with native tokens
        vm.deal(address(tribunal), amount);

        uint256 balanceBefore = address(tribunal).balance;

        vm.prank(sponsor);
        bytes32 registeredClaimHash = tribunal.settleOrRegister(
            bytes32(uint256(1)), compact, mandateHash, recipient, context
        );

        // Get prepare call data to verify it was called
        (,,,,,, bool prepWasCalled) = allocator.getPrepareCall();

        // Verify prepareAllocation received correct callValue
        assertTrue(prepWasCalled, "Should call prepareAllocation");
        assertGt(balanceBefore, address(tribunal).balance, "Tribunal balance should decrease");
        assertTrue(registeredClaimHash != bytes32(0), "Should return claim hash");
    }

    /**
     * @notice Test with different mandate hashes
     */
    function test_HandleOnChainAllocation_DifferentMandateHashes() public {
        bytes32 mandateHash1 = keccak256("mandate1");
        bytes32 mandateHash2 = keccak256("mandate2");

        uint256 amount = 3 ether;
        uint256 expires = block.timestamp + 1 days;

        BatchCompact memory compact = _getBatchCompact(amount, address(token), 0, expires);
        vm.deal(address(tribunal), amount * 2);

        // First call with mandateHash1
        allocator.reset();
        token.mint(address(tribunal), amount); // Ensure tribunal has tokens
        vm.prank(sponsor);
        tribunal.settleOrRegister(bytes32(uint256(1)), compact, mandateHash1, recipient, context);

        (,,,, bytes32 witness1,,) = allocator.getPrepareCall();

        // Second call with mandateHash2
        allocator.reset();
        token.mint(address(tribunal), amount); // Ensure tribunal has tokens for second call
        vm.prank(sponsor);
        tribunal.settleOrRegister(bytes32(uint256(2)), compact, mandateHash2, recipient, context);

        (,,,, bytes32 witness2,,) = allocator.getPrepareCall();

        // Verify different mandate hashes were passed
        assertEq(witness1, mandateHash1, "First call should use mandateHash1");
        assertEq(witness2, mandateHash2, "Second call should use mandateHash2");
        assertTrue(witness1 != witness2, "Witnesses should be different");
    }

    /**
     * @notice Test with different context data
     */
    function test_HandleOnChainAllocation_DifferentContexts() public {
        bytes memory context1 = abi.encode("context1");
        bytes memory context2 = abi.encode("context2", 42, address(0x123));

        uint256 amount = 3 ether;
        uint256 expires = block.timestamp + 1 days;

        BatchCompact memory compact = _getBatchCompact(amount, address(token), 0, expires);
        vm.deal(address(tribunal), amount * 2);

        // First call with context1
        allocator.reset();
        token.mint(address(tribunal), amount); // Ensure tribunal has tokens
        vm.prank(sponsor);
        tribunal.settleOrRegister(bytes32(uint256(1)), compact, mandateHash, recipient, context1);

        (,,,,, bytes memory receivedContext1,) = allocator.getPrepareCall();

        // Second call with context2
        allocator.reset();
        token.mint(address(tribunal), amount); // Ensure tribunal has tokens for second call
        vm.prank(sponsor);
        tribunal.settleOrRegister(bytes32(uint256(2)), compact, mandateHash, recipient, context2);

        (,,,,, bytes memory receivedContext2,) = allocator.getPrepareCall();

        // Verify different contexts were passed
        assertEq(keccak256(receivedContext1), keccak256(context1), "First context should match");
        assertEq(keccak256(receivedContext2), keccak256(context2), "Second context should match");
        assertTrue(
            keccak256(receivedContext1) != keccak256(receivedContext2),
            "Contexts should be different"
        );
    }

    /**
     * @notice Test that allocator nonce is properly used
     */
    function test_HandleOnChainAllocation_UsesAllocatorNonce() public {
        uint256 expectedNonce = 999;
        allocator.setNonceToReturn(expectedNonce);

        uint256 amount = 1 ether;
        uint256 expires = block.timestamp + 1 days;

        BatchCompact memory compact = _getBatchCompact(amount, address(token), 0, expires);
        vm.deal(address(tribunal), amount);

        vm.prank(sponsor);
        bytes32 claimHash = tribunal.settleOrRegister(
            bytes32(uint256(1)), compact, mandateHash, recipient, context
        );

        // Get call status
        (,,,,,, bool prepWasCalled) = allocator.getPrepareCall();
        (,,,,,, bool execWasCalled) = allocator.getExecuteCall();

        // Verify the nonce was used (indirectly, by checking claim was registered)
        assertTrue(claimHash != bytes32(0), "Claim hash should be non-zero");
        assertTrue(prepWasCalled, "Prepare should be called");
        assertTrue(execWasCalled, "Execute should be called");
    }

    /**
     * @notice Test verification helper functions work correctly
     */
    function test_HandleOnChainAllocation_VerificationHelpers() public {
        uint256 amount = 4 ether;
        uint256 expires = block.timestamp + 1 days;

        BatchCompact memory compact = _getBatchCompact(amount, address(token), 0, expires);
        vm.deal(address(tribunal), amount);

        vm.prank(sponsor);
        tribunal.settleOrRegister(bytes32(uint256(1)), compact, mandateHash, recipient, context);

        // Build expected idsAndAmounts using getter function
        uint256[2][] memory prepareIds = allocator.getPrepareIdsAndAmounts();
        uint256[2][] memory expectedIds = new uint256[2][](1);
        expectedIds[0][0] = lockId;
        expectedIds[0][1] = prepareIds[0][1];

        // Verify prepareAllocation call
        bool prepareValid = allocator.verifyPrepareAllocationCall(
            sponsor, expectedIds, arbiter, expires, EXPECTED_TYPEHASH, mandateHash, context
        );
        assertTrue(prepareValid, "Prepare call verification should pass");

        // Verify executeAllocation call
        bool executeValid = allocator.verifyExecuteAllocationCall(
            sponsor, expectedIds, arbiter, expires, EXPECTED_TYPEHASH, mandateHash, context
        );
        assertTrue(executeValid, "Execute call verification should pass");
    }

    /**
     * @notice Test multiple sequential calls work independently
     */
    function test_HandleOnChainAllocation_MultipleSequentialCalls() public {
        uint256 amount = 1 ether;
        uint256 expires = block.timestamp + 1 days;

        vm.deal(address(tribunal), amount * 3);

        BatchCompact memory compact = _getBatchCompact(amount, address(token), 0, expires);

        // First call
        allocator.reset();
        allocator.setNonceToReturn(1);
        token.mint(address(tribunal), amount); // Ensure tribunal has tokens
        vm.prank(sponsor);
        bytes32 hash1 = tribunal.settleOrRegister(
            bytes32(uint256(1)), compact, keccak256("mandate1"), recipient, abi.encode("ctx1")
        );

        (,,,, bytes32 witness1,,) = allocator.getPrepareCall();

        // Second call
        allocator.reset();
        allocator.setNonceToReturn(2);
        token.mint(address(tribunal), amount); // Ensure tribunal has tokens for second call
        vm.prank(sponsor);
        bytes32 hash2 = tribunal.settleOrRegister(
            bytes32(uint256(2)), compact, keccak256("mandate2"), recipient, abi.encode("ctx2")
        );

        (,,,, bytes32 witness2,, bool prepWasCalled) = allocator.getPrepareCall();
        (,,,,,, bool execWasCalled) = allocator.getExecuteCall();

        // Verify each call was independent
        assertTrue(hash1 != hash2, "Claim hashes should differ");
        assertTrue(witness1 != witness2, "Witnesses should differ");
        assertTrue(prepWasCalled, "Second prepare should be called");
        assertTrue(execWasCalled, "Second execute should be called");
    }

    // ============ Helper Functions ============

    function _getBatchCompact(uint256 amount, address tokenAddress, uint256 nonce, uint256 expires)
        internal
        view
        returns (BatchCompact memory)
    {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: lockTag, token: tokenAddress, amount: amount});

        return BatchCompact({
            arbiter: arbiter,
            sponsor: sponsor,
            nonce: nonce,
            expires: expires,
            commitments: commitments
        });
    }
}
