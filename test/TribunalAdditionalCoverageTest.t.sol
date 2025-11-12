// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {ERC7683Tribunal} from "../src/ERC7683Tribunal.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTheCompact} from "./mocks/MockTheCompact.sol";
import {MockAllocator} from "./mocks/MockAllocator.sol";
import {IRecipientCallback} from "../src/interfaces/IRecipientCallback.sol";
import {IDispatchCallback} from "../src/interfaces/IDispatchCallback.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {
    Mandate,
    FillParameters,
    FillComponent,
    Adjustment,
    RecipientCallback,
    BatchClaim,
    DispatchParameters
} from "../src/types/TribunalStructs.sol";
import {ADJUSTMENT_TYPEHASH} from "../src/types/TribunalTypeHashes.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";

/**
 * @title TribunalAdditionalCoverageTest
 * @notice Tests to cover remaining gaps in code coverage
 */
contract TribunalAdditionalCoverageTest is Test {
    Tribunal public tribunal;
    MockERC20 public token;
    address public sponsor;
    address public filler;
    address public adjuster;
    uint256 public adjusterPrivateKey;
    address public arbiter;

    event Dispatch(
        address indexed target, uint256 indexed chainId, bytes32 indexed claimant, bytes32 claimHash
    );

    function setUp() public {
        tribunal = new Tribunal();
        token = new MockERC20();
        sponsor = makeAddr("Sponsor");
        filler = makeAddr("Filler");
        (adjuster, adjusterPrivateKey) = makeAddrAndKey("Adjuster");
        arbiter = makeAddr("Arbiter");
    }

    // ============ Test Invalid Fill Block Coverage ============

    /**
     * @notice Test fill with invalid block number
     * @dev Covers line 694 in Tribunal.sol (InvalidFillBlock revert)
     */
    function test_Fill_InvalidFillBlock_Reverts() public {
        BatchCompact memory compact = _getBatchCompact(10 ether);
        FillParameters memory fill = _getFillParameters(1 ether);
        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        Adjustment memory adjustment = _getAdjustment(0);

        // Try to fill with a future block number
        uint256 futureBlock = block.number + 100;

        vm.expectRevert(ITribunal.InvalidFillBlock.selector);
        tribunal.fill(
            compact, fill, adjustment, fillHashes, bytes32(uint256(uint160(filler))), futureBlock
        );
    }

    // ============ Test settleOrRegister with Multiple Commitments ============

    /**
     * @notice Test settleOrRegister with invalid commitments array
     * @dev Covers line 260 in Tribunal.sol (InvalidCommitmentsArray revert)
     */
    function test_SettleOrRegister_MultipleCommitments_Reverts() public {
        Lock[] memory commitments = new Lock[](2);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(token), amount: 10 ether});
        commitments[1] = Lock({lockTag: bytes12(0), token: address(token), amount: 5 ether});

        BatchCompact memory compact = BatchCompact({
            arbiter: arbiter,
            sponsor: sponsor,
            nonce: 1,
            expires: uint256(block.timestamp + 1 days),
            commitments: commitments
        });

        bytes32 sourceClaimHash = bytes32(0);
        bytes32 mandateHash = bytes32(0);
        address recipient = address(0);
        bytes memory context = "";

        vm.expectRevert(ITribunal.InvalidCommitmentsArray.selector);
        tribunal.settleOrRegister(sourceClaimHash, compact, mandateHash, recipient, context);
    }

    // ============ Test Dispatch Not Available ============

    /**
     * @notice Test dispatch when claim hasn't been filled
     * @dev Covers line 232 in Tribunal.sol (DispatchNotAvailable revert)
     */
    function test_Dispatch_NotAvailable_Reverts() public {
        BatchCompact memory compact = _getBatchCompact(10 ether);
        FillParameters memory fill = _getFillParameters(1 ether);
        Mandate memory mandate = _getMandate(fill);
        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);

        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: 1, target: makeAddr("DispatchTarget"), value: 0, context: ""
        });

        vm.expectRevert(ITribunal.DispatchNotAvailable.selector);
        tribunal.dispatch(compact, mandateHash, dispatchParams);
    }

    // ============ Test Invalid Recipient Callback ============

    /**
     * @notice Test fill with invalid recipient callback selector
     * @dev Covers lines 938-939 in Tribunal.sol (InvalidRecipientCallback revert)
     */
    function test_Fill_InvalidRecipientCallback_Reverts() public {
        // Deploy a mock recipient that returns wrong selector
        InvalidRecipientCallbackMock invalidRecipient = new InvalidRecipientCallbackMock();

        BatchCompact memory compact = _getBatchCompact(10 ether);

        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 1 ether,
            recipient: address(invalidRecipient),
            applyScaling: true
        });

        RecipientCallback[] memory recipientCallbacks = new RecipientCallback[](1);
        recipientCallbacks[0] = RecipientCallback({
            chainId: block.chainid, compact: compact, mandateHash: bytes32(0), context: ""
        });

        FillParameters memory fill = FillParameters({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1 days),
            components: components,
            baselinePriorityFee: 0,
            scalingFactor: 1e18,
            priceCurve: new uint256[](0),
            recipientCallback: recipientCallbacks,
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = _getMandate(fill);
        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        Adjustment memory adjustment = _getAdjustment(0);
        adjustment.adjustmentAuthorization = _toAdjustmentSignature(adjustment, compact, mandate);

        // Mint tokens for filler
        token.mint(filler, 10 ether);
        vm.prank(filler);
        token.approve(address(tribunal), 10 ether);

        vm.prank(filler);
        vm.expectRevert(ITribunal.InvalidRecipientCallback.selector);
        tribunal.fill(
            compact,
            fill,
            adjustment,
            fillHashes,
            bytes32(uint256(uint160(filler))),
            0 // 0 means use current block
        );
    }

    // ============ Test Invalid Recipient Callback Length ============

    /**
     * @notice Test deriveRecipientCallbackHash with invalid length
     * @dev Covers line 642 in Tribunal.sol (InvalidRecipientCallbackLength revert)
     */
    function test_DeriveRecipientCallbackHash_InvalidLength_Reverts() public {
        BatchCompact memory compact = _getBatchCompact(10 ether);

        RecipientCallback[] memory recipientCallbacks = new RecipientCallback[](2);
        recipientCallbacks[0] = RecipientCallback({
            chainId: block.chainid, compact: compact, mandateHash: bytes32(0), context: ""
        });
        recipientCallbacks[1] = RecipientCallback({
            chainId: block.chainid, compact: compact, mandateHash: bytes32(0), context: ""
        });

        vm.expectRevert(ITribunal.InvalidRecipientCallbackLength.selector);
        tribunal.deriveRecipientCallbackHash(recipientCallbacks);
    }

    // ============ Test Invalid Fill Hash Arguments ============

    /**
     * @notice Test fill with invalid fillHash arguments
     * @dev Covers line 1327 in Tribunal.sol (InvalidFillHashArguments revert)
     */
    function test_Fill_InvalidFillHashArguments_Reverts() public {
        BatchCompact memory compact = _getBatchCompact(10 ether);
        FillParameters memory fill = _getFillParameters(1 ether);

        // Create a wrong fill hash
        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = bytes32(uint256(0x123456)); // Wrong hash

        Adjustment memory adjustment = _getAdjustment(0);

        // This should fail during mandate hash derivation
        vm.expectRevert(ITribunal.InvalidFillHashArguments.selector);
        tribunal.fill(compact, fill, adjustment, fillHashes, bytes32(uint256(uint160(filler))), 0);
    }

    // ============ Test Invalid Target Block Designation ============

    /**
     * @notice Test deriveAmounts with targetBlock=0 but non-empty price curve
     * @dev Covers line 552 in Tribunal.sol (InvalidTargetBlockDesignation revert)
     */
    function test_DeriveAmounts_InvalidTargetBlockDesignation_Reverts() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] =
            Lock({lockTag: bytes12(0), token: address(token), amount: 10 ether});

        uint256[] memory priceCurve = new uint256[](2);
        priceCurve[0] = 1e18;
        priceCurve[1] = 2e18;

        uint256 targetBlock = 0; // targetBlock is 0
        uint256 fillBlock = 100;
        uint256 minimumFillAmount = 1 ether;
        uint256 baselinePriorityFee = 0;
        uint256 scalingFactor = 1e18;

        vm.expectRevert(ITribunal.InvalidTargetBlockDesignation.selector);
        tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            targetBlock,
            fillBlock,
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );
    }

    // ============ Test Invalid Target Block (Past) ============

    /**
     * @notice Test deriveAmounts with targetBlock > fillBlock
     * @dev Covers line 534 in Tribunal.sol (InvalidTargetBlock revert)
     */
    function test_DeriveAmounts_InvalidTargetBlockPast_Reverts() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] =
            Lock({lockTag: bytes12(0), token: address(token), amount: 10 ether});

        uint256[] memory priceCurve = new uint256[](0);
        uint256 targetBlock = 200; // Future target block
        uint256 fillBlock = 100; // Current fill block
        uint256 minimumFillAmount = 1 ether;
        uint256 baselinePriorityFee = 0;
        uint256 scalingFactor = 1e18;

        vm.expectRevert(
            abi.encodeWithSelector(ITribunal.InvalidTargetBlock.selector, fillBlock, targetBlock)
        );
        tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            targetBlock,
            fillBlock,
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );
    }

    // ============ Test Invalid Dispatch Callback ============

    /**
     * @notice Test dispatch with invalid callback selector
     * @dev Covers line 1250 in Tribunal.sol (InvalidDispatchCallback revert)
     */
    function test_Dispatch_InvalidCallback_Reverts() public {
        // First fill an order
        BatchCompact memory compact = _getBatchCompact(10 ether);
        FillParameters memory fill = _getFillParameters(1 ether);
        Mandate memory mandate = _getMandate(fill);
        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        Adjustment memory adjustment = _getAdjustment(0);
        adjustment.adjustmentAuthorization = _toAdjustmentSignature(adjustment, compact, mandate);

        // Mint tokens for filler
        token.mint(filler, 10 ether);
        vm.prank(filler);
        token.approve(address(tribunal), 10 ether);

        // Fill the order
        vm.prank(filler);
        tribunal.fill(compact, fill, adjustment, fillHashes, bytes32(uint256(uint160(filler))), 0);

        // Now try to dispatch with invalid callback
        InvalidDispatchCallbackMock invalidCallback = new InvalidDispatchCallbackMock();

        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);
        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: 1, target: address(invalidCallback), value: 0, context: ""
        });

        vm.expectRevert(ITribunal.InvalidDispatchCallback.selector);
        tribunal.dispatch(compact, mandateHash, dispatchParams);
    }

    // ============ Test Invalid Adjustment ============

    /**
     * @notice Test fill with invalid adjustment signature
     * @dev Covers line 750 in Tribunal.sol (InvalidAdjustment revert)
     */
    function test_Fill_InvalidAdjustment_Reverts() public {
        BatchCompact memory compact = _getBatchCompact(10 ether);
        FillParameters memory fill = _getFillParameters(1 ether);
        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        Adjustment memory adjustment = _getAdjustment(0);
        adjustment.adjustmentAuthorization = hex"deadbeef"; // Invalid signature

        vm.expectRevert(ITribunal.InvalidAdjustment.selector);
        tribunal.fill(compact, fill, adjustment, fillHashes, bytes32(uint256(uint160(filler))), 0);
    }

    // ============ Test Cancel Not Sponsor ============

    /**
     * @notice Test cancel by non-sponsor
     * @dev Covers line 1017 in Tribunal.sol (NotSponsor revert)
     */
    function test_Cancel_NotSponsor_Reverts() public {
        BatchCompact memory compact = _getBatchCompact(10 ether);
        FillParameters memory fill = _getFillParameters(1 ether);
        bytes32 mandateHash = tribunal.deriveMandateHash(_getMandate(fill));

        vm.prank(filler); // Not the sponsor
        vm.expectRevert(ITribunal.NotSponsor.selector);
        tribunal.cancel(compact, mandateHash);
    }

    // ============ Test Already Filled ============

    /**
     * @notice Test fill order that's already been filled
     * @dev Covers line 742 in Tribunal.sol (AlreadyFilled revert from fill)
     * and line 1023 in Tribunal.sol (AlreadyFilled revert from cancel)
     */
    function test_Fill_AlreadyFilled_Reverts() public {
        BatchCompact memory compact = _getBatchCompact(10 ether);
        FillParameters memory fill = _getFillParameters(1 ether);
        Mandate memory mandate = _getMandate(fill);
        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        Adjustment memory adjustment = _getAdjustment(0);
        adjustment.adjustmentAuthorization = _toAdjustmentSignature(adjustment, compact, mandate);

        // Mint tokens for filler
        token.mint(filler, 20 ether);
        vm.prank(filler);
        token.approve(address(tribunal), 20 ether);

        // Fill the order once and capture the mandateHash
        vm.prank(filler);
        (, bytes32 mandateHash,,) = tribunal.fill(
            compact, fill, adjustment, fillHashes, bytes32(uint256(uint160(filler))), 0
        );

        // Try to fill again
        vm.prank(filler);
        vm.expectRevert(ITribunal.AlreadyFilled.selector);
        tribunal.fill(compact, fill, adjustment, fillHashes, bytes32(uint256(uint160(filler))), 0);

        // Also test that cancel reverts with AlreadyFilled
        vm.prank(sponsor);
        vm.expectRevert(ITribunal.AlreadyFilled.selector);
        tribunal.cancel(compact, mandateHash);
    }

    // ============ Test Validity Conditions Not Met ============

    /**
     * @notice Test fill with validity conditions not met
     * @dev Covers line 909 in Tribunal.sol (ValidityConditionsNotMet revert)
     */
    function test_Fill_ValidityConditionsNotMet_Reverts() public {
        BatchCompact memory compact = _getBatchCompact(10 ether);
        FillParameters memory fill = _getFillParameters(1 ether);
        Mandate memory mandate = _getMandate(fill);
        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        // Create adjustment with validFiller restriction
        address wrongFiller = makeAddr("WrongFiller");
        Adjustment memory adjustment = _getAdjustment(0);
        adjustment.validityConditions = bytes32(uint256(uint160(wrongFiller))); // Only wrongFiller can fill
        adjustment.adjustmentAuthorization = _toAdjustmentSignature(adjustment, compact, mandate);

        // Mint tokens for filler
        token.mint(filler, 10 ether);
        vm.prank(filler);
        token.approve(address(tribunal), 10 ether);

        // Try to fill with different filler
        vm.prank(filler);
        vm.expectRevert(ITribunal.ValidityConditionsNotMet.selector);
        tribunal.fill(compact, fill, adjustment, fillHashes, bytes32(uint256(uint160(filler))), 0);
    }

    /**
     * @notice Test fill with expired block window
     * @dev Covers line 909 in Tribunal.sol (ValidityConditionsNotMet revert - block window)
     */
    function test_Fill_BlockWindowExpired_Reverts() public {
        BatchCompact memory compact = _getBatchCompact(10 ether);
        FillParameters memory fill = _getFillParameters(1 ether);
        Mandate memory mandate = _getMandate(fill);
        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        // Create adjustment with tight block window that expires
        uint256 targetBlock = 100;
        uint256 validBlockWindow = 5; // Only valid for 5 blocks
        Adjustment memory adjustment = _getAdjustment(targetBlock);
        adjustment.validityConditions = bytes32(validBlockWindow << 160); // Set block window
        adjustment.adjustmentAuthorization = _toAdjustmentSignature(adjustment, compact, mandate);

        // Mint tokens for filler
        token.mint(filler, 10 ether);
        vm.prank(filler);
        token.approve(address(tribunal), 10 ether);

        // Roll to a block past the window
        vm.roll(targetBlock + validBlockWindow + 10);

        // Try to fill
        vm.prank(filler);
        vm.expectRevert(ITribunal.ValidityConditionsNotMet.selector);
        tribunal.fill(compact, fill, adjustment, fillHashes, bytes32(uint256(uint160(filler))), 0);
    }

    // ============ Test Invalid Chain ID ============

    /**
     * @notice Test fill with wrong chain ID
     * @dev Covers line 895 in Tribunal.sol (InvalidChainId revert)
     */
    function test_Fill_InvalidChainId_Reverts() public {
        BatchCompact memory compact = _getBatchCompact(10 ether);
        FillParameters memory fill = _getFillParameters(1 ether);
        fill.chainId = 999; // Wrong chain ID
        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        Adjustment memory adjustment = _getAdjustment(0);

        vm.expectRevert(ITribunal.InvalidChainId.selector);
        tribunal.fill(compact, fill, adjustment, fillHashes, bytes32(uint256(uint160(filler))), 0);
    }

    // ============ Test fillAndDispatch Coverage ============

    /**
     * @notice Test fillAndDispatch function
     * @dev Covers line 193 in Tribunal.sol (fillAndDispatch return)
     */
    function test_FillAndDispatch_Success() public {
        // Deploy valid dispatch callback
        ValidDispatchCallbackMock callbackTarget = new ValidDispatchCallbackMock();

        BatchCompact memory compact = _getBatchCompact(10 ether);
        FillParameters memory fill = _getFillParameters(1 ether);
        Mandate memory mandate = _getMandate(fill);
        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        Adjustment memory adjustment = _getAdjustment(0);
        adjustment.adjustmentAuthorization = _toAdjustmentSignature(adjustment, compact, mandate);

        // Mint tokens for filler
        token.mint(filler, 10 ether);
        vm.prank(filler);
        token.approve(address(tribunal), 10 ether);

        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: 1, target: address(callbackTarget), value: 0, context: ""
        });

        // Fill and dispatch
        vm.prank(filler);
        (
            bytes32 claimHash,
            bytes32 mandateHash,
            uint256[] memory fillAmounts,
            uint256[] memory claimAmounts
        ) = tribunal.fillAndDispatch(
            compact,
            fill,
            adjustment,
            fillHashes,
            bytes32(uint256(uint160(filler))),
            0,
            dispatchParams
        );

        // Verify the fill was successful
        assertTrue(claimHash != bytes32(0), "Claim hash should be non-zero");
        assertTrue(mandateHash != bytes32(0), "Mandate hash should be non-zero");
        assertEq(fillAmounts.length, 1, "Should have 1 fill amount");
        assertEq(claimAmounts.length, 1, "Should have 1 claim amount");
    }

    // ============ Test cancelAndDispatch Coverage ============

    /**
     * @notice Test cancelAndDispatch function
     * @dev Covers line 334 in Tribunal.sol (cancelAndDispatch execution)
     */
    function test_CancelAndDispatch_Success() public {
        // Deploy valid dispatch callback
        ValidDispatchCallbackMock callbackTarget = new ValidDispatchCallbackMock();

        BatchCompact memory compact = _getBatchCompact(10 ether);
        FillParameters memory fill = _getFillParameters(1 ether);
        Mandate memory mandate = _getMandate(fill);
        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);

        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: 1, target: address(callbackTarget), value: 0, context: ""
        });

        // Cancel and dispatch
        vm.prank(sponsor);
        bytes32 claimHash = tribunal.cancelAndDispatch(compact, mandateHash, dispatchParams);

        // Verify the cancel was successful
        assertTrue(claimHash != bytes32(0), "Claim hash should be non-zero");

        // Verify it was marked as cancelled
        bytes32 filledStatus = tribunal.filled(claimHash);
        assertEq(
            filledStatus,
            bytes32(uint256(uint160(sponsor))),
            "Should be marked as cancelled by sponsor"
        );
    }

    // ============ Helper Functions ============

    function _getBatchCompact(uint256 amount) internal view returns (BatchCompact memory) {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(uint96(1)), token: address(token), amount: amount});

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
            baselinePriorityFee: 0,
            scalingFactor: 1e18,
            priceCurve: new uint256[](0),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });
    }

    function _getMandate(FillParameters memory fill) internal view returns (Mandate memory) {
        FillParameters[] memory fills = new FillParameters[](1);
        fills[0] = fill;

        return Mandate({adjuster: adjuster, fills: fills});
    }

    function _getAdjustment(uint256 targetBlock) internal view returns (Adjustment memory) {
        return Adjustment({
            adjuster: adjuster,
            fillIndex: 0,
            targetBlock: targetBlock,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0),
            adjustmentAuthorization: ""
        });
    }

    function _toAdjustmentSignature(
        Adjustment memory adjustment,
        BatchCompact memory compact,
        Mandate memory mandate
    ) internal view returns (bytes memory) {
        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);
        bytes32 claimHash = tribunal.deriveClaimHash(compact, mandateHash);

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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adjusterPrivateKey, digest);

        return abi.encodePacked(r, s, v);
    }
}

/**
 * @notice Mock contract that returns wrong selector from tribunalCallback
 */
contract InvalidRecipientCallbackMock {
    function tribunalCallback(
        uint256,
        bytes32,
        bytes32,
        address,
        uint256,
        BatchCompact calldata,
        bytes32,
        bytes calldata
    ) external pure returns (bytes4) {
        return bytes4(0xdeadbeef); // Wrong selector
    }
}

/**
 * @notice Mock contract that returns wrong selector from dispatchCallback
 */
contract InvalidDispatchCallbackMock {
    function dispatchCallback(
        uint256,
        BatchCompact calldata,
        bytes32,
        bytes32,
        bytes32,
        uint256,
        uint256[] memory,
        bytes calldata
    ) external payable returns (bytes4) {
        return bytes4(0xdeadbeef); // Wrong selector
    }
}

/**
 * @notice Mock contract that returns correct selector from dispatchCallback
 */
contract ValidDispatchCallbackMock {
    function dispatchCallback(
        uint256,
        BatchCompact calldata,
        bytes32,
        bytes32,
        bytes32,
        uint256,
        uint256[] memory,
        bytes calldata
    ) external payable returns (bytes4) {
        return IDispatchCallback.dispatchCallback.selector;
    }
}
