// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAllocator} from "./mocks/MockAllocator.sol";
import {DeployTheCompact} from "./helpers/DeployTheCompact.sol";
import {TheCompact} from "../lib/the-compact/src/TheCompact.sol";
import {
    Mandate,
    FillParameters,
    FillComponent,
    Adjustment,
    RecipientCallback,
    BatchClaim
} from "../src/types/TribunalStructs.sol";
import {ADJUSTMENT_TYPEHASH, WITNESS_TYPESTRING} from "../src/types/TribunalTypeHashes.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {ITheCompact} from "the-compact/src/interfaces/ITheCompact.sol";

/**
 * @title TribunalFinalCoverageGapsTest
 * @notice Targeted tests for specific remaining coverage gaps using proper integration with THE_COMPACT
 */
contract TribunalFinalCoverageGapsTest is Test, DeployTheCompact {
    Tribunal public tribunal;
    MockERC20 public token;
    MockAllocator public allocator;
    TheCompact public theCompact;

    address public sponsor;
    address public filler;
    address public adjuster;
    uint256 public adjusterPrivateKey;
    address public arbiter;
    address public recipient;

    bytes12 public lockTag;
    uint256 public lockId;

    function setUp() public {
        // Deploy THE_COMPACT using the helper
        theCompact = deployTheCompact();

        tribunal = new Tribunal();
        token = new MockERC20();
        allocator = new MockAllocator();

        sponsor = makeAddr("Sponsor");
        filler = makeAddr("Filler");
        (adjuster, adjusterPrivateKey) = makeAddrAndKey("Adjuster");
        arbiter = makeAddr("Arbiter");
        recipient = makeAddr("Recipient");

        // Setup token balances
        token.mint(sponsor, 100 ether);
        token.mint(filler, 1000 ether);

        // Configure allocator
        allocator.setNonceToReturn(123);

        // Register the MockAllocator contract as an allocator
        vm.prank(address(allocator));
        uint96 allocatorId = theCompact.__registerAllocator(address(allocator), "");
        lockTag = bytes12(allocatorId);
        lockId = uint256(bytes32(lockTag)) | uint256(uint160(address(token)));

        // Sponsor makes a deposit to establish the lock
        vm.startPrank(sponsor);
        token.approve(address(theCompact), 20 ether);
        theCompact.depositERC20(address(token), lockTag, 10 ether, sponsor);
        vm.stopPrank();

        // Setup filler approval
        vm.prank(filler);
        token.approve(address(tribunal), type(uint256).max);
    }

    // ============ Coverage Gap: Lines 289-290 - settleOrRegister with mandateHash == 0 ============
    /**
     * @notice Test settleOrRegister deposit path without registration (mandateHash = 0)
     * @dev Covers lines 289-290 - batchDeposit without registration
     */
    function test_SettleOrRegister_DepositWithoutRegistration() public {
        uint256 depositAmount = 5 ether;

        // Create compact with existing lockTag
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({
            lockTag: lockTag, // Use registered lock
            token: address(token),
            amount: depositAmount
        });

        BatchCompact memory compact = BatchCompact({
            arbiter: arbiter,
            sponsor: sponsor,
            nonce: 1,
            expires: uint256(block.timestamp + 1 days),
            commitments: commitments
        });

        bytes32 sourceClaimHash = bytes32(0); // No source claim
        bytes32 mandateHash = bytes32(0); // No registration - triggers deposit path (lines 289-290)

        // Fund tribunal with tokens and approve
        token.mint(address(tribunal), depositAmount);
        vm.prank(address(tribunal));
        token.approve(address(theCompact), type(uint256).max);

        // Check recipient balance before
        uint256 balanceBefore = theCompact.balanceOf(recipient, lockId);

        // Should deposit without registration (lines 289-290)
        bytes32 result =
            tribunal.settleOrRegister(sourceClaimHash, compact, mandateHash, recipient, "");

        // Verify deposit occurred without registration
        assertEq(result, bytes32(0), "Should return 0 for deposit without registration");
        assertGt(
            theCompact.balanceOf(recipient, lockId),
            balanceBefore,
            "Recipient should receive deposit"
        );
    }

    // ============ Coverage Gap: Line 1085 - Token balance path in _prepareIdsAndAmounts ============
    /**
     * @notice Test _prepareIdsAndAmounts with sufficient allowance
     * @dev Covers line 1085 - the balanceOf path when allowance is already sufficient
     */
    function test_PrepareIdsAndAmounts_SufficientAllowance() public {
        uint256 depositAmount = 7 ether;

        // Setup: tribunal has tokens and pre-existing allowance
        token.mint(address(tribunal), depositAmount);

        // Give tribunal pre-existing sufficient allowance to THE_COMPACT
        // This triggers the path where line 1085 checks balance without re-approving
        vm.prank(address(tribunal));
        token.approve(address(theCompact), type(uint256).max);

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({
            lockTag: lockTag, // Use registered lock
            token: address(token),
            amount: depositAmount
        });

        BatchCompact memory compact = BatchCompact({
            arbiter: arbiter,
            sponsor: sponsor,
            nonce: 2, // Non-zero nonce triggers direct registration path
            expires: uint256(block.timestamp + 1 days),
            commitments: commitments
        });

        bytes32 sourceClaimHash = bytes32(0);
        bytes32 mandateHash = keccak256("test");

        // This executes _prepareIdsAndAmounts where line 1085 checks the balance
        // Since allowance is already sufficient, it skips the approval
        bytes32 result =
            tribunal.settleOrRegister(sourceClaimHash, compact, mandateHash, recipient, "");

        // Should return a claim hash for registration
        assertTrue(result != bytes32(0), "Should return claim hash for registration");
    }

    // ============ Helper Functions ============
    function _getBatchCompact(uint256 amount) internal view returns (BatchCompact memory) {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: lockTag, token: address(token), amount: amount});

        return BatchCompact({
            arbiter: arbiter,
            sponsor: sponsor,
            nonce: 1,
            expires: uint256(block.timestamp + 1 days),
            commitments: commitments
        });
    }

    function _getFillParameters(uint256 minimumFillAmount)
        internal
        view
        returns (FillParameters memory)
    {
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: minimumFillAmount,
            recipient: sponsor,
            applyScaling: true
        });

        return FillParameters({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1 days),
            components: components,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: new uint256[](0),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });
    }
}
