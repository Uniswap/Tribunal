// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {ITheCompactClaims} from "the-compact/src/interfaces/ITheCompactClaims.sol";
import {FixedPointMathLib} from "the-compact/lib/solady/src/utils/FixedPointMathLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantReceiver} from "./mocks/ReentrantReceiver.sol";
import {Mandate, Fill, Adjustment, RecipientCallback} from "../src/types/TribunalStructs.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";

contract TribunalTest is Test {
    using FixedPointMathLib for uint256;

    Tribunal public tribunal;
    address theCompact;
    MockERC20 public token;
    address sponsor;
    address adjuster;

    uint256[] public emptyPriceCurve;

    bytes32 constant MANDATE_TYPEHASH =
        0x78eb489c4f76cd1d9bc735e1f4e8369b94ed75b11b35b0d5882f9c4c856a7a90;

    bytes32 constant COMPACT_TYPEHASH_WITH_MANDATE =
        0xab0a4c35b998b2b78c7b8f899e1423371e4fbed77d7c8e4fc3b03816cea512a5;

    // Make test contract payable to receive ETH refunds
    receive() external payable {}

    function setUp() public {
        theCompact = address(0xC0); // Mock address for ITheCompactClaims
        tribunal = new Tribunal(theCompact);
        token = new MockERC20();
        (sponsor,) = makeAddrAndKey("sponsor");
        (adjuster,) = makeAddrAndKey("adjuster");

        emptyPriceCurve = new uint256[](0);
    }

    /**
     * @notice Verify that the contract name is correctly set to "Tribunal"
     */
    function test_Name() public view {
        assertEq(tribunal.name(), "Tribunal");
    }

    function test_fillRevertsOnInvalidTargetBlock() public {
        // Create a fill for native token settlement
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            priceCurve: emptyPriceCurve,
            recipient: address(0xBEEF),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        // Create compact
        Tribunal.BatchClaim memory claim = Tribunal.BatchClaim({
            chainId: block.chainid,
            compact: BatchCompact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: new bytes(0),
            allocatorSignature: new bytes(0)
        });

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: vm.getBlockNumber() + 100,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        // Send ETH with the fill
        vm.expectRevert(
            abi.encodeWithSignature(
                "InvalidTargetBlock(uint256,uint256)",
                vm.getBlockNumber() + 100,
                vm.getBlockNumber()
            )
        );
        tribunal.fill{value: 1 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            0,
            fillHashes,
            bytes32(uint256(uint160(address(this))))
        );
    }

    /**
     * @notice Verify that mandate hash derivation follows EIP-712 structured data hashing
     * @dev Tests mandate hash derivation with a salt value of 1
     */
    function test_DeriveMandateHash() public view {
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            fillToken: address(0xDEAD),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipient: address(0xCAFE),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        bytes32 fillsHash = keccak256(abi.encodePacked(tribunal.deriveFillHash(fill)));

        bytes32 expectedHash = keccak256(
            abi.encode(
                MANDATE_TYPEHASH, block.chainid, address(tribunal), mandate.adjuster, fillsHash
            )
        );

        assertEq(tribunal.deriveMandateHash(mandate), expectedHash);
    }

    /**
     * @notice Verify that mandate hash derivation works correctly with a different salt value
     * @dev Tests mandate hash derivation with a salt value of 2 to ensure salt uniqueness is reflected
     */
    function test_DeriveMandateHash_DifferentSalt() public view {
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            fillToken: address(0xDEAD),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipient: address(0xCAFE),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(2))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        bytes32 fillsHash = keccak256(abi.encodePacked(tribunal.deriveFillHash(fill)));

        bytes32 expectedHash = keccak256(
            abi.encode(
                MANDATE_TYPEHASH, block.chainid, address(tribunal), mandate.adjuster, fillsHash
            )
        );

        assertEq(tribunal.deriveMandateHash(mandate), expectedHash);
    }

    /**
     * @notice Verify that fill reverts when attempting to use an expired mandate
     * @dev Sets up a mandate that has already expired and ensures the fill function reverts
     */
    function test_FillRevertsOnExpiredMandate() public {
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            fillToken: address(0xDEAD),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipient: address(0xCAFE),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0xDEAD), amount: 1 ether});

        Tribunal.BatchClaim memory claim = Tribunal.BatchClaim({
            chainId: block.chainid,
            compact: BatchCompact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: new bytes(0),
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

        vm.warp(fill.expires + 1);

        vm.expectRevert(abi.encodeWithSignature("ValidityConditionsNotMet()"));
        tribunal.fill(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            0,
            fillHashes,
            bytes32(uint256(uint160(address(this))))
        );
    }

    /**
     * @notice Verify that fill reverts when attempting to reuse a claim
     * @dev Tests that a mandate's claim hash cannot be reused after it has been processed
     */
    function test_FillRevertsOnReusedClaim() public {
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            fillToken: address(0xDEAD),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipient: address(0xCAFE),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0xDEAD), amount: 1 ether});

        Tribunal.BatchClaim memory claim = Tribunal.BatchClaim({
            chainId: block.chainid,
            compact: BatchCompact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: new bytes(0),
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

        tribunal.fill(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            0,
            fillHashes,
            bytes32(uint256(uint160(address(this))))
        );

        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        tribunal.fill(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            0,
            fillHashes,
            bytes32(uint256(uint160(address(this))))
        );
    }

    /**
     * @notice Verify that filled correctly identifies used claims
     * @dev Tests that filled returns true for claims that have been processed by fill
     */
    function test_FilledReturnsTrueForUsedClaim() public {
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            fillToken: address(0xDEAD),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipient: address(0xCAFE),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0xDEAD), amount: 1 ether});

        Tribunal.BatchClaim memory claim = Tribunal.BatchClaim({
            chainId: block.chainid,
            compact: BatchCompact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: new bytes(0),
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

        bytes32 claimHash =
            tribunal.deriveClaimHash(claim.compact, tribunal.deriveMandateHash(mandate));
        assertEq(tribunal.filled(claimHash), address(0));

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = commitments[0].amount;

        vm.expectEmit(true, true, true, true, address(tribunal));
        emit Tribunal.SingleChainFill(
            sponsor, address(this), claimHash, 1 ether, claimAmounts, adjustment.targetBlock
        );

        tribunal.fill(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            0,
            fillHashes,
            bytes32(uint256(uint160(address(this))))
        );
        assertEq(tribunal.filled(claimHash), address(this));
    }

    /**
     * @notice Verify amount derivation with no priority fee above baseline
     * @dev Should return original amounts when priority fee equals baseline
     */
    function test_DeriveAmounts_NoPriorityFee() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 100 ether});

        uint256 minimumFillAmount = 95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 1e18; // 1 WAD, no scaling

        // Set block base fee and priority fee
        vm.fee(baselinePriorityFee);
        vm.txGasPrice(baselinePriorityFee + 1 wei); // Set gas price slightly above base fee

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            emptyPriceCurve,
            0,
            vm.getBlockNumber(),
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );

        assertEq(
            fillAmount,
            minimumFillAmount,
            "Fill amount should equal minimum when no priority fee above baseline"
        );
        assertEq(
            claimAmounts[0],
            maximumClaimAmounts[0].amount,
            "Claim amount should equal maximum when no priority fee above baseline"
        );
    }

    /**
     * @notice Verify amount derivation for exact-out case (scaling factor < 1e18)
     * @dev Should keep minimum settlement fixed and scale down maximum claim
     */
    function test_DeriveAmounts_ExactOut() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256 minimumFillAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 5e17; // 0.5 WAD, decreases claim by 50% per priority fee increment

        // Set block base fee lower than priority fee
        vm.fee(1 gwei);
        // Set priority fee to baseline + 2 wei
        vm.txGasPrice(1 gwei + baselinePriorityFee + 2 wei);

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            emptyPriceCurve,
            0,
            vm.getBlockNumber(),
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );

        assertEq(
            fillAmount, minimumFillAmount, "Fill amount should remain at minimum for exact-out"
        );

        // Priority fee above baseline is 2 wei
        // For exact-out with 0.5 WAD scaling factor:
        // scalingMultiplier = 1e18 - ((1e18 - 0.5e18) * 2)
        //                   = 1e18 - (0.5e18 * 2)
        //                   = 1e18 - 1e18
        //                   = 0
        uint256 scalingMultiplier = 1e18 - ((1e18 - scalingFactor) * 2);
        uint256 expectedClaimAmount = maximumClaimAmounts[0].amount.mulWad(scalingMultiplier);
        assertEq(claimAmounts[0], expectedClaimAmount, "Claim amount should go to zero");
    }

    /**
     * @notice Verify amount derivation for exact-in case (scaling factor > 1e18)
     * @dev Should keep maximum claim fixed and scale up minimum settlement
     */
    function test_DeriveAmounts_ExactIn() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256 minimumFillAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 15e17; // 1.5 WAD, increases settlement by 50% per priority fee increment

        // Set block base fee lower than priority fee
        vm.fee(1 gwei);
        // Set priority fee to baseline + 2 wei
        vm.txGasPrice(1 gwei + baselinePriorityFee + 2 wei);

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            emptyPriceCurve,
            0,
            vm.getBlockNumber(),
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );

        assertEq(
            claimAmounts[0],
            maximumClaimAmounts[0].amount,
            "Claim amount should remain at maximum for exact-in"
        );

        // Priority fee above baseline is 2 wei
        // For exact-in with 1.5 WAD scaling factor:
        // scalingMultiplier = 1e18 + ((1.5e18 - 1e18) * 2)
        //                   = 1e18 + (0.5e18 * 2)
        //                   = 1e18 + 1e18
        //                   = 2e18
        uint256 scalingMultiplier = 1e18 + ((scalingFactor - 1e18) * 2);
        uint256 expectedFillAmount = minimumFillAmount.mulWadUp(scalingMultiplier);
        assertEq(fillAmount, expectedFillAmount, "Fill amount should double");
    }

    /**
     * @notice Verify amount derivation with extreme priority fees
     * @dev Should handle large priority fees without overflow
     */
    /**
     * @notice Verify amount derivation with extreme priority fees
     * @dev Should handle large priority fees without overflow
     */
    function test_DeriveAmounts_ExtremePriorityFee() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256 minimumFillAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 15e17; // 1.5 WAD, increases settlement by 50% per priority fee increment

        // Set block base fee lower than priority fee
        uint256 baseFee = 1 gwei;
        vm.fee(baseFee);
        // Set priority fee to baseline + 10 wei
        vm.txGasPrice(baseFee + baselinePriorityFee + 10 wei);

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            emptyPriceCurve,
            0,
            vm.getBlockNumber(),
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );

        assertEq(
            claimAmounts[0],
            maximumClaimAmounts[0].amount,
            "Claim amount should remain at maximum for exact-in"
        );

        // Priority fee above baseline is 10 wei
        // For exact-in with 1.5 WAD scaling factor:
        // scalingMultiplier = 1e18 + ((1.5e18 - 1e18) * 10)
        //                   = 1e18 + (0.5e18 * 10)
        //                   = 1e18 + 5e18
        //                   = 6e18
        uint256 scalingMultiplier = 1e18 + ((scalingFactor - 1e18) * 10);
        uint256 expectedFillAmount = minimumFillAmount.mulWadUp(scalingMultiplier);
        assertEq(fillAmount, expectedFillAmount, "Fill amount should increase 6x");
    }

    function test_DeriveAmounts_RealisticExactIn() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256 minimumFillAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        // 1.0000000001 WAD - 10% increase per gwei above baseline
        uint256 scalingFactor = 1000000000100000000;

        // Set block base fee lower than priority fee
        vm.fee(1 gwei);
        // Set priority fee to baseline + 5 gwei
        vm.txGasPrice(1 gwei + baselinePriorityFee + 5 gwei);

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            emptyPriceCurve,
            0,
            vm.getBlockNumber(),
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );

        assertEq(
            claimAmounts[0],
            maximumClaimAmounts[0].amount,
            "Claim amount should remain at maximum for exact-in"
        );

        // Priority fee above baseline is 5 gwei (5e9 wei)
        // For exact-in with 1.0000000001 WAD scaling factor:
        // scalingMultiplier = 1e18 + ((1.0000000001e18 - 1e18) * 5e9)
        //                   = 1e18 + (1e11 * 5e9)
        //                   = 1e18 + 0.5e18
        //                   = 1.5e18
        // So fill amount increases by 50%
        uint256 scalingMultiplier = 1e18 + ((scalingFactor - 1e18) * 5 gwei);
        uint256 expectedFillAmount = minimumFillAmount.mulWadUp(scalingMultiplier);
        assertEq(fillAmount, expectedFillAmount, "Fill amount should increase by 50%");
    }

    function test_DeriveAmounts_RealisticExactOut() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256 minimumFillAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        // 0.9999999999 WAD - 10% decrease per gwei above baseline
        uint256 scalingFactor = 999999999900000000;

        // Set block base fee lower than priority fee
        vm.fee(1 gwei);
        // Set priority fee to baseline + 5 gwei
        vm.txGasPrice(1 gwei + baselinePriorityFee + 5 gwei);

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            emptyPriceCurve,
            0,
            vm.getBlockNumber(),
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );

        assertEq(
            fillAmount, minimumFillAmount, "Fill amount should remain at minimum for exact-out"
        );

        // Priority fee above baseline is 5 gwei (5e9 wei)
        // For exact-out with 0.9999999999 WAD scaling factor:
        // scalingMultiplier = 1e18 - ((1e18 - 0.9999999999e18) * 5e9)
        //                   = 1e18 - (1e11 * 5e9)
        //                   = 1e18 - 0.5e18
        //                   = 0.5e18
        // So claim amount decreases by 50%
        uint256 scalingMultiplier = 1e18 - ((1e18 - scalingFactor) * 5 gwei);
        uint256 expectedClaimAmount = maximumClaimAmounts[0].amount.mulWad(scalingMultiplier);
        assertEq(claimAmounts[0], expectedClaimAmount, "Claim amount should decrease by 50%");
    }

    function test_DeriveAmounts_WithPriceCurve() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256 minimumFillAmount = 0.95 ether;
        uint256 baselinePriorityFee = 0;
        uint256 scalingFactor = 1e18;

        uint256 targetBlock = vm.getBlockNumber();
        uint256 fillBlock = targetBlock + 5;

        uint256[] memory priceCurve = new uint256[](2);
        priceCurve[0] = (3 << 240) | 1.2e18; // After 3 blocks, scaling = 1.2e18
        priceCurve[1] = (10 << 240) | 1.5e18; // After 10 blocks, scaling = 1.5e18

        (uint256 fillAmount, uint256[] memory claimAmounts) = tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            targetBlock,
            fillBlock,
            minimumFillAmount,
            baselinePriorityFee,
            scalingFactor
        );

        uint256 expectedScaling = 1.2e18; // Since 5 - 0 = 5, which is after 3 but before 10
        uint256 expectedFillAmount = minimumFillAmount.mulWadUp(expectedScaling);
        assertEq(fillAmount, expectedFillAmount);
        assertEq(claimAmounts[0], maximumClaimAmounts[0].amount);
    }

    function test_DeriveAmounts_InvalidTargetBlockDesignation() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        uint256[] memory priceCurve = new uint256[](1);
        priceCurve[0] = 1e18;

        vm.expectRevert(abi.encodeWithSignature("InvalidTargetBlockDesignation()"));
        tribunal.deriveAmounts(
            maximumClaimAmounts, priceCurve, 0, vm.getBlockNumber(), 1 ether, 0, 1e18
        );
    }

    function test_FillSettlesNativeToken() public {
        // Create a fill for native token settlement
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            priceCurve: emptyPriceCurve,
            recipient: address(0xBEEF),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        // Create compact
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        Tribunal.BatchClaim memory claim = Tribunal.BatchClaim({
            chainId: block.chainid,
            compact: BatchCompact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: new bytes(0),
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

        // Send ETH with the fill
        uint256 initialSenderBalance = address(this).balance;
        tribunal.fill{value: 2 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            0,
            fillHashes,
            bytes32(uint256(uint160(address(this))))
        );

        // Check that recipient received exactly 1 ETH
        assertEq(address(0xBEEF).balance, 1 ether);
        // Check that sender sent exactly 1 ETH (2 ETH sent - 1 ETH refunded)
        assertEq(initialSenderBalance - address(this).balance, 1 ether);
    }

    function test_FillSettlesERC20Token() public {
        // Create a fill for ERC20 token settlement
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            fillToken: address(token),
            minimumFillAmount: 100e18,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            priceCurve: emptyPriceCurve,
            recipient: address(0xBEEF),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        // Create compact
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(token), amount: 1 ether});

        Tribunal.BatchClaim memory claim = Tribunal.BatchClaim({
            chainId: block.chainid,
            compact: BatchCompact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: new bytes(0),
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

        // Approve tokens for settlement
        token.approve(address(tribunal), type(uint256).max);

        // Record initial balances
        uint256 initialRecipientBalance = token.balanceOf(address(0xBEEF));
        uint256 initialSenderBalance = token.balanceOf(address(this));

        // Derive claim hash
        bytes32 claimHash =
            tribunal.deriveClaimHash(claim.compact, tribunal.deriveMandateHash(mandate));

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = commitments[0].amount;

        vm.expectEmit(true, true, true, true, address(tribunal));
        emit Tribunal.SingleChainFill(
            sponsor, address(this), claimHash, 100e18, claimAmounts, adjustment.targetBlock
        );

        // Execute fill
        tribunal.fill(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            0,
            fillHashes,
            bytes32(uint256(uint160(address(this))))
        );

        // Check that recipient received exactly 100 tokens
        assertEq(token.balanceOf(address(0xBEEF)) - initialRecipientBalance, 100e18);
        // Check that sender sent exactly 100 tokens
        assertEq(initialSenderBalance - token.balanceOf(address(this)), 100e18);
    }

    /**
     * @notice Verify that claim hash derivation follows EIP-712 structured data hashing
     * @dev Tests claim hash derivation with a mandate hash and compact data
     */
    function test_DeriveClaimHash() public view {
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            fillToken: address(0xDEAD),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipient: address(0xCAFE),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0xDEAD), amount: 1 ether});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(this),
            sponsor: sponsor,
            nonce: 0,
            expires: block.timestamp + 1 hours,
            commitments: commitments
        });

        // First derive the mandate hash
        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);

        // Calculate expected claim hash
        bytes32 expectedHash = keccak256(
            abi.encode(
                tribunal.COMPACT_TYPEHASH_WITH_MANDATE(),
                compact.arbiter,
                compact.sponsor,
                compact.nonce,
                compact.expires,
                tribunal.deriveCommitmentsHash(compact.commitments),
                mandateHash
            )
        );

        // Verify the derived claim hash matches the expected hash
        assertEq(tribunal.deriveClaimHash(compact, mandateHash), expectedHash);
    }

    /**
     * @notice Verify that quote function returns expected placeholder value
     */
    function test_Quote() public {
        Fill memory fill = Fill({
            chainId: block.chainid + 1, // Different chain for cross-chain quote
            tribunal: address(tribunal),
            expires: 1703116800,
            fillToken: address(0xDEAD),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipient: address(0xCAFE),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0xDEAD), amount: 1 ether});

        Tribunal.BatchClaim memory claim = Tribunal.BatchClaim({
            chainId: block.chainid + 1,
            compact: BatchCompact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: new bytes(0),
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

        bytes32 claimant = bytes32(uint256(uint160(address(this))));

        // Fund the test contract with some ETH for the placeholder calculation
        vm.deal(address(this), 1000 ether);

        uint256 expectedQuote = address(this).balance / 1000;
        assertEq(
            tribunal.quote(
                claim, fill, adjuster, adjustment, vm.getBlockNumber(), fillHashes, claimant
            ),
            expectedQuote
        );
    }

    /**
     * @notice Verify that getCompactWitnessDetails returns correct values
     */
    function test_GetCompactWitnessDetails() public view {
        (string memory witnessTypeString, uint256 tokenArg, uint256 amountArg) =
            tribunal.getCompactWitnessDetails();

        assertEq(witnessTypeString, string.concat("Mandate(", tribunal.WITNESS_TYPESTRING(), ")"));
        assertEq(tokenArg, 4);
        assertEq(amountArg, 5);
    }

    /**
     * @notice Verify that fill reverts when gas price is below base fee
     */
    function test_FillRevertsOnInvalidGasPrice() public {
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: 1703116800,
            fillToken: address(0xDEAD),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipient: address(0xCAFE),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0xDEAD), amount: 1 ether});

        Tribunal.BatchClaim memory claim = Tribunal.BatchClaim({
            chainId: block.chainid,
            compact: BatchCompact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: new bytes(0),
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

        // Set block base fee higher than gas price
        vm.fee(2 gwei);
        vm.txGasPrice(1 gwei);

        vm.expectRevert(abi.encodeWithSignature("InvalidGasPrice()"));
        tribunal.fill(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            0,
            fillHashes,
            bytes32(uint256(uint160(address(this))))
        );
    }

    function test_FillWithReentrancyAttack() public {
        // Deploy reentrant receiver
        ReentrantReceiver reentrantReceiver = new ReentrantReceiver{value: 10 ether}(tribunal);

        // Create a fill for native token settlement
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            priceCurve: emptyPriceCurve,
            recipient: address(reentrantReceiver),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        // Create compact
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        Tribunal.BatchClaim memory claim = Tribunal.BatchClaim({
            chainId: block.chainid,
            compact: BatchCompact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: new bytes(0),
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

        // Record initial recipient balance
        uint256 initialRecipientBalance = address(reentrantReceiver).balance;

        // Send ETH with the fill
        uint256 initialSenderBalance = address(this).balance;

        // sending way too much ETH which could be stolen without reentrancy guard by the reentrant receiver
        Tribunal.BatchClaim memory reentrantClaim = reentrantReceiver.getClaim();
        Fill memory reentrantFill = reentrantReceiver.getMandate();
        vm.expectCall(
            address(tribunal),
            abi.encodeCall(
                Tribunal.fill,
                (
                    reentrantClaim,
                    reentrantFill,
                    address(reentrantReceiver),
                    adjustment,
                    new bytes(0),
                    0,
                    fillHashes,
                    bytes32(uint256(uint160(address(reentrantReceiver))))
                )
            )
        );
        tribunal.fill{value: 5 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            0,
            fillHashes,
            bytes32(uint256(uint160(address(this))))
        );

        // Check that reentrant receiver still has received their tokens
        assertEq(
            address(reentrantReceiver).balance, initialRecipientBalance + fill.minimumFillAmount
        );
        // Check that sender sent exactly 1 ETH (5 ETH sent - 1 ETH filled - 4 ETH refunded)
        assertEq(address(this).balance, initialSenderBalance - fill.minimumFillAmount);
    }

    function test_cancelSuccessfully() public {
        // Create a fill for native token settlement
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            priceCurve: emptyPriceCurve,
            recipient: address(0xBEEF),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandateStruct = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandateStruct.fills[0] = fill;

        bytes32 mandateHash = tribunal.deriveMandateHash(mandateStruct);

        // Create compact
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        Tribunal.BatchClaim memory claim = Tribunal.BatchClaim({
            chainId: block.chainid,
            compact: BatchCompact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: new bytes(0),
            allocatorSignature: new bytes(0)
        });

        bytes32 claimHash = tribunal.deriveClaimHash(claim.compact, mandateHash);

        // Cancel the claim
        vm.prank(sponsor);
        vm.expectEmit(true, false, false, false, address(tribunal));
        emit Tribunal.Cancel(sponsor, claimHash);
        tribunal.cancel(claim, mandateHash);

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: vm.getBlockNumber(),
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });

        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        // Attempt fill for a cancelled claim
        uint256 initialSenderBalance = address(this).balance;
        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        tribunal.fill{value: 2 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            0,
            fillHashes,
            bytes32(uint256(uint160(address(this))))
        );

        // Check that recipient received no eth, as the claim was cancelled
        assertEq(address(0xBEEF).balance, 0 ether);
        // Check that sender sent no eth, as the claim was cancelled
        assertEq(initialSenderBalance, address(this).balance);
    }

    function test_cancelRevertsOnInvalidSponsor(address attacker) public {
        vm.assume(attacker != sponsor);
        // Create a fill for native token settlement
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            priceCurve: emptyPriceCurve,
            recipient: address(0xBEEF),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandateStruct = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandateStruct.fills[0] = fill;

        bytes32 mandateHash = tribunal.deriveMandateHash(mandateStruct);

        // Create compact
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        Tribunal.BatchClaim memory claim = Tribunal.BatchClaim({
            chainId: block.chainid,
            compact: BatchCompact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: new bytes(0),
            allocatorSignature: new bytes(0)
        });

        // Cancel the claim as a non-sponsor
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotSponsor()"));
        tribunal.cancel(claim, mandateHash);
    }

    function test_cancelRevertsOnFilledClaim() public {
        // Create a fill for native token settlement
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            priceCurve: emptyPriceCurve,
            recipient: address(0xBEEF),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandateStruct = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandateStruct.fills[0] = fill;

        bytes32 mandateHash = tribunal.deriveMandateHash(mandateStruct);

        // Create compact
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        Tribunal.BatchClaim memory claim = Tribunal.BatchClaim({
            chainId: block.chainid,
            compact: BatchCompact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: new bytes(0),
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

        // Send ETH with the fill
        uint256 initialSenderBalance = address(this).balance;
        bytes32 claimHash = tribunal.deriveClaimHash(claim.compact, mandateHash);
        vm.expectEmit(true, true, true, true, address(tribunal));
        emit Tribunal.SingleChainFill(
            sponsor, address(this), claimHash, 1 ether, new uint256[](1), adjustment.targetBlock
        );
        tribunal.fill{value: 2 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            0,
            fillHashes,
            bytes32(uint256(uint160(address(this))))
        );

        // Check that recipient received exactly 1 ETH
        assertEq(address(0xBEEF).balance, fill.minimumFillAmount);
        // Check that sender sent exactly 1 ETH (2 ETH sent - 1 ETH refunded)
        assertEq(address(this).balance, initialSenderBalance - fill.minimumFillAmount);

        // Cancel the claim
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        tribunal.cancel(claim, mandateHash);
    }

    function test_cancelRevertsOnExpiredMandate(uint8 expires) public {
        // Create a fill for native token settlement
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(expires),
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            priceCurve: emptyPriceCurve,
            recipient: address(0xBEEF),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandateStruct = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandateStruct.fills[0] = fill;

        bytes32 mandateHash = tribunal.deriveMandateHash(mandateStruct);

        // Create compact
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        Tribunal.BatchClaim memory claim = Tribunal.BatchClaim({
            chainId: block.chainid,
            compact: BatchCompact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            sponsorSignature: new bytes(0),
            allocatorSignature: new bytes(0)
        });

        // warp to after the expiry time
        vm.warp(fill.expires + 1);

        // Cancel the claim
        vm.prank(sponsor);
        tribunal.cancel(claim, mandateHash); // Note: No revert expected for expiration in cancel
    }

    function test_cancelSuccessfullyChainExclusive() public {
        // Create a fill for native token settlement
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            priceCurve: emptyPriceCurve,
            recipient: address(0xBEEF),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandateStruct = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandateStruct.fills[0] = fill;

        bytes32 mandateHash = tribunal.deriveMandateHash(mandateStruct);

        // Create compact
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(this),
            sponsor: sponsor,
            nonce: 0,
            expires: block.timestamp + 1 hours,
            commitments: commitments
        });

        bytes32 claimHash = tribunal.deriveClaimHash(compact, mandateHash);

        // Cancel the claim
        vm.prank(sponsor);
        vm.expectEmit(true, false, false, false, address(tribunal));
        emit Tribunal.Cancel(sponsor, claimHash);
        tribunal.cancelChainExclusive(compact, mandateHash);

        Tribunal.BatchClaim memory claim = Tribunal.BatchClaim({
            chainId: block.chainid,
            compact: compact,
            sponsorSignature: new bytes(0),
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

        // Attempt fill for a cancelled claim
        uint256 initialSenderBalance = address(this).balance;
        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        tribunal.fill{value: 2 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            new bytes(0),
            0,
            fillHashes,
            bytes32(uint256(uint160(address(this))))
        );

        // Check that recipient received no eth, as the claim was cancelled
        assertEq(address(0xBEEF).balance, 0 ether);
        // Check that sender sent no eth, as the claim was cancelled
        assertEq(initialSenderBalance, address(this).balance);
    }
}
