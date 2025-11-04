// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {DeployTheCompact} from "./helpers/DeployTheCompact.sol";
import {TheCompact} from "the-compact/src/TheCompact.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FillerContract} from "./mocks/FillerContract.sol";
import {ITribunalCallback} from "../src/interfaces/ITribunalCallback.sol";
import {IRecipientCallback} from "../src/interfaces/IRecipientCallback.sol";
import {
    Mandate,
    Fill,
    FillComponent,
    Adjustment,
    RecipientCallback,
    FillRecipient
} from "../src/types/TribunalStructs.sol";
import {
    BatchCompact,
    Lock,
    BATCH_COMPACT_TYPEHASH,
    LOCK_TYPEHASH
} from "the-compact/src/types/EIP712Types.sol";
import {COMPACT_TYPEHASH_WITH_MANDATE} from "../src/types/TribunalTypeHashes.sol";

contract TribunalFillComponentTest is DeployTheCompact, ITribunalCallback {
    using FixedPointMathLib for uint256;

    Tribunal public tribunal;
    TheCompact public compactContract;
    MockERC20 public token1;
    MockERC20 public token2;
    address sponsor;
    uint256 sponsorPrivateKey;
    address adjuster;
    uint256 adjusterPrivateKey;
    FillerContract public filler;
    uint96 allocatorId;

    uint256[] public emptyPriceCurve;

    // Event definitions for testing
    event SingleChainFill(
        address indexed sponsor,
        bytes32 indexed claimant,
        bytes32 claimHash,
        FillRecipient[] fillRecipients,
        uint256[] claimAmounts,
        uint256 targetBlock
    );

    receive() external payable {}

    function _generateSponsorSignature(BatchCompact memory compact, bytes32 mandateHash)
        internal
        view
        returns (bytes memory)
    {
        string memory witnessTypestring =
            "address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,Mandate_FillComponent[] components,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_FillComponent(address fillToken,uint256 minimumFillAmount,address recipient,bool applyScaling)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context";

        string memory fullTypestring = string.concat(
            "BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Lock[] commitments,Mandate mandate)Lock(bytes12 lockTag,address token,uint256 amount)Mandate(",
            witnessTypestring,
            ")"
        );

        bytes32 computedTypehash = keccak256(bytes(fullTypestring));

        bytes32[] memory lockHashes = new bytes32[](compact.commitments.length);
        for (uint256 i = 0; i < compact.commitments.length; i++) {
            lockHashes[i] = keccak256(
                abi.encode(
                    LOCK_TYPEHASH,
                    compact.commitments[i].lockTag,
                    compact.commitments[i].token,
                    compact.commitments[i].amount
                )
            );
        }
        bytes32 commitmentsHash = keccak256(abi.encodePacked(lockHashes));

        bytes32 structHash = keccak256(
            abi.encode(
                computedTypehash,
                compact.arbiter,
                compact.sponsor,
                compact.nonce,
                compact.expires,
                commitmentsHash,
                mandateHash
            )
        );

        bytes32 domainSeparator = compactContract.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        bytes32 r;
        bytes32 vs;
        (r, vs) = vm.signCompact(sponsorPrivateKey, digest);

        return abi.encodePacked(r, vs);
    }

    function _signAdjustment(bytes32 claimHash, Adjustment memory adjustment)
        internal
        view
        returns (bytes memory)
    {
        bytes32 adjustmentHash = keccak256(
            abi.encode(
                keccak256(
                    "Adjustment(bytes32 claimHash,uint256 fillIndex,uint256 targetBlock,uint256[] supplementalPriceCurve,bytes32 validityConditions)"
                ),
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

    function setUp() public {
        compactContract = deployTheCompact();

        vm.prank(address(this));
        allocatorId = compactContract.__registerAllocator(address(this), "");

        tribunal = new Tribunal();
        token1 = new MockERC20();
        token2 = new MockERC20();
        (sponsor, sponsorPrivateKey) = makeAddrAndKey("sponsor");
        (adjuster, adjusterPrivateKey) = makeAddrAndKey("adjuster");
        filler = new FillerContract();

        emptyPriceCurve = new uint256[](0);

        vm.deal(sponsor, 100 ether);
        vm.deal(address(filler), 100 ether);

        token1.transfer(address(filler), 1000e18);
        token2.transfer(address(filler), 1000e18);
    }

    function tribunalCallback(
        bytes32,
        Lock[] calldata,
        uint256[] calldata,
        address,
        uint256,
        uint256
    ) external {}

    function authorizeClaim(
        bytes32,
        address,
        address,
        uint256,
        uint256,
        uint256[2][] calldata,
        bytes calldata
    ) external pure returns (bytes32) {
        return this.authorizeClaim.selector;
    }

    /// @notice Test that multiple recipients can each receive tokens as part of a single fill
    /// and that the event contains all the correct information
    function test_MultipleRecipientsReceiveTokensWithCorrectEvent() public {
        // Set up three recipients
        address recipient1 = address(0xBEEF);
        address recipient2 = address(0xCAFE);
        address recipient3 = address(0xDEAD);

        // Deposit tokens to TheCompact for the sponsor
        uint256 depositAmount = 300e18;
        token1.transfer(sponsor, depositAmount);

        vm.startPrank(sponsor);
        token1.approve(address(compactContract), depositAmount);
        compactContract.depositERC20(
            address(token1), bytes12(uint96(allocatorId)), depositAmount, sponsor
        );
        vm.stopPrank();

        // Create three fill components with different recipients and amounts
        FillComponent[] memory components = new FillComponent[](3);
        components[0] = FillComponent({
            fillToken: address(token1),
            minimumFillAmount: 100e18,
            recipient: recipient1,
            applyScaling: false
        });
        components[1] = FillComponent({
            fillToken: address(token1),
            minimumFillAmount: 50e18,
            recipient: recipient2,
            applyScaling: false
        });
        components[2] = FillComponent({
            fillToken: address(token1),
            minimumFillAmount: 75e18,
            recipient: recipient3,
            applyScaling: false
        });

        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            components: components,
            baselinePriorityFee: 0,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] =
            Lock({lockTag: bytes12(uint96(allocatorId)), token: address(token1), amount: 225e18});

        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);

        bytes memory sponsorSig = _generateSponsorSignature(
            BatchCompact({
                arbiter: address(tribunal),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            mandateHash
        );

        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
            compact: BatchCompact({
                arbiter: address(tribunal),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: sponsorSig,
            allocatorSignature: new bytes(0)
        });

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: vm.getBlockNumber(),
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        bytes32 claimHash = tribunal.deriveClaimHash(claim.compact, mandateHash);
        bytes memory adjustmentSignature = _signAdjustment(claimHash, adjustment);

        vm.prank(address(filler));
        token1.approve(address(tribunal), type(uint256).max);

        // Expect the event with all three recipients
        FillRecipient[] memory expectedFillRecipients = new FillRecipient[](3);
        expectedFillRecipients[0] = FillRecipient({fillAmount: 100e18, recipient: recipient1});
        expectedFillRecipients[1] = FillRecipient({fillAmount: 50e18, recipient: recipient2});
        expectedFillRecipients[2] = FillRecipient({fillAmount: 75e18, recipient: recipient3});

        uint256[] memory expectedClaimAmounts = new uint256[](1);
        expectedClaimAmounts[0] = 225e18;

        vm.expectEmit(true, true, false, true);
        emit SingleChainFill(
            sponsor,
            bytes32(uint256(uint160(address(filler)))),
            claimHash,
            expectedFillRecipients,
            expectedClaimAmounts,
            vm.getBlockNumber()
        );

        vm.prank(address(filler));
        tribunal.fillAndClaim(
            claim,
            fill,
            adjuster,
            adjustment,
            adjustmentSignature,
            fillHashes,
            bytes32(uint256(uint160(address(filler)))),
            0
        );

        // Verify all recipients received their tokens
        assertEq(token1.balanceOf(recipient1), 100e18, "Recipient 1 should receive 100 tokens");
        assertEq(token1.balanceOf(recipient2), 50e18, "Recipient 2 should receive 50 tokens");
        assertEq(token1.balanceOf(recipient3), 75e18, "Recipient 3 should receive 75 tokens");
    }

    /// @notice Test that one fill component applies scaling (priority fee + price curve) while another doesn't
    function test_MixedScalingAndNonScalingComponents_ExactIn_WithPriorityFee() public {
        address recipient1 = address(0xBEEF);
        address recipient2 = address(0xCAFE);

        // Deposit tokens to TheCompact for the sponsor
        uint256 depositAmount = 250e18;
        token1.transfer(sponsor, depositAmount);

        vm.startPrank(sponsor);
        token1.approve(address(compactContract), depositAmount);
        compactContract.depositERC20(
            address(token1), bytes12(uint96(allocatorId)), depositAmount, sponsor
        );
        vm.stopPrank();

        // Create components: one with scaling, one without
        FillComponent[] memory components = new FillComponent[](2);
        components[0] = FillComponent({
            fillToken: address(token1),
            minimumFillAmount: 100e18,
            recipient: recipient1,
            applyScaling: true // This should scale with priority fees and price curve
        });
        components[1] = FillComponent({
            fillToken: address(token1),
            minimumFillAmount: 50e18,
            recipient: recipient2,
            applyScaling: false // This should NOT scale
        });

        // Dutch auction: starts at 1.2x, ends at 1e18 over 10 blocks
        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = (10 << 240) | uint256(1.2e18);

        // Use exact-in mode (scalingFactor > 1e18) with priority fee scaling
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            components: components,
            baselinePriorityFee: 100 gwei,
            scalingFactor: 15e17, // 1.5x amplification of priority fees
            priceCurve: priceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] =
            Lock({lockTag: bytes12(uint96(allocatorId)), token: address(token1), amount: 150e18});

        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);

        bytes memory sponsorSig = _generateSponsorSignature(
            BatchCompact({
                arbiter: address(tribunal),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            mandateHash
        );

        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
            compact: BatchCompact({
                arbiter: address(tribunal),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: sponsorSig,
            allocatorSignature: new bytes(0)
        });

        uint256 targetBlock = vm.getBlockNumber();

        // Fill 5 blocks into the auction (halfway through 10-block curve)
        vm.roll(targetBlock + 5);

        // Set priority fee 2 wei above baseline (small amount to avoid overflow)
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + 100 gwei + 2);

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: targetBlock,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        bytes32 claimHash = tribunal.deriveClaimHash(claim.compact, mandateHash);
        bytes memory adjustmentSignature = _signAdjustment(claimHash, adjustment);

        vm.prank(address(filler));
        token1.approve(address(tribunal), type(uint256).max);

        vm.prank(address(filler));
        (,, uint256[] memory fillAmounts,) = tribunal.fillAndClaim(
            claim,
            fill,
            adjuster,
            adjustment,
            adjustmentSignature,
            fillHashes,
            bytes32(uint256(uint160(address(filler)))),
            0
        );

        // Calculate expected scaling for component 0 (applyScaling=true):
        // Price curve at block 5: interpolate from 1.2 to 1.0 over 10 blocks = 1.1
        // Priority fee scaling: 1.1 + ((1.5 - 1.0) * 2 wei) = 1.1 + (0.5 * 2 wei) ≈ 1.1 + 0.000000000000000001
        // So fillAmount[0] ≈ 100e18 * 1.1 = 110e18 (the 2 wei makes negligible difference)
        uint256 currentScalingFactor = 1.1e18; // Price curve at block 5
        uint256 priorityFeeAboveBaseline = 2; // 2 wei
        uint256 scalingMultiplier =
            currentScalingFactor + ((15e17 - 1e18) * priorityFeeAboveBaseline);
        uint256 expectedFillAmount0 = uint256(100e18).mulWadUp(scalingMultiplier);

        assertEq(fillAmounts[0], expectedFillAmount0, "Component 0 should be scaled");
        assertEq(
            token1.balanceOf(recipient1),
            expectedFillAmount0,
            "Recipient 1 should receive scaled amount"
        );

        // Component 1 with applyScaling=false: remains at minimum
        assertEq(fillAmounts[1], 50e18, "Component 1 should remain unscaled at 50 tokens");
        assertEq(token1.balanceOf(recipient2), 50e18, "Recipient 2 should receive unscaled amount");
    }

    /// @notice Test that providing the same token + recipient pair twice still works
    /// and does both transfers (eg that a single fill isn't somehow double-counted)
    function test_DuplicateTokenRecipientPairDoesDoubleTransfer() public {
        address recipient = address(0xBEEF);

        // Deposit tokens to TheCompact for the sponsor
        uint256 depositAmount = 300e18;
        token1.transfer(sponsor, depositAmount);

        vm.startPrank(sponsor);
        token1.approve(address(compactContract), depositAmount);
        compactContract.depositERC20(
            address(token1), bytes12(uint96(allocatorId)), depositAmount, sponsor
        );
        vm.stopPrank();

        // Create three components with the SAME token and recipient
        FillComponent[] memory components = new FillComponent[](3);
        components[0] = FillComponent({
            fillToken: address(token1),
            minimumFillAmount: 100e18,
            recipient: recipient,
            applyScaling: false
        });
        components[1] = FillComponent({
            fillToken: address(token1),
            minimumFillAmount: 75e18,
            recipient: recipient, // Same recipient
            applyScaling: false
        });
        components[2] = FillComponent({
            fillToken: address(token1),
            minimumFillAmount: 50e18,
            recipient: recipient, // Same recipient again
            applyScaling: false
        });

        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            components: components,
            baselinePriorityFee: 0,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] =
            Lock({lockTag: bytes12(uint96(allocatorId)), token: address(token1), amount: 225e18});

        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);

        bytes memory sponsorSig = _generateSponsorSignature(
            BatchCompact({
                arbiter: address(tribunal),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            mandateHash
        );

        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
            compact: BatchCompact({
                arbiter: address(tribunal),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: sponsorSig,
            allocatorSignature: new bytes(0)
        });

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: vm.getBlockNumber(),
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        bytes32 claimHash = tribunal.deriveClaimHash(claim.compact, mandateHash);
        bytes memory adjustmentSignature = _signAdjustment(claimHash, adjustment);

        vm.prank(address(filler));
        token1.approve(address(tribunal), type(uint256).max);

        uint256 recipientBalanceBefore = token1.balanceOf(recipient);

        vm.prank(address(filler));
        tribunal.fillAndClaim(
            claim,
            fill,
            adjuster,
            adjustment,
            adjustmentSignature,
            fillHashes,
            bytes32(uint256(uint160(address(filler)))),
            0
        );

        // Verify that ALL THREE transfers occurred (total = 100 + 75 + 50 = 225)
        uint256 recipientBalanceAfter = token1.balanceOf(recipient);
        assertEq(
            recipientBalanceAfter - recipientBalanceBefore,
            225e18,
            "Recipient should receive sum of all three components"
        );
    }

    /// @notice Test exact-out mode with mixed scaling flags
    /// In exact-out mode (scalingFactor < 1e18), fill amounts stay at minimum regardless of applyScaling flag
    /// This test confirms that components with applyScaling=false work correctly in exact-out mode
    function test_MixedScalingAndNonScalingComponents_ExactOut_WithPriorityFee() public {
        address recipient1 = address(0xBEEF);
        address recipient2 = address(0xCAFE);

        // Deposit tokens to TheCompact for the sponsor (more than filler will provide)
        uint256 depositAmount = 200e18;
        token1.transfer(sponsor, depositAmount);

        vm.startPrank(sponsor);
        token1.approve(address(compactContract), depositAmount);
        compactContract.depositERC20(
            address(token1), bytes12(uint96(allocatorId)), depositAmount, sponsor
        );
        vm.stopPrank();

        // Create components: one with scaling, one without
        FillComponent[] memory components = new FillComponent[](2);
        components[0] = FillComponent({
            fillToken: address(token1),
            minimumFillAmount: 100e18,
            recipient: recipient1,
            applyScaling: true // In exact-out, this doesn't scale fill amount
        });
        components[1] = FillComponent({
            fillToken: address(token1),
            minimumFillAmount: 50e18,
            recipient: recipient2,
            applyScaling: false // This also doesn't scale fill amount
        });

        // Reverse dutch auction: starts at 0.8x, ends at 1e18 over 10 blocks
        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = (10 << 240) | uint256(8e17);

        // Use exact-out mode (scalingFactor < 1e18) with a less aggressive scaling factor
        // to avoid underflow when combined with priority fees
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            components: components,
            baselinePriorityFee: 100 gwei,
            scalingFactor: 999999999900000000, // Just slightly below 1e18 for exact-out mode
            priceCurve: priceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] =
            Lock({lockTag: bytes12(uint96(allocatorId)), token: address(token1), amount: 200e18});

        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);

        bytes memory sponsorSig = _generateSponsorSignature(
            BatchCompact({
                arbiter: address(tribunal),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            mandateHash
        );

        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
            compact: BatchCompact({
                arbiter: address(tribunal),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: sponsorSig,
            allocatorSignature: new bytes(0)
        });

        uint256 targetBlock = vm.getBlockNumber();

        // Fill 5 blocks into the auction (halfway through 10-block curve)
        vm.roll(targetBlock + 5);

        // Set priority fee 5 gwei above baseline
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + 100 gwei + 5 gwei);

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: targetBlock,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        bytes32 claimHash = tribunal.deriveClaimHash(claim.compact, mandateHash);
        bytes memory adjustmentSignature = _signAdjustment(claimHash, adjustment);

        vm.prank(address(filler));
        token1.approve(address(tribunal), type(uint256).max);

        vm.prank(address(filler));
        (,, uint256[] memory fillAmounts, uint256[] memory claimAmounts) = tribunal.fillAndClaim(
            claim,
            fill,
            adjuster,
            adjustment,
            adjustmentSignature,
            fillHashes,
            bytes32(uint256(uint160(address(filler)))),
            0
        );

        // In exact-out mode, BOTH components stay at their minimum fill amounts
        // regardless of the applyScaling flag
        assertEq(fillAmounts[0], 100e18, "Component 0 should remain at minimum in exact-out");
        assertEq(
            token1.balanceOf(recipient1),
            100e18,
            "Recipient 1 should receive minimum amount in exact-out"
        );

        assertEq(fillAmounts[1], 50e18, "Component 1 should remain at minimum in exact-out");
        assertEq(
            token1.balanceOf(recipient2),
            50e18,
            "Recipient 2 should receive minimum amount in exact-out"
        );

        // The scaling happens on the claim side (what filler receives)
        // Price curve at block 5: interpolate from 0.8 to 1.0 over 10 blocks = 0.9
        // scalingFactor is 999999999900000000 (just below 1e18)
        // Priority fee scaling: 0.9 - ((1e18 - 999999999900000000) * 5 gwei)
        //                      = 0.9 - (100000000 * 5000000000)
        //                      = 0.9 - 500000000000000000 (0.5e18)
        //                      = 0.4e18
        uint256 currentScalingFactor = 9e17; // Price curve at block 5
        uint256 priorityFeeAboveBaseline = 5 gwei;
        uint256 scalingMultiplier =
            currentScalingFactor - ((1e18 - 999999999900000000) * priorityFeeAboveBaseline);
        uint256 expectedClaimAmount = uint256(200e18).mulWad(scalingMultiplier);

        assertEq(
            claimAmounts[0], expectedClaimAmount, "Claim amount should be scaled down in exact-out"
        );
    }

    /// @notice Test that recipient fallback is correctly triggered on the first fill component
    /// recipient when there are multiple recipients
    function test_RecipientFallbackUsesFirstComponent() public {
        address recipient1 = address(new MockRecipientCallback());
        address recipient2 = address(0xCAFE);
        address recipient3 = address(0xDEAD);

        // Deposit tokens to TheCompact for the sponsor
        uint256 depositAmount = 300e18;
        token1.transfer(sponsor, depositAmount);

        vm.startPrank(sponsor);
        token1.approve(address(compactContract), depositAmount);
        compactContract.depositERC20(
            address(token1), bytes12(uint96(allocatorId)), depositAmount, sponsor
        );
        vm.stopPrank();

        // Create three fill components
        FillComponent[] memory components = new FillComponent[](3);
        components[0] = FillComponent({
            fillToken: address(token1),
            minimumFillAmount: 100e18,
            recipient: recipient1, // This should receive the callback
            applyScaling: false
        });
        components[1] = FillComponent({
            fillToken: address(token1),
            minimumFillAmount: 50e18,
            recipient: recipient2,
            applyScaling: false
        });
        components[2] = FillComponent({
            fillToken: address(token1),
            minimumFillAmount: 75e18,
            recipient: recipient3,
            applyScaling: false
        });

        // Set up a recipient callback
        RecipientCallback[] memory callbacks = new RecipientCallback[](1);
        callbacks[0] = RecipientCallback({
            chainId: 1,
            compact: BatchCompact({
                arbiter: address(0),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: new Lock[](0)
            }),
            mandateHash: bytes32(0),
            context: hex"1234"
        });

        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            components: components,
            baselinePriorityFee: 0,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipientCallback: callbacks,
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] =
            Lock({lockTag: bytes12(uint96(allocatorId)), token: address(token1), amount: 225e18});

        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);

        bytes memory sponsorSig = _generateSponsorSignature(
            BatchCompact({
                arbiter: address(tribunal),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            mandateHash
        );

        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
            compact: BatchCompact({
                arbiter: address(tribunal),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: sponsorSig,
            allocatorSignature: new bytes(0)
        });

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: vm.getBlockNumber(),
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        bytes32 claimHash = tribunal.deriveClaimHash(claim.compact, mandateHash);
        bytes memory adjustmentSignature = _signAdjustment(claimHash, adjustment);

        vm.prank(address(filler));
        token1.approve(address(tribunal), type(uint256).max);

        // The MockRecipientCallback will track if it was called
        MockRecipientCallback mockCallback = MockRecipientCallback(recipient1);

        vm.prank(address(filler));
        tribunal.fillAndClaim(
            claim,
            fill,
            adjuster,
            adjustment,
            adjustmentSignature,
            fillHashes,
            bytes32(uint256(uint160(address(filler)))),
            0
        );

        // Verify that the callback was triggered on the FIRST component's recipient
        assertTrue(
            mockCallback.callbackReceived(), "Callback should be received by first recipient"
        );
        assertEq(
            mockCallback.lastFillToken(),
            address(token1),
            "Callback should receive correct token address"
        );
        assertEq(
            mockCallback.lastFillAmount(),
            100e18,
            "Callback should receive first component's fill amount"
        );
        assertEq(mockCallback.lastContext(), hex"1234", "Callback should receive correct context");
    }
}

/// @notice Mock contract to test recipient callback
contract MockRecipientCallback is IRecipientCallback {
    bool public callbackReceived;
    uint256 public lastChainId;
    bytes32 public lastClaimHash;
    bytes32 public lastMandateHash;
    address public lastFillToken;
    uint256 public lastFillAmount;
    BatchCompact public lastCompact;
    bytes32 public lastCallbackMandateHash;
    bytes public lastContext;

    function tribunalCallback(
        uint256 chainId,
        bytes32 claimHash,
        bytes32 mandateHash,
        address fillToken,
        uint256 fillAmount,
        BatchCompact calldata compact,
        bytes32 callbackMandateHash,
        bytes calldata context
    ) external returns (bytes4) {
        callbackReceived = true;
        lastChainId = chainId;
        lastClaimHash = claimHash;
        lastMandateHash = mandateHash;
        lastFillToken = fillToken;
        lastFillAmount = fillAmount;
        lastCompact = compact;
        lastCallbackMandateHash = callbackMandateHash;
        lastContext = context;

        return IRecipientCallback.tribunalCallback.selector;
    }
}
