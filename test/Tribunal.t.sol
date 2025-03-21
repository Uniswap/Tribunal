// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {FixedPointMathLib} from "the-compact/lib/solady/src/utils/FixedPointMathLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract TribunalTest is Test {
    using FixedPointMathLib for uint256;

    Tribunal public tribunal;
    MockERC20 public token;
    address sponsor;

    uint256[] public emptyDecayCurve;

    // Mandate type string
    string constant MANDATE_TYPESTRING =
        "Mandate(uint256 chainId,address tribunal,address recipient,uint256 expires,address token,uint256 minimumAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] decayCurve,bytes32 salt)";
    bytes32 constant MANDATE_TYPEHASH = keccak256(bytes(MANDATE_TYPESTRING));

    // Compact type string with mandate witness
    string constant COMPACT_TYPESTRING_WITH_MANDATE =
        "Compact(address arbiter,address sponsor,uint256 nonce,uint256 expires,uint256 id,uint256 amount,Mandate mandate)Mandate(uint256 chainId,address tribunal,address recipient,uint256 expires,address token,uint256 minimumAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] decayCurve,bytes32 salt)";
    bytes32 constant COMPACT_TYPEHASH_WITH_MANDATE =
        keccak256(bytes(COMPACT_TYPESTRING_WITH_MANDATE));

    // Make test contract payable to receive ETH refunds
    receive() external payable {}

    function setUp() public {
        tribunal = new Tribunal();
        token = new MockERC20();
        (sponsor,) = makeAddrAndKey("sponsor");

        emptyDecayCurve = new uint256[](0);
    }

    /**
     * @notice Verify that the contract name is correctly set to "Tribunal"
     */
    function test_Name() public view {
        assertEq(tribunal.name(), "Tribunal");
    }

    function test_fillRevertsOnInvalidTargetBlock() public {
        // Create a mandate for native token settlement
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            recipient: address(0xBEEF),
            expires: uint256(block.timestamp + 1),
            token: address(0),
            minimumAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            decayCurve: emptyDecayCurve,
            salt: bytes32(uint256(1))
        });

        // Create compact
        Tribunal.Claim memory claim = Tribunal.Claim({
            chainId: block.chainid,
            compact: Tribunal.Compact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                id: 1,
                amount: 1 ether
            }),
            sponsorSignature: new bytes(0),
            allocatorSignature: new bytes(0)
        });

        // Send ETH with the fill
        vm.expectRevert(
            abi.encodeWithSignature("InvalidTargetBlock(uint256,uint256)", 100, vm.getBlockNumber())
        );
        tribunal.fill{value: 1 ether}(claim, mandate, address(this), 100, 10);
    }

    /**
     * @notice Verify that mandate hash derivation follows EIP-712 structured data hashing
     * @dev Tests mandate hash derivation with a salt value of 1
     */
    function test_DeriveMandateHash() public view {
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            recipient: address(0xCAFE),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            token: address(0xDEAD),
            minimumAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            decayCurve: emptyDecayCurve,
            salt: bytes32(uint256(1))
        });

        bytes32 expectedHash = keccak256(
            abi.encode(
                MANDATE_TYPEHASH,
                block.chainid,
                address(tribunal),
                mandate.recipient,
                mandate.expires,
                mandate.token,
                mandate.minimumAmount,
                mandate.baselinePriorityFee,
                mandate.scalingFactor,
                keccak256(abi.encodePacked(mandate.decayCurve)),
                mandate.salt
            )
        );

        assertEq(tribunal.deriveMandateHash(mandate), expectedHash);
    }

    /**
     * @notice Verify that mandate hash derivation works correctly with a different salt value
     * @dev Tests mandate hash derivation with a salt value of 2 to ensure salt uniqueness is reflected
     */
    function test_DeriveMandateHash_DifferentSalt() public view {
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            recipient: address(0xCAFE),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            token: address(0xDEAD),
            minimumAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            decayCurve: emptyDecayCurve,
            salt: bytes32(uint256(2))
        });

        bytes32 expectedHash = keccak256(
            abi.encode(
                MANDATE_TYPEHASH,
                block.chainid,
                address(tribunal),
                mandate.recipient,
                mandate.expires,
                mandate.token,
                mandate.minimumAmount,
                mandate.baselinePriorityFee,
                mandate.scalingFactor,
                keccak256(abi.encodePacked(mandate.decayCurve)),
                mandate.salt
            )
        );

        assertEq(tribunal.deriveMandateHash(mandate), expectedHash);
    }

    /**
     * @notice Verify that fill reverts when attempting to use an expired mandate
     * @dev Sets up a mandate that has already expired and ensures the fill function reverts
     */
    function test_FillRevertsOnExpiredMandate() public {
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            recipient: address(0xCAFE),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            token: address(0xDEAD),
            minimumAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            decayCurve: emptyDecayCurve,
            salt: bytes32(uint256(1))
        });

        Tribunal.Claim memory claim = Tribunal.Claim({
            chainId: block.chainid,
            compact: Tribunal.Compact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                id: 1,
                amount: 1 ether
            }),
            sponsorSignature: new bytes(0),
            allocatorSignature: new bytes(0)
        });

        vm.warp(mandate.expires + 1);

        vm.expectRevert(abi.encodeWithSignature("Expired(uint256)", mandate.expires));
        tribunal.fill(claim, mandate, address(this));
    }

    /**
     * @notice Verify that fill reverts when attempting to reuse a claim
     * @dev Tests that a mandate's claim hash cannot be reused after it has been processed
     */
    function test_FillRevertsOnReusedClaim() public {
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            recipient: address(0xCAFE),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            token: address(0xDEAD),
            minimumAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            decayCurve: emptyDecayCurve,
            salt: bytes32(uint256(1))
        });

        Tribunal.Claim memory claim = Tribunal.Claim({
            chainId: block.chainid,
            compact: Tribunal.Compact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                id: 1,
                amount: 1 ether
            }),
            sponsorSignature: new bytes(0),
            allocatorSignature: new bytes(0)
        });

        tribunal.fill(claim, mandate, address(this));

        vm.expectRevert(abi.encodeWithSignature("AlreadyClaimed()"));
        tribunal.fill(claim, mandate, address(this));
    }

    /**
     * @notice Verify that filled correctly identifies used claims
     * @dev Tests that filled returns true for claims that have been processed by fill
     */
    function test_FilledReturnsTrueForUsedClaim() public {
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            recipient: address(0xCAFE),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            token: address(0xDEAD),
            minimumAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            decayCurve: emptyDecayCurve,
            salt: bytes32(uint256(1))
        });

        Tribunal.Claim memory claim = Tribunal.Claim({
            chainId: block.chainid,
            compact: Tribunal.Compact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                id: 1,
                amount: 1 ether
            }),
            sponsorSignature: new bytes(0),
            allocatorSignature: new bytes(0)
        });

        bytes32 claimHash =
            tribunal.deriveClaimHash(claim.compact, tribunal.deriveMandateHash(mandate));
        assertFalse(tribunal.filled(claimHash));

        vm.expectEmit(true, true, false, true, address(tribunal));
        emit Tribunal.Fill(sponsor, address(this), claimHash, 1 ether, 1 ether, 0);

        tribunal.fill(claim, mandate, address(this));
        assertTrue(tribunal.filled(claimHash));
    }

    /**
     * @notice Verify amount derivation with no priority fee above baseline
     * @dev Should return original amounts when priority fee equals baseline
     */
    function test_DeriveAmounts_NoPriorityFee() public {
        uint256 maximumAmount = 100 ether;
        uint256 minimumAmount = 95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 1e18; // 1 WAD, no scaling

        // Set block base fee and priority fee
        vm.fee(baselinePriorityFee);
        vm.txGasPrice(baselinePriorityFee + 1 wei); // Set gas price slightly above base fee

        (uint256 fillAmount, uint256 claimAmount) =
            tribunal.deriveAmounts(maximumAmount, minimumAmount, baselinePriorityFee, scalingFactor);

        assertEq(
            fillAmount,
            minimumAmount,
            "Fill amount should equal minimum when no priority fee above baseline"
        );
        assertEq(
            claimAmount,
            maximumAmount,
            "Claim amount should equal maximum when no priority fee above baseline"
        );
    }

    /**
     * @notice Verify amount derivation for exact-out case (scaling factor < 1e18)
     * @dev Should keep minimum settlement fixed and scale down maximum claim
     */
    function test_DeriveAmounts_ExactOut() public {
        uint256 maximumAmount = 1 ether;
        uint256 minimumAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 5e17; // 0.5 WAD, decreases claim by 50% per priority fee increment

        // Set block base fee lower than priority fee
        vm.fee(1 gwei);
        // Set priority fee to baseline + 2 wei
        vm.txGasPrice(1 gwei + baselinePriorityFee + 2 wei);

        (uint256 fillAmount, uint256 claimAmount) =
            tribunal.deriveAmounts(maximumAmount, minimumAmount, baselinePriorityFee, scalingFactor);

        assertEq(fillAmount, minimumAmount, "Fill amount should remain at minimum for exact-out");

        // Priority fee above baseline is 2 wei
        // For exact-out with 0.5 WAD scaling factor:
        // scalingMultiplier = 1e18 - ((1e18 - 0.5e18) * 2)
        //                   = 1e18 - (0.5e18 * 2)
        //                   = 1e18 - 1e18
        //                   = 0
        uint256 scalingMultiplier = 1e18 - ((1e18 - scalingFactor) * 2);
        uint256 expectedClaimAmount = maximumAmount.mulWad(scalingMultiplier);
        assertEq(claimAmount, expectedClaimAmount, "Claim amount should go to zero");
    }

    /**
     * @notice Verify amount derivation for exact-in case (scaling factor > 1e18)
     * @dev Should keep maximum claim fixed and scale up minimum settlement
     */
    function test_DeriveAmounts_ExactIn() public {
        uint256 maximumAmount = 1 ether;
        uint256 minimumAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 15e17; // 1.5 WAD, increases settlement by 50% per priority fee increment

        // Set block base fee lower than priority fee
        vm.fee(1 gwei);
        // Set priority fee to baseline + 2 wei
        vm.txGasPrice(1 gwei + baselinePriorityFee + 2 wei);

        (uint256 fillAmount, uint256 claimAmount) =
            tribunal.deriveAmounts(maximumAmount, minimumAmount, baselinePriorityFee, scalingFactor);

        assertEq(claimAmount, maximumAmount, "Claim amount should remain at maximum for exact-in");

        // Priority fee above baseline is 2 wei
        // For exact-in with 1.5 WAD scaling factor:
        // scalingMultiplier = 1e18 + ((1.5e18 - 1e18) * 2)
        //                   = 1e18 + (0.5e18 * 2)
        //                   = 1e18 + 1e18
        //                   = 2e18
        uint256 scalingMultiplier = 1e18 + ((scalingFactor - 1e18) * 2);
        uint256 expectedFillAmount = minimumAmount.mulWadUp(scalingMultiplier);
        assertEq(fillAmount, expectedFillAmount, "Fill amount should double");
    }

    /**
     * @notice Verify amount derivation with extreme priority fees
     * @dev Should handle large priority fees without overflow
     */
    function test_DeriveAmounts_ExtremePriorityFee() public {
        uint256 maximumAmount = 1 ether;
        uint256 minimumAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        uint256 scalingFactor = 15e17; // 1.5 WAD, increases settlement by 50% per priority fee increment

        // Set block base fee lower than priority fee
        uint256 baseFee = 1 gwei;
        vm.fee(baseFee);
        // Set priority fee to baseline + 10 wei
        vm.txGasPrice(baseFee + baselinePriorityFee + 10 wei);

        (uint256 fillAmount, uint256 claimAmount) =
            tribunal.deriveAmounts(maximumAmount, minimumAmount, baselinePriorityFee, scalingFactor);

        assertEq(claimAmount, maximumAmount, "Claim amount should remain at maximum for exact-in");

        // Priority fee above baseline is 10 wei
        // For exact-in with 1.5 WAD scaling factor:
        // scalingMultiplier = 1e18 + ((1.5e18 - 1e18) * 10)
        //                   = 1e18 + (0.5e18 * 10)
        //                   = 1e18 + 5e18
        //                   = 6e18
        uint256 scalingMultiplier = 1e18 + ((scalingFactor - 1e18) * 10);
        uint256 expectedFillAmount = minimumAmount.mulWadUp(scalingMultiplier);
        assertEq(fillAmount, expectedFillAmount, "Fill amount should increase 6x");
    }

    function test_DeriveAmounts_RealisticExactIn() public {
        uint256 maximumAmount = 1 ether;
        uint256 minimumAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        // 1.0000000001 WAD - 10% increase per gwei above baseline
        uint256 scalingFactor = 1000000000100000000;

        // Set block base fee lower than priority fee
        vm.fee(1 gwei);
        // Set priority fee to baseline + 5 gwei
        vm.txGasPrice(1 gwei + baselinePriorityFee + 5 gwei);

        (uint256 fillAmount, uint256 claimAmount) =
            tribunal.deriveAmounts(maximumAmount, minimumAmount, baselinePriorityFee, scalingFactor);

        assertEq(claimAmount, maximumAmount, "Claim amount should remain at maximum for exact-in");

        // Priority fee above baseline is 5 gwei (5e9 wei)
        // For exact-in with 1.0000000001 WAD scaling factor:
        // scalingMultiplier = 1e18 + ((1.0000000001e18 - 1e18) * 5e9)
        //                   = 1e18 + (1e11 * 5e9)
        //                   = 1e18 + 0.5e18
        //                   = 1.5e18
        // So fill amount increases by 50%
        uint256 scalingMultiplier = 1e18 + ((scalingFactor - 1e18) * 5 gwei);
        uint256 expectedFillAmount = minimumAmount.mulWadUp(scalingMultiplier);
        assertEq(fillAmount, expectedFillAmount, "Fill amount should increase by 50%");
    }

    function test_DeriveAmounts_RealisticExactOut() public {
        uint256 maximumAmount = 1 ether;
        uint256 minimumAmount = 0.95 ether;
        uint256 baselinePriorityFee = 100 gwei;
        // 0.9999999999 WAD - 10% decrease per gwei above baseline
        uint256 scalingFactor = 999999999900000000;

        // Set block base fee lower than priority fee
        vm.fee(1 gwei);
        // Set priority fee to baseline + 5 gwei
        vm.txGasPrice(1 gwei + baselinePriorityFee + 5 gwei);

        (uint256 fillAmount, uint256 claimAmount) =
            tribunal.deriveAmounts(maximumAmount, minimumAmount, baselinePriorityFee, scalingFactor);

        assertEq(fillAmount, minimumAmount, "Fill amount should remain at minimum for exact-out");

        // Priority fee above baseline is 5 gwei (5e9 wei)
        // For exact-out with 0.9999999999 WAD scaling factor:
        // scalingMultiplier = 1e18 - ((1e18 - 0.9999999999e18) * 5e9)
        //                   = 1e18 - (1e11 * 5e9)
        //                   = 1e18 - 0.5e18
        //                   = 0.5e18
        // So claim amount decreases by 50%
        uint256 scalingMultiplier = 1e18 - ((1e18 - scalingFactor) * 5 gwei);
        uint256 expectedClaimAmount = maximumAmount.mulWad(scalingMultiplier);
        assertEq(claimAmount, expectedClaimAmount, "Claim amount should decrease by 50%");
    }

    function test_FillSettlesNativeToken() public {
        // Create a mandate for native token settlement
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            recipient: address(0xBEEF),
            expires: uint256(block.timestamp + 1),
            token: address(0),
            minimumAmount: 1 ether,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            decayCurve: emptyDecayCurve,
            salt: bytes32(uint256(1))
        });

        // Create compact
        Tribunal.Claim memory claim = Tribunal.Claim({
            chainId: block.chainid,
            compact: Tribunal.Compact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                id: 1,
                amount: 1 ether
            }),
            sponsorSignature: new bytes(0),
            allocatorSignature: new bytes(0)
        });

        // Send ETH with the fill
        uint256 initialSenderBalance = address(this).balance;
        tribunal.fill{value: 2 ether}(claim, mandate, address(this));

        // Check that recipient received exactly 1 ETH
        assertEq(address(0xBEEF).balance, 1 ether);
        // Check that sender sent exactly 1 ETH (2 ETH sent - 1 ETH refunded)
        assertEq(initialSenderBalance - address(this).balance, 1 ether);
    }

    function test_FillSettlesERC20Token() public {
        // Create a mandate for ERC20 token settlement
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            recipient: address(0xBEEF),
            expires: uint256(block.timestamp + 1),
            token: address(token),
            minimumAmount: 100e18,
            baselinePriorityFee: 0,
            scalingFactor: 0,
            decayCurve: emptyDecayCurve,
            salt: bytes32(uint256(1))
        });

        // Create compact
        Tribunal.Claim memory claim = Tribunal.Claim({
            chainId: block.chainid,
            compact: Tribunal.Compact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                id: 1,
                amount: 1 ether
            }),
            sponsorSignature: new bytes(0),
            allocatorSignature: new bytes(0)
        });

        // Approve tokens for settlement
        token.approve(address(tribunal), type(uint256).max);

        // Record initial balances
        uint256 initialRecipientBalance = token.balanceOf(address(0xBEEF));
        uint256 initialSenderBalance = token.balanceOf(address(this));

        // Derive claim hash
        bytes32 claimHash =
            tribunal.deriveClaimHash(claim.compact, tribunal.deriveMandateHash(mandate));

        vm.expectEmit(true, true, false, true, address(tribunal));
        emit Tribunal.Fill(sponsor, address(this), claimHash, 100e18, 1 ether, 0);

        // Execute fill
        tribunal.fill(claim, mandate, address(this));

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
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            recipient: address(0xCAFE),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            token: address(0xDEAD),
            minimumAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            decayCurve: emptyDecayCurve,
            salt: bytes32(uint256(1))
        });

        Tribunal.Claim memory claim = Tribunal.Claim({
            chainId: block.chainid,
            compact: Tribunal.Compact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                id: 1,
                amount: 1 ether
            }),
            sponsorSignature: new bytes(0),
            allocatorSignature: new bytes(0)
        });

        // First derive the mandate hash
        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);

        // Calculate expected claim hash
        bytes32 expectedHash = keccak256(
            abi.encode(
                COMPACT_TYPEHASH_WITH_MANDATE,
                claim.compact.arbiter,
                claim.compact.sponsor,
                claim.compact.nonce,
                claim.compact.expires,
                claim.compact.id,
                claim.compact.amount,
                mandateHash
            )
        );

        // Verify the derived claim hash matches the expected hash
        assertEq(tribunal.deriveClaimHash(claim.compact, mandateHash), expectedHash);
    }

    /**
     * @notice Verify that quote function returns expected placeholder value
     */
    function test_Quote() public {
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            recipient: address(0xCAFE),
            expires: 1703116800,
            token: address(0xDEAD),
            minimumAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            decayCurve: emptyDecayCurve,
            salt: bytes32(uint256(1))
        });

        Tribunal.Claim memory claim = Tribunal.Claim({
            chainId: block.chainid,
            compact: Tribunal.Compact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                id: 1,
                amount: 1 ether
            }),
            sponsorSignature: new bytes(0),
            allocatorSignature: new bytes(0)
        });

        address claimant = address(this);

        // Fund the test contract with some ETH for the placeholder calculation
        vm.deal(address(this), 1000 ether);

        uint256 expectedQuote = address(this).balance / 1000;
        assertEq(tribunal.quote(claim, mandate, claimant), expectedQuote);
    }

    /**
     * @notice Verify that getCompactWitnessDetails returns correct values
     */
    function test_GetCompactWitnessDetails() public view {
        (string memory witnessTypeString, uint256 tokenArg, uint256 amountArg) =
            tribunal.getCompactWitnessDetails();

        assertEq(
            witnessTypeString,
            "Mandate mandate)Mandate(uint256 chainId,address tribunal,address recipient,uint256 expires,address token,uint256 minimumAmount,uint256 baselinePriorityFee,uint256 scalingFactor,bytes32 salt)"
        );
        assertEq(tokenArg, 4);
        assertEq(amountArg, 5);
    }

    /**
     * @notice Verify that fill reverts when gas price is below base fee
     */
    function test_FillRevertsOnInvalidGasPrice() public {
        Tribunal.Mandate memory mandate = Tribunal.Mandate({
            recipient: address(0xCAFE),
            expires: 1703116800,
            token: address(0xDEAD),
            minimumAmount: 1 ether,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            decayCurve: emptyDecayCurve,
            salt: bytes32(uint256(1))
        });

        Tribunal.Claim memory claim = Tribunal.Claim({
            chainId: block.chainid,
            compact: Tribunal.Compact({
                arbiter: address(this),
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                id: 1,
                amount: 1 ether
            }),
            sponsorSignature: new bytes(0),
            allocatorSignature: new bytes(0)
        });

        // Set block base fee higher than gas price
        vm.fee(2 gwei);
        vm.txGasPrice(1 gwei);

        vm.expectRevert(abi.encodeWithSignature("InvalidGasPrice()"));
        tribunal.fill(claim, mandate, address(this));
    }
}
