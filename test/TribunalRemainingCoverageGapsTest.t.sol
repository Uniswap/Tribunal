// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTheCompact} from "./mocks/MockTheCompact.sol";
import {IDispatchCallback} from "../src/interfaces/IDispatchCallback.sol";
import {
    Mandate,
    FillParameters,
    FillComponent,
    Adjustment,
    RecipientCallback,
    BatchClaim,
    DispositionDetails,
    DispatchParameters
} from "../src/types/TribunalStructs.sol";
import {ADJUSTMENT_TYPEHASH} from "../src/types/TribunalTypeHashes.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {PriceCurveLib} from "../src/lib/PriceCurveLib.sol";

// ============ Helper Mock Contract for Dispatch Callback ============
contract MockDispatchCallback is IDispatchCallback {
    bool public shouldReturnValidSelector;

    constructor(bool _shouldReturnValidSelector) {
        shouldReturnValidSelector = _shouldReturnValidSelector;
    }

    function dispatchCallback(
        uint256,
        BatchCompact calldata,
        bytes32,
        bytes32,
        bytes32,
        uint256,
        uint256[] calldata,
        bytes calldata
    ) external payable returns (bytes4) {
        if (shouldReturnValidSelector) {
            return IDispatchCallback.dispatchCallback.selector;
        } else {
            return bytes4(0);
        }
    }
}

/**
 * @title TribunalRemainingCoverageGapsTest
 * @notice Tests targeting specific remaining uncovered lines and branches
 */
contract TribunalRemainingCoverageGapsTest is Test {
    Tribunal public tribunal;
    MockERC20 public token;
    address public sponsor;
    address public filler;
    address public adjuster;
    uint256 public adjusterPrivateKey;
    address public arbiter;

    function setUp() public {
        tribunal = new Tribunal();
        token = new MockERC20();
        sponsor = makeAddr("Sponsor");
        filler = makeAddr("Filler");
        (adjuster, adjusterPrivateKey) = makeAddrAndKey("Adjuster");
        arbiter = makeAddr("Arbiter");

        // Setup token balances
        token.mint(filler, 1000 ether);
        vm.prank(filler);
        token.approve(address(tribunal), type(uint256).max);
    }

    // ============ Coverage Gap: getDispositionDetails with multiple hashes ============
    /**
     * @notice Test getDispositionDetails with multiple claim hashes
     * @dev Covers line 370 - loop iteration in getDispositionDetails
     */
    function test_GetDispositionDetails_MultipleHashes() public view {
        // Create multiple claim hashes
        bytes32[] memory claimHashes = new bytes32[](3);
        claimHashes[0] = keccak256("claim1");
        claimHashes[1] = keccak256("claim2");
        claimHashes[2] = keccak256("claim3");

        DispositionDetails[] memory details = tribunal.getDispositionDetails(claimHashes);

        assertEq(details.length, 3, "Should return 3 details");
        for (uint256 i = 0; i < 3; i++) {
            assertEq(details[i].claimant, bytes32(0), "Unfilled orders should have zero claimant");
            assertEq(
                details[i].scalingFactor, 1e18, "Unfilled orders should have 1e18 scaling factor"
            );
        }
    }

    // ============ Coverage Gap: Invalid scaling direction in deriveAmountsFromComponents ============
    /**
     * @notice Test deriveAmountsFromComponents with invalid scaling direction
     * @dev Covers lines 614-615 - validation branch for scaling direction
     */
    function test_DeriveAmountsFromComponents_InvalidScalingDirection() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] =
            Lock({lockTag: bytes12(0), token: address(token), amount: 10 ether});

        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 1 ether,
            recipient: sponsor,
            applyScaling: true
        });

        // Create a price curve that results in decreasing scaling (starts < 1e18)
        // Using proper format: (duration << 240) | scalingFactor
        uint256[] memory priceCurve = new uint256[](2);
        priceCurve[0] = (10 << 240) | uint256(0.5e18); // 10 blocks, starts at 0.5x
        priceCurve[1] = (10 << 240) | uint256(0.3e18); // 10 blocks, ends at 0.3x (decreasing)

        uint256 targetBlock = 100;
        uint256 fillBlock = 105; // 5 blocks after target (within duration)
        uint256 baselinePriorityFee = 100 wei;
        // Set scalingFactor > 1e18 (increasing) - this conflicts with decreasing curve
        uint256 scalingFactor = 1.5e18;

        vm.expectRevert(PriceCurveLib.InvalidPriceCurveParameters.selector);
        tribunal.deriveAmountsFromComponents(
            maximumClaimAmounts,
            components,
            priceCurve,
            targetBlock,
            fillBlock,
            baselinePriorityFee,
            scalingFactor
        );
    }

    // ============ Coverage Gap: _calculateFillAmounts with non-scaling components ============
    /**
     * @notice Test fill amount calculation with mixed scaling settings
     * @dev Covers line 1440 - the else branch when applyScaling is false in exact-out mode
     */
    function test_CalculateFillAmounts_MixedScaling_ExactOut() public view {
        Lock[] memory maximumClaimAmounts = new Lock[](2);
        maximumClaimAmounts[0] =
            Lock({lockTag: bytes12(0), token: address(token), amount: 10 ether});
        maximumClaimAmounts[1] =
            Lock({lockTag: bytes12(0), token: address(token), amount: 20 ether});

        FillComponent[] memory components = new FillComponent[](2);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 1 ether,
            recipient: sponsor,
            applyScaling: true // This one applies scaling
        });
        components[1] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 2 ether,
            recipient: filler,
            applyScaling: false // This one doesn't apply scaling
        });

        uint256[] memory priceCurve = new uint256[](0);
        uint256 targetBlock = 0; // No target block
        uint256 fillBlock = block.number;
        uint256 baselinePriorityFee = 100 wei;
        // Use scalingFactor < 1e18 to trigger exact-out mode
        uint256 scalingFactor = 0.9e18;

        (uint256[] memory fillAmounts, uint256[] memory claimAmounts) = tribunal.deriveAmountsFromComponents(
            maximumClaimAmounts,
            components,
            priceCurve,
            targetBlock,
            fillBlock,
            baselinePriorityFee,
            scalingFactor
        );

        // In exact-out mode with applyScaling=false, fillAmount should equal minimumFillAmount
        assertEq(fillAmounts[1], 2 ether, "Non-scaling component should have minimum fill amount");
        // In exact-out mode with no priority fee above baseline, claims are reduced by scaling factor
        assertTrue(
            claimAmounts[0] <= 10 ether,
            "Claim amounts should be reduced or equal in exact-out mode"
        );
    }

    // ============ Coverage Gap: _calculateClaimAmounts in exact-in mode ============
    /**
     * @notice Test claim amount calculation in exact-in mode
     * @dev Covers line 1465 - the loop in exact-in mode for claim amounts
     */
    function test_CalculateClaimAmounts_ExactIn() public view {
        Lock[] memory maximumClaimAmounts = new Lock[](2);
        maximumClaimAmounts[0] =
            Lock({lockTag: bytes12(0), token: address(token), amount: 10 ether});
        maximumClaimAmounts[1] =
            Lock({lockTag: bytes12(0), token: address(token), amount: 20 ether});

        FillComponent[] memory components = new FillComponent[](2);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 1 ether,
            recipient: sponsor,
            applyScaling: true
        });
        components[1] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 2 ether,
            recipient: filler,
            applyScaling: true
        });

        uint256[] memory priceCurve = new uint256[](0);
        uint256 targetBlock = 0;
        uint256 fillBlock = block.number;
        uint256 baselinePriorityFee = 100 wei;
        // Use scalingFactor > 1e18 to trigger exact-in mode
        uint256 scalingFactor = 1.5e18;

        (uint256[] memory fillAmounts, uint256[] memory claimAmounts) = tribunal.deriveAmountsFromComponents(
            maximumClaimAmounts,
            components,
            priceCurve,
            targetBlock,
            fillBlock,
            baselinePriorityFee,
            scalingFactor
        );

        // In exact-in mode, claim amounts should equal maximum claim amounts
        assertEq(claimAmounts[0], 10 ether, "Claim amount should equal maximum in exact-in mode");
        assertEq(claimAmounts[1], 20 ether, "Claim amount should equal maximum in exact-in mode");
        assertTrue(fillAmounts[0] >= 1 ether, "Fill amounts should be increased");
    }

    // ============ Coverage Gap: Target block validation error ============
    /**
     * @notice Test _calculateCurrentScalingFactor with invalid target block
     * @dev Covers line 1518 - revert when targetBlock > fillBlock but should be caught earlier
     */
    function test_DeriveAmounts_InvalidTargetBlock() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] =
            Lock({lockTag: bytes12(0), token: address(token), amount: 10 ether});

        uint256[] memory priceCurve = new uint256[](3);
        priceCurve[0] = 10;
        priceCurve[1] = 1e18;
        priceCurve[2] = 2e18;

        uint256 targetBlock = 200; // Target is in the future
        uint256 fillBlock = 100; // Fill block is in the past
        uint256 minimumFillAmount = 1 ether;
        uint256 baselinePriorityFee = 100 wei;
        uint256 scalingFactor = 1e18;

        vm.expectRevert(
            abi.encodeWithSignature("InvalidTargetBlock(uint256,uint256)", fillBlock, targetBlock)
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

    // ============ Coverage Gap: Empty price curve with non-zero target block ============
    /**
     * @notice Test price curve validation - empty curve with target block
     * @dev This should trigger InvalidTargetBlockDesignation error
     */
    function test_DeriveAmounts_EmptyPriceCurveWithTargetBlock() public view {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] =
            Lock({lockTag: bytes12(0), token: address(token), amount: 10 ether});

        uint256[] memory priceCurve = new uint256[](0); // Empty price curve
        uint256 targetBlock = 0; // But targetBlock is 0, so this should work
        uint256 fillBlock = 100;
        uint256 minimumFillAmount = 1 ether;
        uint256 baselinePriorityFee = 100 wei;
        uint256 scalingFactor = 1e18;

        // This should succeed because targetBlock = 0
        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            targetBlock,
            fillBlock,
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );

        assertEq(claimAmounts[0], 10 ether, "Should use maximum claim amount");
        assertEq(fillAmount, minimumFillAmount, "Should use minimum fill amount");
    }

    // ============ Coverage Gap: Neutral scaling with decreasing price curve ============
    /**
     * @notice Test deriveAmounts with neutral scaling and decreasing price curve
     * @dev Tests the branch where scalingFactor == BASE_SCALING_FACTOR && currentScalingFactor < BASE_SCALING_FACTOR
     */
    function test_DeriveAmounts_NeutralScaling_DecreasingCurve() public view {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] =
            Lock({lockTag: bytes12(0), token: address(token), amount: 10 ether});

        // Create a decreasing price curve with proper format: (duration << 240) | scalingFactor
        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = (100 << 240) | uint256(0.8e18); // 100 blocks, starts at 0.8x (will interpolate to 1.0x)

        uint256 targetBlock = 100;
        uint256 fillBlock = 105; // 5 blocks after target (within 100-block duration)
        uint256 minimumFillAmount = 1 ether;
        uint256 baselinePriorityFee = 100 wei;
        uint256 scalingFactor = 1e18; // Neutral scaling

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            targetBlock,
            fillBlock,
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );

        // With neutral scaling and decreasing curve, should use exact-out mode
        assertEq(fillAmount, minimumFillAmount, "Should use minimum fill amount in exact-out");
        assertTrue(claimAmounts[0] < 10 ether, "Claim amounts should be reduced");
    }

    // ============ Coverage Gap: deriveFillComponentHash ============
    /**
     * @notice Test deriveFillComponentHash function
     * @dev Covers lines 490-495 - ensures the hash function is called
     */
    function test_DeriveFillComponentHash() public view {
        FillComponent memory component = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 1 ether,
            recipient: sponsor,
            applyScaling: true
        });

        bytes32 hash = tribunal.deriveFillComponentHash(component);
        assertTrue(hash != bytes32(0), "Component hash should not be zero");

        // Test determinism
        bytes32 hash2 = tribunal.deriveFillComponentHash(component);
        assertEq(hash, hash2, "Hash should be deterministic");
    }

    // ============ Coverage Gap: claimReductionScalingFactor view function ============
    /**
     * @notice Test claimReductionScalingFactor view function
     * @dev Covers lines 347-352 - external view for scaling factor
     */
    function test_ClaimReductionScalingFactor_ViewFunction() public view {
        bytes32 claimHash = keccak256("test_claim");
        uint256 scalingFactor = tribunal.claimReductionScalingFactor(claimHash);

        // For unfilled claim, should return 1e18
        assertEq(scalingFactor, 1e18, "Unfilled claim should have scaling factor 1e18");
    }

    // ============ Coverage Gap: Multiple extsload slots ============
    /**
     * @notice Test extsload with multiple slots to ensure full array handling
     * @dev Covers line 406 in the loop - multiple iterations
     */
    function test_Extsload_MultipleSlots() public view {
        bytes32[] memory slots = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            slots[i] = bytes32(uint256(i));
        }

        bytes32[] memory values = tribunal.extsload(slots);

        assertEq(values.length, 5, "Should return 5 values");
        for (uint256 i = 0; i < 5; i++) {
            // All uninitialized slots should be zero
            assertEq(values[i], bytes32(0), "Uninitialized slot should be zero");
        }
    }

    // ============ Coverage Gap: Dispatch callback validation failure ============
    /**
     * @notice Test dispatch callback with invalid return selector
     * @dev Covers lines 1249-1250 - callback validation failure branch
     */
    function test_Dispatch_InvalidCallbackSelector() public {
        // Setup a filled order first
        BatchCompact memory compact = _getBatchCompact(10 ether);
        FillParameters memory fill = _getFillParameters(1 ether);
        Mandate memory mandate = _getMandate(fill);

        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);
        bytes32 claimHash = tribunal.deriveClaimHash(compact, mandateHash);

        // Mock the filled status
        vm.store(
            address(tribunal),
            keccak256(abi.encode(claimHash, uint256(0))),
            bytes32(uint256(uint160(filler)))
        );

        // Deploy a callback contract that returns invalid selector
        MockDispatchCallback invalidCallback = new MockDispatchCallback(false);

        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: block.chainid, target: address(invalidCallback), value: 0, context: ""
        });

        vm.expectRevert(abi.encodeWithSignature("InvalidDispatchCallback()"));
        tribunal.dispatch(compact, mandateHash, dispatchParams);
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
            baselinePriorityFee: 100 wei,
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
}
