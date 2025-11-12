// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {PriceCurveLib} from "../src/lib/PriceCurveLib.sol";
import {
    Mandate,
    FillParameters,
    FillComponent,
    Adjustment,
    RecipientCallback,
    BatchClaim,
    DispatchParameters
} from "../src/types/TribunalStructs.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {ITheCompact} from "the-compact/src/interfaces/ITheCompact.sol";
import {ADJUSTMENT_TYPEHASH} from "../src/types/TribunalTypeHashes.sol";

/**
 * @title TribunalErrorPathsTest
 * @notice Additional test suite targeting uncovered error paths and edge cases
 */
contract TribunalErrorPathsTest is Test {
    Tribunal public tribunal;
    MockERC20 public token;

    ITheCompact public constant THE_COMPACT =
        ITheCompact(0x00000000000000171ede64904551eeDF3C6C9788);

    address public sponsor;
    address public filler;
    address public adjuster;
    uint256 public adjusterPrivateKey;

    uint256 public constant BASE_SCALING_FACTOR = 1e18;

    function setUp() public {
        // TheCompact should already be deployed at the constant address
        // If tests need it deployed, use vm.etch or fork a network where it exists

        tribunal = new Tribunal();
        token = new MockERC20();

        sponsor = makeAddr("Sponsor");
        filler = makeAddr("Filler");
        (adjuster, adjusterPrivateKey) = makeAddrAndKey("Adjuster");

        // Fund accounts
        vm.deal(sponsor, 100 ether);
        vm.deal(filler, 100 ether);
        token.mint(filler, 1000e18);
        token.mint(sponsor, 1000e18);
    }

    // ============ Error Path Coverage Tests ============

    /**
     * @notice Test invalid target block in deriveAmounts (exact-out mode)
     * @dev Covers line 534 (InvalidTargetBlock branch)
     */
    function test_InvalidTargetBlock_FutureBlock() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] =
            Lock({lockTag: bytes12(uint96(1)), token: address(token), amount: 100e18});

        uint256[] memory priceCurve = new uint256[](5);
        priceCurve[0] = 1; // blockDuration
        priceCurve[1] = 0; // fillIncrease
        priceCurve[2] = 2; // components length
        priceCurve[3] = BASE_SCALING_FACTOR;
        priceCurve[4] = BASE_SCALING_FACTOR * 2;

        uint256 targetBlock = block.number + 100; // Future block
        uint256 fillBlock = block.number;

        vm.expectRevert(
            abi.encodeWithSelector(ITribunal.InvalidTargetBlock.selector, fillBlock, targetBlock)
        );
        tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            targetBlock,
            fillBlock,
            50e18,
            1 gwei,
            BASE_SCALING_FACTOR - 1 // Exact-out mode
        );
    }

    /**
     * @notice Test invalid target block designation (priceCurve with targetBlock=0)
     * @dev Covers line 552 (InvalidTargetBlockDesignation)
     */
    function test_InvalidTargetBlockDesignation() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] =
            Lock({lockTag: bytes12(uint96(1)), token: address(token), amount: 100e18});

        uint256[] memory priceCurve = new uint256[](5);
        priceCurve[0] = 1;
        priceCurve[1] = 0;
        priceCurve[2] = 2;
        priceCurve[3] = BASE_SCALING_FACTOR;
        priceCurve[4] = BASE_SCALING_FACTOR * 2;

        vm.expectRevert(ITribunal.InvalidTargetBlockDesignation.selector);
        tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            0, // targetBlock = 0
            block.number,
            50e18,
            1 gwei,
            BASE_SCALING_FACTOR
        );
    }

    /**
     * @notice Test invalid gas price (tx.gasprice < block.basefee)
     * @dev Covers line 1378 (InvalidGasPrice error)
     */
    function test_InvalidGasPrice() public {
        BatchCompact memory compact = _createBasicCompact();
        FillParameters memory mandate = _createBasicMandate();
        mandate.baselinePriorityFee = 10 gwei;

        Adjustment memory adjustment = _createBasicAdjustment();
        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(mandate);

        bytes32 claimant = bytes32(uint256(uint160(filler)));

        vm.startPrank(filler);
        token.approve(address(tribunal), type(uint256).max);

        // Set gas price below base fee
        vm.txGasPrice(1 gwei);
        vm.fee(10 gwei);

        vm.expectRevert(ITribunal.InvalidGasPrice.selector);
        tribunal.fill(compact, mandate, adjustment, fillHashes, claimant, block.number);
        vm.stopPrank();
    }

    /**
     * @notice Test settleOrRegister with invalid commitments array length
     * @dev Covers lines 260 (InvalidCommitmentsArray error)
     */
    function test_SettleOrRegister_InvalidCommitmentsArray() public {
        bytes32 sourceClaimHash = bytes32(uint256(1));

        // Create compact with multiple commitments (should only have 1)
        Lock[] memory commitments = new Lock[](2);
        commitments[0] = Lock({lockTag: bytes12(uint96(1)), token: address(token), amount: 100e18});
        commitments[1] = Lock({lockTag: bytes12(uint96(2)), token: address(token), amount: 50e18});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(tribunal),
            sponsor: sponsor,
            nonce: 0,
            expires: block.timestamp + 1 hours,
            commitments: commitments
        });

        bytes32 mandateHash = bytes32(uint256(2));
        address recipient = address(0x4444);
        bytes memory context = "";

        vm.expectRevert(ITribunal.InvalidCommitmentsArray.selector);
        tribunal.settleOrRegister(sourceClaimHash, compact, mandateHash, recipient, context);
    }

    /**
     * @notice Test deriveRecipientCallbackHash with invalid length
     * @dev Covers line 642 (InvalidRecipientCallbackLength error)
     */
    function test_DeriveRecipientCallbackHash_InvalidLength() public {
        RecipientCallback[] memory callbacks = new RecipientCallback[](2);

        BatchCompact memory compact = _createBasicCompact();

        callbacks[0] = RecipientCallback({
            chainId: block.chainid, compact: compact, mandateHash: bytes32(uint256(1)), context: ""
        });
        callbacks[1] = RecipientCallback({
            chainId: block.chainid, compact: compact, mandateHash: bytes32(uint256(2)), context: ""
        });

        vm.expectRevert(ITribunal.InvalidRecipientCallbackLength.selector);
        tribunal.deriveRecipientCallbackHash(callbacks);
    }

    /**
     * @notice Test PriceCurveLib edge case with invalid scaling direction
     * @dev Covers InvalidPriceCurveParameters error path
     */
    function test_InvalidPriceCurveParameters() public {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] =
            Lock({lockTag: bytes12(uint96(1)), token: address(token), amount: 100e18});

        // Create price curve that decreases (< 1e18)
        uint256[] memory priceCurve = new uint256[](5);
        priceCurve[0] = 10; // blockDuration = 10 blocks
        priceCurve[1] = 0; // fillIncrease
        priceCurve[2] = 2; // components length
        priceCurve[3] = BASE_SCALING_FACTOR; // start at 1e18
        priceCurve[4] = BASE_SCALING_FACTOR / 2; // end at 0.5e18 (decreasing)

        // Use a valid target block that's sufficiently in the past
        uint256 targetBlock = block.number > 10 ? block.number - 10 : 1;
        uint256 fillBlock = block.number;

        // Try with exact-in mode (scalingFactor > 1e18) which conflicts with decreasing curve
        vm.expectRevert(PriceCurveLib.InvalidPriceCurveParameters.selector);
        tribunal.deriveAmounts(
            maximumClaimAmounts,
            priceCurve,
            targetBlock,
            fillBlock,
            50e18,
            1 gwei,
            BASE_SCALING_FACTOR + 1 // Exact-in, but curve decreases
        );
    }

    /**
     * @notice Test deriveAmountsFromComponents with zero targetBlock and empty price curve
     * @dev Covers edge case in _calculateCurrentScalingFactor
     */
    function test_DeriveAmountsFromComponents_NoTargetBlock() public view {
        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] =
            Lock({lockTag: bytes12(uint96(1)), token: address(token), amount: 100e18});

        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 50e18,
            recipient: filler,
            applyScaling: true
        });

        uint256[] memory priceCurve = new uint256[](0);

        (uint256[] memory fillAmounts, uint256[] memory claimAmounts) = tribunal.deriveAmountsFromComponents(
            maximumClaimAmounts,
            components,
            priceCurve,
            0, // No target block
            block.number,
            1 gwei,
            BASE_SCALING_FACTOR
        );

        assertEq(fillAmounts.length, 1, "Should have 1 fill amount");
        assertEq(claimAmounts.length, 1, "Should have 1 claim amount");
        assertEq(claimAmounts[0], 100e18, "Claim should be maximum in neutral mode");
    }

    /**
     * @notice Test components with applyScaling = false in exact-out mode
     * @dev Covers line 1434 in _calculateFillAmounts
     */
    function test_FillAmounts_NoScalingApplied() public view {
        Lock[] memory maximumClaimAmounts = new Lock[](2);
        maximumClaimAmounts[0] =
            Lock({lockTag: bytes12(uint96(1)), token: address(token), amount: 100e18});
        maximumClaimAmounts[1] =
            Lock({lockTag: bytes12(uint96(2)), token: address(token), amount: 200e18});

        FillComponent[] memory components = new FillComponent[](2);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 50e18,
            recipient: filler,
            applyScaling: false // No scaling
        });
        components[1] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 75e18,
            recipient: filler,
            applyScaling: false // No scaling
        });

        uint256[] memory priceCurve = new uint256[](0);

        (uint256[] memory fillAmounts,) = tribunal.deriveAmountsFromComponents(
            maximumClaimAmounts,
            components,
            priceCurve,
            0,
            block.number,
            1 gwei,
            BASE_SCALING_FACTOR - 1 // Exact-out mode
        );

        // With no scaling applied, fill amounts should equal minimum amounts
        assertEq(fillAmounts[0], 50e18, "First fill should be minimum (no scaling)");
        assertEq(fillAmounts[1], 75e18, "Second fill should be minimum (no scaling)");
    }

    /**
     * @notice Test reentrancy guard status reading during protected call
     * @dev Verifies the reentrancy guard status can be read during callback
     */
    function test_ReentrancyGuardStatus_DuringCallback() public {
        // First, cancel a compact to set its disposition
        BatchCompact memory compact = _createBasicCompact();

        FillParameters[] memory fills = new FillParameters[](0);
        Mandate memory mandate = Mandate({adjuster: adjuster, fills: fills});
        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);

        // Cancel the compact (sets disposition)
        vm.prank(sponsor);
        tribunal.cancel(compact, mandateHash);

        // Deploy a checker that will verify reentrancy status during dispatch
        ReentrancyStatusChecker checker = new ReentrancyStatusChecker(address(tribunal));

        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: block.chainid, target: address(checker), value: 0, context: ""
        });

        // Dispatch - the checker will read reentrancy status during the callback
        vm.prank(address(this));
        tribunal.dispatch(compact, mandateHash, dispatchParams);

        // Verify the checker recorded that the status was set to our address
        assertEq(
            checker.recordedStatus(), address(this), "Should record caller address during callback"
        );
    }

    /**
     * @notice Test reentrancy guard revert when attempting to reenter
     * @dev Covers lines 107-108 by triggering the actual reentrancy guard revert
     */
    function test_ReentrancyGuard_Revert() public {
        // First, cancel a compact to set its disposition
        BatchCompact memory compact = _createBasicCompact();

        FillParameters[] memory fills = new FillParameters[](0);
        Mandate memory mandate = Mandate({adjuster: adjuster, fills: fills});
        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);

        // Cancel the compact (sets disposition)
        vm.prank(sponsor);
        tribunal.cancel(compact, mandateHash);

        // Deploy a reentrant callback that tries to call another protected function
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(tribunal), mandateHash);

        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: block.chainid, target: address(attacker), value: 0, context: ""
        });

        // Dispatch - the attacker will try to reenter via cancel()
        // This should trigger the ReentrancyGuard() revert on lines 107-108
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuard()"));
        tribunal.dispatch(compact, mandateHash, dispatchParams);
    }

    /**
     * @notice Test Arbitrum block number path
     * @dev Covers line 16 by mocking IArbSys precompile and performing a fill on Arbitrum
     */
    function test_ArbitrumBlockNumber() public {
        // Mock the IArbSys precompile
        address arbSysAddress = address(0x0000000000000000000000000000000000000064);

        // Create mock that returns a specific block number
        vm.mockCall(
            arbSysAddress, abi.encodeWithSignature("arbBlockNumber()"), abi.encode(uint256(12345))
        );

        // Set chain ID to Arbitrum
        vm.chainId(42161);

        // Deploy a new tribunal on "Arbitrum"
        Tribunal arbTribunal = new Tribunal();

        Lock[] memory maximumClaimAmounts = new Lock[](1);
        maximumClaimAmounts[0] =
            Lock({lockTag: bytes12(uint96(1)), token: address(token), amount: 100e18});

        // Call deriveAmounts which internally calls _validateFillBlock -> _getBlockNumberish
        // Use fillBlock = 0 which will use current block from _getBlockNumberish()
        arbTribunal.deriveAmounts(
            maximumClaimAmounts,
            new uint256[](0),
            0, // no target block
            0, // fillBlock = 0 triggers _getBlockNumberish() call
            50e18,
            1 gwei,
            BASE_SCALING_FACTOR
        );

        // If we got here without reverting, the Arbitrum path was successfully executed
        // Reset chain ID
        vm.chainId(31337);
    }

    /**
     * @notice Test deriveAmountsFromComponents with applyScaling components
     * @dev Covers additional branches in _calculateFillAmounts
     */
    function test_DeriveAmountsFromComponents_WithScaling() public view {
        Lock[] memory maximumClaimAmounts = new Lock[](2);
        maximumClaimAmounts[0] =
            Lock({lockTag: bytes12(uint96(1)), token: address(token), amount: 100e18});
        maximumClaimAmounts[1] =
            Lock({lockTag: bytes12(uint96(2)), token: address(token), amount: 200e18});

        FillComponent[] memory components = new FillComponent[](2);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 50e18,
            recipient: filler,
            applyScaling: true // Apply scaling
        });
        components[1] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 75e18,
            recipient: filler,
            applyScaling: false // No scaling
        });

        uint256[] memory priceCurve = new uint256[](0);

        (uint256[] memory fillAmounts, uint256[] memory claimAmounts) = tribunal.deriveAmountsFromComponents(
            maximumClaimAmounts,
            components,
            priceCurve,
            0,
            block.number,
            1 gwei,
            BASE_SCALING_FACTOR // Neutral scaling
        );

        // Verify both components are calculated
        assertEq(fillAmounts.length, 2, "Should have 2 fill amounts");
        assertEq(claimAmounts.length, 2, "Should have 2 claim amounts");
        assertTrue(fillAmounts[0] > 0, "First fill should be positive");
        assertTrue(fillAmounts[1] > 0, "Second fill should be positive");
    }

    // ============ Helper Functions ============

    function _createBasicCompact() internal view returns (BatchCompact memory) {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(uint96(1)), token: address(token), amount: 100e18});

        return BatchCompact({
            arbiter: address(tribunal),
            sponsor: sponsor,
            nonce: 1,
            expires: block.timestamp + 1 hours,
            commitments: commitments
        });
    }

    function _createBasicMandate() internal view returns (FillParameters memory) {
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 50e18,
            recipient: filler,
            applyScaling: false
        });

        return FillParameters({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: block.timestamp + 1 hours,
            components: components,
            baselinePriorityFee: 1 gwei,
            scalingFactor: BASE_SCALING_FACTOR,
            priceCurve: new uint256[](0),
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(0)
        });
    }

    function _createBasicAdjustment() internal view returns (Adjustment memory) {
        return Adjustment({
            adjuster: adjuster,
            targetBlock: block.number,
            fillIndex: 0,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(uint256(uint160(filler))),
            adjustmentAuthorization: ""
        });
    }
}

/**
 * @notice Helper contract to check reentrancy guard status during a callback
 */
contract ReentrancyStatusChecker {
    Tribunal public tribunal;
    address public recordedStatus;

    constructor(address _tribunal) {
        tribunal = Tribunal(payable(_tribunal));
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
    ) external returns (bytes4) {
        // Check the reentrancy guard status during the callback
        recordedStatus = tribunal.reentrancyGuardStatus();
        return this.dispatchCallback.selector;
    }
}

/**
 * @notice Helper contract that attempts to reenter a protected function
 */
contract ReentrancyAttacker {
    Tribunal public tribunal;
    bytes32 public mandateHash;

    constructor(address _tribunal, bytes32 _mandateHash) {
        tribunal = Tribunal(payable(_tribunal));
        mandateHash = _mandateHash;
    }

    function dispatchCallback(
        uint256,
        BatchCompact calldata compact,
        bytes32,
        bytes32,
        bytes32,
        uint256,
        uint256[] calldata,
        bytes calldata
    ) external returns (bytes4) {
        // Attempt to reenter by calling cancel (another nonReentrant function)
        // Use the compact passed in via calldata
        tribunal.cancel(compact, mandateHash);
        return this.dispatchCallback.selector;
    }
}
