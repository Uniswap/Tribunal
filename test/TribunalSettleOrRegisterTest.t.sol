// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {ERC7683Tribunal} from "../src/ERC7683Tribunal.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTheCompact} from "./mocks/MockTheCompact.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {
    Mandate,
    FillParameters,
    FillComponent,
    Adjustment,
    BatchClaim,
    RecipientCallback
} from "../src/types/TribunalStructs.sol";
import {ADJUSTMENT_TYPEHASH} from "../src/types/TribunalTypeHashes.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";

/**
 * @title TribunalSettleOrRegisterTest
 * @notice Comprehensive tests for settleOrRegister function paths to improve coverage
 */
contract TribunalSettleOrRegisterTest is Test {
    ERC7683Tribunal public tribunal;
    MockERC20 public token;
    MockTheCompact public mockCompact;
    address public sponsor;
    address public filler;
    address public adjuster;
    uint256 public adjusterPrivateKey;
    address public arbiter;
    address public recipient;

    function setUp() public {
        tribunal = new ERC7683Tribunal();
        token = new MockERC20();
        sponsor = makeAddr("Sponsor");
        filler = makeAddr("Filler");
        (adjuster, adjusterPrivateKey) = makeAddrAndKey("Adjuster");
        arbiter = makeAddr("Arbiter");
        recipient = makeAddr("Recipient");

        // Setup tokens
        token.mint(address(tribunal), 10 ether);
        vm.deal(address(tribunal), 10 ether);
        token.mint(filler, 100 ether);
    }

    // ============ Test _handleClaimantTransfer Coverage ============

    /**
     * @notice Test settleOrRegister with existing claimant (ERC20 transfer)
     * @dev Covers lines 252-269 in Tribunal.sol (_handleClaimantTransfer ERC20 path)
     */
    function test_SettleOrRegister_ExistingClaimant_ERC20() public {
        // First, create a fill to establish a claimant
        BatchCompact memory compact = _getBatchCompact(10 ether, address(token));
        FillParameters memory fill = _getFillParameters(1 ether);
        Mandate memory mandate = _getMandate(fill);
        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);
        bytes32 claimHash = tribunal.deriveClaimHash(compact, mandateHash);

        // Mock a fill by setting the disposition directly via storage manipulation
        bytes32 claimantBytes = bytes32(uint256(uint160(filler)));
        bytes32 dispositionSlot = keccak256(abi.encodePacked(claimHash, uint256(0)));
        vm.store(address(tribunal), dispositionSlot, claimantBytes);

        // Now call settleOrRegister - should transfer to claimant
        uint256 balanceBefore = token.balanceOf(filler);

        vm.prank(sponsor);
        bytes32 result = tribunal.settleOrRegister(claimHash, compact, mandateHash, recipient, "");

        assertEq(result, bytes32(0), "Should return bytes32(0) for claimant transfer");
        assertGt(token.balanceOf(filler), balanceBefore, "Claimant should receive tokens");
    }

    /**
     * @notice Test settleOrRegister with existing claimant (native token transfer)
     * @dev Covers lines 252-269 in Tribunal.sol (_handleClaimantTransfer native path)
     */
    function test_SettleOrRegister_ExistingClaimant_Native() public {
        // Create compact with native token (address(0))
        BatchCompact memory compact = _getBatchCompact(5 ether, address(0));
        FillParameters memory fill = _getFillParameters(1 ether);
        Mandate memory mandate = _getMandate(fill);
        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);
        bytes32 claimHash = tribunal.deriveClaimHash(compact, mandateHash);

        // Mock a fill by setting the disposition
        bytes32 claimantBytes = bytes32(uint256(uint160(filler)));
        bytes32 dispositionSlot = keccak256(abi.encodePacked(claimHash, uint256(0)));
        vm.store(address(tribunal), dispositionSlot, claimantBytes);

        // Call settleOrRegister with native tokens
        uint256 balanceBefore = filler.balance;

        vm.prank(sponsor);
        bytes32 result = tribunal.settleOrRegister(claimHash, compact, mandateHash, recipient, "");

        assertEq(result, bytes32(0), "Should return bytes32(0) for claimant transfer");
        assertGt(filler.balance, balanceBefore, "Claimant should receive native tokens");
    }

    // ============ Test _handleDirectTransfer Coverage ============

    /**
     * @notice Test settleOrRegister with empty lockTag (direct ERC20 transfer)
     * @dev Covers lines 273-281 in Tribunal.sol (_handleDirectTransfer ERC20 path)
     */
    function test_SettleOrRegister_DirectTransfer_ERC20() public {
        // Create compact with empty lockTag (direct transfer)
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({
            lockTag: bytes12(0), // Empty lockTag for direct transfer
            token: address(token),
            amount: 5 ether
        });

        BatchCompact memory compact = BatchCompact({
            arbiter: arbiter,
            sponsor: sponsor,
            nonce: 0,
            expires: uint256(block.timestamp + 1 days),
            commitments: commitments
        });

        bytes32 sourceClaimHash = bytes32(uint256(1));
        bytes32 mandateHash = bytes32(0); // No mandate hash needed for direct transfer

        vm.prank(sponsor);
        bytes32 result =
            tribunal.settleOrRegister(sourceClaimHash, compact, mandateHash, recipient, "");

        assertEq(result, bytes32(0), "Should return bytes32(0) for direct transfer");
        assertGt(token.balanceOf(recipient), 0, "Recipient should receive tokens");
    }

    /**
     * @notice Test settleOrRegister with empty lockTag (direct native transfer)
     * @dev Covers lines 273-281 in Tribunal.sol (_handleDirectTransfer native path)
     */
    function test_SettleOrRegister_DirectTransfer_Native() public {
        // Create compact with empty lockTag and native token
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({
            lockTag: bytes12(0), // Empty lockTag for direct transfer
            token: address(0), // Native token
            amount: 3 ether
        });

        BatchCompact memory compact = BatchCompact({
            arbiter: arbiter,
            sponsor: sponsor,
            nonce: 0,
            expires: uint256(block.timestamp + 1 days),
            commitments: commitments
        });

        bytes32 sourceClaimHash = bytes32(uint256(1));
        bytes32 mandateHash = bytes32(0);

        uint256 balanceBefore = recipient.balance;

        vm.prank(sponsor);
        bytes32 result =
            tribunal.settleOrRegister(sourceClaimHash, compact, mandateHash, recipient, "");

        assertEq(result, bytes32(0), "Should return bytes32(0) for direct transfer");
        assertGt(recipient.balance, balanceBefore, "Recipient should receive native tokens");
    }

    /**
     * @notice Test settleOrRegister with empty lockTag and no recipient (defaults to sponsor)
     * @dev Covers line 268-269 assembly block for recipient default
     */
    function test_SettleOrRegister_DirectTransfer_DefaultRecipient() public {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(token), amount: 2 ether});

        BatchCompact memory compact = BatchCompact({
            arbiter: arbiter,
            sponsor: sponsor,
            nonce: 0,
            expires: uint256(block.timestamp + 1 days),
            commitments: commitments
        });

        bytes32 sourceClaimHash = bytes32(uint256(1));
        bytes32 mandateHash = bytes32(0);

        uint256 balanceBefore = token.balanceOf(sponsor);

        vm.prank(sponsor);
        bytes32 result = tribunal.settleOrRegister(
            sourceClaimHash,
            compact,
            mandateHash,
            address(0),
            "" // No recipient specified
        );

        assertEq(result, bytes32(0), "Should return bytes32(0)");
        assertGt(
            token.balanceOf(sponsor), balanceBefore, "Sponsor should receive tokens as default"
        );
    }

    // ============ Test InvalidCommitmentsArray Error ============

    /**
     * @notice Test settleOrRegister reverts with multiple commitments
     * @dev Covers line 259-260 in Tribunal.sol
     */
    function test_SettleOrRegister_Revert_MultipleCommitments() public {
        Lock[] memory commitments = new Lock[](2);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(token), amount: 1 ether});
        commitments[1] = Lock({lockTag: bytes12(0), token: address(token), amount: 1 ether});

        BatchCompact memory compact = BatchCompact({
            arbiter: arbiter,
            sponsor: sponsor,
            nonce: 0,
            expires: uint256(block.timestamp + 1 days),
            commitments: commitments
        });

        bytes32 sourceClaimHash = bytes32(uint256(1));
        bytes32 mandateHash = bytes32(0);

        vm.expectRevert(ITribunal.InvalidCommitmentsArray.selector);
        vm.prank(sponsor);
        tribunal.settleOrRegister(sourceClaimHash, compact, mandateHash, recipient, "");
    }

    // ============ Helper Functions ============

    function _getBatchCompact(uint256 amount, address tokenAddress)
        internal
        view
        returns (BatchCompact memory)
    {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({
            lockTag: bytes12(uint96(1)), // Non-zero lockTag
            token: tokenAddress,
            amount: amount
        });

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

    function _getMandate(FillParameters memory fill) internal pure returns (Mandate memory) {
        FillParameters[] memory fills = new FillParameters[](1);
        fills[0] = fill;

        return Mandate({adjuster: address(0), fills: fills});
    }
}
