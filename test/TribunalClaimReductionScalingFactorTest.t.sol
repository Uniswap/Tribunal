// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {
    Mandate,
    Fill,
    FillComponent,
    Adjustment,
    RecipientCallback
} from "../src/types/TribunalStructs.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {ADJUSTMENT_TYPEHASH} from "../src/types/TribunalTypeHashes.sol";
import {MockTheCompact} from "./mocks/MockTheCompact.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract TribunalClaimReductionScalingFactorTest is Test {
    using FixedPointMathLib for uint256;

    Tribunal public tribunal;
    MockTheCompact public theCompact;
    MockERC20 public token;

    address public sponsor = address(0x1);
    address public filler = address(0x3);

    // Use actual private keys for signing
    uint256 public adjusterPrivateKey = 0xA11CE;
    address public adjuster;

    uint256 public constant BASE_SCALING_FACTOR = 1e18;

    receive() external payable {}

    function setUp() public {
        theCompact = new MockTheCompact();
        tribunal = new Tribunal();
        token = new MockERC20();

        adjuster = vm.addr(adjusterPrivateKey);

        vm.label(sponsor, "sponsor");
        vm.label(adjuster, "adjuster");
        vm.label(filler, "filler");
        vm.label(address(tribunal), "tribunal");
        vm.label(address(theCompact), "theCompact");
    }

    // Helper function to sign adjustment with EIP-712
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

    function test_ClaimReductionScalingFactor_ReturnsBaseWhenNotSet() public view {
        bytes32 claimHash = keccak256("test");
        uint256 scalingFactor = tribunal.claimReductionScalingFactor(claimHash);
        assertEq(scalingFactor, BASE_SCALING_FACTOR, "Should return 1e18 when not set");
    }

    function test_ClaimReductionScalingFactor_StoredWhenReduced() public {
        // Setup a fill that will reduce claim amounts (exact-out mode with scaling < 1e18)
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(uint96(1)), token: address(token), amount: 1 ether});

        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 0.95 ether,
            recipient: filler,
            applyScaling: true
        });

        Fill memory fillData = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: block.timestamp + 1 days,
            components: components,
            baselinePriorityFee: 100 gwei,
            scalingFactor: 8e17, // 0.8 - exact-out mode
            priceCurve: new uint256[](0),
            recipientCallback: new RecipientCallback[](0),
            salt: 0
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fillData;

        BatchCompact memory compact = BatchCompact({
            arbiter: address(0),
            sponsor: sponsor,
            nonce: 1,
            expires: block.timestamp + 1 days,
            commitments: commitments
        });

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: 0,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(uint256(uint160(filler)))
        });

        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
            compact: compact, sponsorSignature: new bytes(0), allocatorSignature: new bytes(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fillData);

        // Set up gas price to have priority fee above baseline
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + 100 gwei + 1 wei); // 1 wei above baseline

        // Mock token balance and approvals
        token.mint(filler, 100 ether);
        vm.prank(filler);
        token.approve(address(tribunal), type(uint256).max);

        // Sign the adjustment properly using EIP-712
        bytes memory adjustmentAuth = _toAdjustmentSignature(adjustment, compact, mandate);

        // Execute the fill
        vm.prank(filler);
        (bytes32 claimHash,,,) = tribunal.fill(
            claim.compact,
            fillData,
            adjuster,
            adjustment,
            adjustmentAuth,
            fillHashes,
            bytes32(uint256(uint160(filler))),
            block.number
        );

        // Check that scaling factor was stored
        uint256 storedScalingFactor = tribunal.claimReductionScalingFactor(claimHash);

        // Calculate expected scaling multiplier: 1e18 - ((1e18 - 8e17) * 1) = 1e18 - 2e17 = 8e17
        uint256 expectedScalingMultiplier = BASE_SCALING_FACTOR - ((BASE_SCALING_FACTOR - 8e17) * 1);

        assertLt(
            storedScalingFactor, BASE_SCALING_FACTOR, "Scaling factor should be less than 1e18"
        );
        assertEq(
            storedScalingFactor,
            expectedScalingMultiplier,
            "Stored scaling factor should match calculated value"
        );
    }

    function test_ClaimReductionScalingFactor_NotStoredWhenNotReduced() public {
        // Setup a fill that will NOT reduce claim amounts (exact-in mode with scaling > 1e18)
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(uint96(1)), token: address(token), amount: 1 ether});

        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 0.95 ether,
            recipient: filler,
            applyScaling: true
        });

        Fill memory fillData = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: block.timestamp + 1 days,
            components: components,
            baselinePriorityFee: 100 gwei,
            scalingFactor: 15e17, // 1.5 - exact-in mode
            priceCurve: new uint256[](0),
            recipientCallback: new RecipientCallback[](0),
            salt: 0
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fillData;

        BatchCompact memory compact = BatchCompact({
            arbiter: address(0),
            sponsor: sponsor,
            nonce: 1,
            expires: block.timestamp + 1 days,
            commitments: commitments
        });

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: 0,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(uint256(uint160(filler)))
        });

        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
            compact: compact, sponsorSignature: new bytes(0), allocatorSignature: new bytes(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fillData);

        // Set up gas price
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + 100 gwei + 2 wei);

        // Mock token balance and approvals
        token.mint(filler, 100 ether);
        vm.prank(filler);
        token.approve(address(tribunal), type(uint256).max);

        // Sign the adjustment properly using EIP-712
        bytes memory adjustmentAuth = _toAdjustmentSignature(adjustment, compact, mandate);

        // Execute the fill
        vm.prank(filler);
        (bytes32 claimHash,,,) = tribunal.fill(
            claim.compact,
            fillData,
            adjuster,
            adjustment,
            adjustmentAuth,
            fillHashes,
            bytes32(uint256(uint160(filler))),
            block.number
        );

        // Check that scaling factor returns base value (not stored)
        uint256 storedScalingFactor = tribunal.claimReductionScalingFactor(claimHash);
        assertEq(storedScalingFactor, BASE_SCALING_FACTOR, "Should return 1e18 when not reduced");
    }

    function test_ClaimReductionScalingFactor_RevertsOnZeroScalingFactor() public {
        // Setup conditions that would result in a zero scaling factor
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(uint96(1)), token: address(token), amount: 1 ether});

        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 0.95 ether,
            recipient: filler,
            applyScaling: true
        });

        // Use a very aggressive scaling factor and high priority fee to drive scaling to 0
        // scalingFactor = 0 means we want to scale down from 1e18
        // With high priority fee, this could reach 0
        Fill memory fillData = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: block.timestamp + 1 days,
            components: components,
            baselinePriorityFee: 0, // No baseline, so all priority fee counts
            scalingFactor: 1, // Extremely low scaling factor (almost 0)
            priceCurve: new uint256[](0),
            recipientCallback: new RecipientCallback[](0),
            salt: 0
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fillData;

        BatchCompact memory compact = BatchCompact({
            arbiter: address(0),
            sponsor: sponsor,
            nonce: 1,
            expires: block.timestamp + 1 days,
            commitments: commitments
        });

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: 0,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(uint256(uint160(filler)))
        });

        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
            compact: compact, sponsorSignature: new bytes(0), allocatorSignature: new bytes(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fillData);

        // Set priority fee high enough to drive scaling to 0
        // scalingMultiplier = currentScalingFactor - ((1e18 - scalingFactor) * priorityFeeAboveBaseline)
        // With scalingFactor = 1, currentScalingFactor = 1e18:
        // scalingMultiplier = 1e18 - ((1e18 - 1) * priorityFeeAboveBaseline)
        // To get 0: priorityFeeAboveBaseline >= 1e18 / (1e18 - 1) ≈ 1
        vm.fee(0);
        vm.txGasPrice(2); // Priority fee of 2 wei, which is > 1

        // Mock token balance and approvals
        token.mint(filler, 100 ether);
        vm.prank(filler);
        token.approve(address(tribunal), type(uint256).max);

        // Sign the adjustment
        bytes32 adjustmentHash = keccak256(abi.encode(adjustment));
        bytes memory adjustmentAuth = abi.encodePacked(adjustmentHash);

        // Expect revert due to zero scaling factor
        vm.expectRevert();
        vm.prank(filler);
        tribunal.fill(
            claim.compact,
            fillData,
            adjuster,
            adjustment,
            adjustmentAuth,
            fillHashes,
            bytes32(uint256(uint160(filler))),
            block.number
        );
    }
}
