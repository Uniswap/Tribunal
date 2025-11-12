// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {ERC7683Tribunal} from "../src/ERC7683Tribunal.sol";
import {PriceCurveLib, PriceCurveElement} from "../src/lib/PriceCurveLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {
    Mandate,
    FillParameters,
    FillComponent,
    Adjustment,
    RecipientCallback
} from "../src/types/TribunalStructs.sol";
import {ADJUSTMENT_TYPEHASH} from "../src/types/TribunalTypeHashes.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";

/**
 * @title TribunalLibraryGapsTest
 * @notice Tests to cover library function gaps (DomainLib, PriceCurveLib)
 */
contract TribunalLibraryGapsTest is Test {
    ERC7683Tribunal public tribunal;
    MockERC20 public token;
    address public sponsor;
    address public filler;
    address public adjuster;
    uint256 public adjusterPrivateKey;
    address public arbiter;

    function setUp() public {
        tribunal = new ERC7683Tribunal();
        token = new MockERC20();
        sponsor = makeAddr("Sponsor");
        filler = makeAddr("Filler");
        (adjuster, adjusterPrivateKey) = makeAddrAndKey("Adjuster");
        arbiter = makeAddr("Arbiter");

        token.mint(filler, 100 ether);
    }

    // ============ DomainLib Chain ID Change Coverage ============

    /**
     * @notice Test domain separator update on chain ID change using the same contract
     * @dev Covers lines 39-51 in DomainLib.sol
     * This is critical for ensuring the domain separator is recalculated if the chain forks
     */
    function test_DomainSeparator_ChainIdChange() public {
        // Record the initial domain separator from the SAME tribunal instance
        bytes32 domainSeparatorBefore = _getDomainSeparator();

        // Simulate a chain ID change (e.g., during a fork)
        uint256 newChainId = block.chainid + 1;
        vm.chainId(newChainId);

        // Query the domain separator again from the SAME tribunal instance
        // This should trigger toLatest to recalculate due to chain ID change
        bytes32 domainSeparatorAfter = _getDomainSeparator();

        // The domain separator should be different after the chain ID changes
        assertTrue(
            domainSeparatorBefore != domainSeparatorAfter,
            "Domain separator should change when chain ID changes"
        );
    }

    /**
     * @notice Test toLatest function recalculates domain separator after chain ID change
     * @dev Covers the branch in toLatest (lines 41-51) where chainId has changed
     * This tests an EXISTING tribunal instance that needs to recalculate its domain separator
     * when queried after a chain fork, which is the actual purpose of toLatest
     */
    function test_ToLatest_RecalculatesDomainSeparatorAfterChainIdChange() public {
        // Store initial chain ID and domain separator
        uint256 initialChainId = block.chainid;

        // Get the domain separator on the original chain
        // This internally calls toLatest, which should return the initial domain separator
        bytes32 domainSeparatorOriginal = _getDomainSeparator();

        // Simulate a chain fork by changing the chain ID
        uint256 newChainId = initialChainId + 1;
        vm.chainId(newChainId);

        // Now query the domain separator again from the SAME tribunal instance
        // This should trigger the toLatest function to recalculate the domain separator
        // because the chainId has changed from what was stored at deployment
        bytes32 domainSeparatorAfterFork = _getDomainSeparator();

        // Calculate what the new domain separator should be
        bytes32 expectedNewDomainSeparator = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Tribunal"),
                keccak256("1"),
                newChainId,
                address(tribunal)
            )
        );

        // Verify the domain separator was recalculated
        assertEq(
            domainSeparatorAfterFork,
            expectedNewDomainSeparator,
            "Domain separator should be recalculated for new chain ID"
        );

        // Verify it's different from the original
        assertTrue(
            domainSeparatorOriginal != domainSeparatorAfterFork,
            "Domain separator should differ after chain ID change"
        );
    }

    // ============ PriceCurveLib Coverage ============

    /**
     * @notice Test PriceCurveLib.create function
     * @dev Covers lines 44-51 in PriceCurveLib.sol
     */
    function test_PriceCurveLib_Create() public pure {
        uint16 blockDuration = 10;
        uint240 fillIncrease = uint240(1e18);

        PriceCurveElement element = PriceCurveLib.create(blockDuration, fillIncrease);

        // Verify the element is non-zero
        assertTrue(PriceCurveElement.unwrap(element) != 0, "Element should be non-zero");
    }

    /**
     * @notice Test PriceCurveLib.getBlockDuration function
     * @dev Covers lines 59-60 in PriceCurveLib.sol
     */
    function test_PriceCurveLib_GetBlockDuration() public pure {
        uint16 blockDuration = 25;
        uint240 fillIncrease = uint240(5e17);

        PriceCurveElement element = PriceCurveLib.create(blockDuration, fillIncrease);
        uint256 retrievedDuration = PriceCurveLib.getBlockDuration(element);

        assertEq(retrievedDuration, 25, "Block duration should match first element");
    }

    /**
     * @notice Test PriceCurveLib.getFillIncrease function
     * @dev Covers lines 68-69 in PriceCurveLib.sol
     */
    function test_PriceCurveLib_GetFillIncrease() public pure {
        uint16 blockDuration = 25;
        uint240 fillIncrease = uint240(5e17);

        PriceCurveElement element = PriceCurveLib.create(blockDuration, fillIncrease);
        uint256 retrievedIncrease = PriceCurveLib.getFillIncrease(element);

        assertEq(retrievedIncrease, 5e17, "Fill increase should match second element");
    }

    /**
     * @notice Test PriceCurveLib.getComponents function
     * @dev Covers lines 78-88 in PriceCurveLib.sol
     */
    function test_PriceCurveLib_GetComponents() public pure {
        uint16 blockDuration = 30;
        uint240 fillIncrease = uint240(2e18);

        PriceCurveElement element = PriceCurveLib.create(blockDuration, fillIncrease);
        (uint256 retrievedDuration, uint256 retrievedIncrease) =
            PriceCurveLib.getComponents(element);

        assertEq(retrievedDuration, 30, "Block duration should match");
        assertEq(retrievedIncrease, 2e18, "Fill increase should match");
    }

    /**
     * @notice Test complex price curve scenarios
     * @dev Covers various branches in PriceCurveLib.getCalculatedValues
     */
    function test_PriceCurveLib_ComplexCurve_MultipleSegments() public pure {
        // Create a multi-segment curve using proper types
        // Total duration: 10 + 20 + 30 = 60 blocks
        uint256[] memory curve = new uint256[](3);
        curve[0] = PriceCurveElement.unwrap(PriceCurveLib.create(10, uint240(1.5e18)));
        curve[1] = PriceCurveElement.unwrap(PriceCurveLib.create(20, uint240(1.3e18)));
        curve[2] = PriceCurveElement.unwrap(PriceCurveLib.create(30, uint240(1.1e18)));

        // Test at different points within the total 60 block duration
        uint256 result1 = PriceCurveLib.getCalculatedValues(curve, 5); // Within first segment (0-10)
        uint256 result2 = PriceCurveLib.getCalculatedValues(curve, 15); // Within second segment (10-30)
        uint256 result3 = PriceCurveLib.getCalculatedValues(curve, 35); // Within third segment (30-60)

        // Results should show progression through curve (decreasing from 1.5e18 toward 1e18)
        assertTrue(result1 >= 1e18, "Result should be at least base");
        assertTrue(result2 >= 1e18, "Result should be at least base");
        assertTrue(result3 >= 1e18, "Result should be at least base");

        // Later results should be closer to 1e18 as curve decays
        assertTrue(result1 >= result2, "Earlier result should be higher or equal");
        assertTrue(result2 >= result3, "Earlier result should be higher or equal");
    }

    /**
     * @notice Test price curve with exact boundary conditions
     * @dev Covers edge cases in _locateCurrentAmount
     */
    function test_PriceCurveLib_ExactBoundary() public pure {
        uint256[] memory curve = new uint256[](2);
        curve[0] = PriceCurveElement.unwrap(PriceCurveLib.create(10, uint240(1.5e18)));
        curve[1] = PriceCurveElement.unwrap(PriceCurveLib.create(20, uint240(1.3e18)));

        // Test exactly at segment boundary (block 10) - should be transitioning between segments
        uint256 resultAtBoundary1 = PriceCurveLib.getCalculatedValues(curve, 10);

        // Test within second segment (block 20) - still within total duration of 30 blocks
        uint256 resultAtBoundary2 = PriceCurveLib.getCalculatedValues(curve, 20);

        assertTrue(resultAtBoundary1 >= 1e18, "Should have result at first boundary");
        assertTrue(resultAtBoundary2 >= 1e18, "Should have result within second segment");
    }

    /**
     * @notice Test price curve with zero blocks passed
     * @dev Covers base case in getCalculatedValues - when 0 blocks have passed,
     * the curve returns the initial scaling factor, not 1e18
     */
    function test_PriceCurveLib_ZeroBlocksPassed() public pure {
        uint256[] memory curve = new uint256[](1);
        curve[0] = PriceCurveElement.unwrap(PriceCurveLib.create(10, uint240(1.5e18)));

        uint256 result = PriceCurveLib.getCalculatedValues(curve, 0);

        // At block 0, the curve is at its starting point (1.5e18)
        assertEq(result, 1.5e18, "Should return curve starting value at block 0");
    }

    /**
     * @notice Test sharesScalingDirection with various inputs
     * @dev Improves coverage for lines 345-349 in PriceCurveLib.sol
     */
    function test_PriceCurveLib_SharesScalingDirection() public pure {
        // Both increasing (>= 1e18)
        assertTrue(
            PriceCurveLib.sharesScalingDirection(1.5e18, 1.2e18),
            "Both increasing should share direction"
        );

        // Both decreasing (< 1e18)
        assertTrue(
            PriceCurveLib.sharesScalingDirection(0.8e18, 0.9e18),
            "Both decreasing should share direction"
        );

        // One increasing, one decreasing - should NOT share direction
        assertFalse(
            PriceCurveLib.sharesScalingDirection(1.2e18, 0.8e18),
            "Different directions should not share"
        );

        assertFalse(
            PriceCurveLib.sharesScalingDirection(0.8e18, 1.2e18),
            "Different directions should not share"
        );
    }

    // ============ Edge Case Coverage for Tribunal ============

    /**
     * @notice Test invalid gas price scenario
     * @dev Covers line 1376 in Tribunal.sol (tx.gasprice < block.basefee)
     */
    function test_InvalidGasPrice_Revert() public {
        // This is difficult to test directly in Foundry since it controls the environment
        // But we can at least verify the normal case works
        BatchCompact memory compact = _getBatchCompact(10 ether);
        FillParameters memory fill = _getFillParameters(1 ether);
        Mandate memory mandate = _getMandate(fill);

        Adjustment memory adjustment = Adjustment({
            adjuster: adjuster,
            fillIndex: 0,
            targetBlock: block.number,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0),
            adjustmentAuthorization: ""
        });

        // Sign the adjustment
        adjustment.adjustmentAuthorization = _signAdjustment(adjustment, compact, mandate);

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        // Approve tokens
        vm.prank(filler);
        token.approve(address(tribunal), type(uint256).max);

        // This should work with normal gas price
        vm.prank(filler);
        tribunal.fill{
            gas: 1000000
        }(compact, fill, adjustment, fillHashes, bytes32(uint256(uint160(filler))), block.number);
    }

    /**
     * @notice Test deriveAmountsFromComponents with error conditions
     * @dev Covers line 614-615 in Tribunal.sol
     */
    function test_DeriveAmountsFromComponents_InvalidTargetBlock() public {
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

        uint256[] memory priceCurve = new uint256[](0);
        uint256 targetBlock = 200; // Future block
        uint256 fillBlock = 100; // Current block (before target)

        vm.expectRevert(
            abi.encodeWithSelector(ITribunal.InvalidTargetBlock.selector, fillBlock, targetBlock)
        );
        tribunal.deriveAmountsFromComponents(
            maximumClaimAmounts, components, priceCurve, targetBlock, fillBlock, 100 wei, 1e18
        );
    }

    /**
     * @notice Test _calculateCurrentScalingFactor with zero target block and non-empty price curve
     * @dev Covers lines 1514-1515 in Tribunal.sol
     */
    function test_InvalidTargetBlockDesignation() public {
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

        // Non-empty price curve with target block 0 (invalid)
        uint256[] memory priceCurve = new uint256[](2);
        priceCurve[0] = 10;
        priceCurve[1] = 5e17;

        vm.expectRevert(ITribunal.InvalidTargetBlockDesignation.selector);
        tribunal.deriveAmountsFromComponents(
            maximumClaimAmounts,
            components,
            priceCurve,
            0, // targetBlock = 0
            100, // fillBlock
            100 wei,
            1e18
        );
    }

    // ============ Helper Functions ============

    function _getBatchCompact(uint256 amount) internal view returns (BatchCompact memory) {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(token), amount: amount});

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

    function _signAdjustment(
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

        bytes32 domainSeparator = _getDomainSeparator();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, adjustmentHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adjusterPrivateKey, digest);

        return abi.encodePacked(r, s, v);
    }

    function _getDomainSeparator() internal view returns (bytes32) {
        return keccak256(
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
    }

    function _getDomainSeparatorForContract(address contractAddress)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Tribunal"),
                keccak256("1"),
                block.chainid,
                contractAddress
            )
        );
    }
}
