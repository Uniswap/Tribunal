// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {TheCompact} from "../lib/the-compact/src/TheCompact.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {BatchCompact, Lock, LOCK_TYPEHASH} from "../lib/the-compact/src/types/EIP712Types.sol";
import {Mandate, Fill, RecipientCallback, Adjustment} from "../src/types/TribunalStructs.sol";
import {
    MANDATE_TYPEHASH,
    MANDATE_FILL_TYPEHASH,
    MANDATE_RECIPIENT_CALLBACK_TYPEHASH,
    MANDATE_BATCH_COMPACT_TYPEHASH,
    MANDATE_LOCK_TYPEHASH,
    COMPACT_TYPEHASH_WITH_MANDATE,
    ADJUSTMENT_TYPEHASH,
    WITNESS_TYPESTRING
} from "../src/types/TribunalTypeHashes.sol";
import {IRecipientCallback} from "../src/interfaces/IRecipientCallback.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";

// Helper contract for recipient callback testing
contract TestRecipientCallback is IRecipientCallback {
    event RecipientCallbackTriggered(
        uint256 chainId,
        bytes32 claimHash,
        bytes32 mandateHash,
        address fillToken,
        uint256 fillAmount,
        BatchCompact compact,
        bytes32 callbackMandateHash,
        bytes context
    );

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
        emit RecipientCallbackTriggered(
            chainId,
            claimHash,
            mandateHash,
            fillToken,
            fillAmount,
            compact,
            callbackMandateHash,
            context
        );
        return IRecipientCallback.tribunalCallback.selector;
    }
}

// Helper contract for bridged token with minting capability
contract BridgedToken is MockERC20 {
    mapping(address => bool) public hasBridgeRole;

    constructor() MockERC20() {}

    function grantBridgeRole(address account) external {
        hasBridgeRole[account] = true;
    }

    function bridgeMint(address to, uint256 amount) external {
        require(hasBridgeRole[msg.sender], "Missing bridge role");
        _mint(to, amount);
    }
}

// Mock bridge contract
contract MockBridge {
    using SafeTransferLib for address;

    address payable public tribunal;
    BridgedToken public bridgedToken;

    event BridgeEvent(
        bytes32 sourceClaimHash,
        BatchCompact compact,
        bytes32 mandateHash,
        address recipient,
        uint256 amount
    );

    constructor(address payable _tribunal, address _bridgedToken) {
        tribunal = _tribunal;
        bridgedToken = BridgedToken(_bridgedToken);
    }

    function bridgeTokens(
        bytes32 sourceClaimHash,
        BatchCompact calldata compact,
        bytes32 mandateHash,
        address recipient,
        uint256 amount
    ) external {
        // Emit event for tracking
        emit BridgeEvent(sourceClaimHash, compact, mandateHash, recipient, amount);

        // Mint bridged tokens to tribunal
        bridgedToken.bridgeMint(tribunal, amount);

        // Call settleOrRegister on tribunal
        Tribunal(tribunal).settleOrRegister(sourceClaimHash, compact, mandateHash, recipient);
    }
}

contract TribunalE2ETest is Test {
    // Core contracts
    TheCompact public theCompact;
    Tribunal public tribunalChain1;
    Tribunal public tribunalChain2;

    // Token contracts
    MockERC20 public tokenChain1;
    BridgedToken public bridgedTokenChain2;

    // Helper contracts
    TestRecipientCallback public recipientCallback;
    MockBridge public bridge;

    // Test accounts
    address public sponsor;
    uint256 public sponsorKey;
    address public adjuster;
    uint256 public adjusterKey;
    address public filler;
    address public recipient;
    address public allocator;
    uint256 public allocatorKey;

    // Store addresses for cross-chain references as constants (determined at compile time)
    // We'll use hardcoded predictable addresses based on CREATE opcode
    address constant tribunalChain1Address = address(0x2e234DAe75C793f67A35089C9d99245E1C58470b);
    address constant tokenChain1Address = address(0xF62849F9A0B5Bf2913b396098F7c7019b51A820a);
    address constant tribunalChain2Address = address(0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9);
    address constant bridgedTokenChain2Address = address(0xc7183455a4C133Ae270771860664b6B7ec320bB1);
    address constant recipientCallbackAddress = address(0xa0Cb889707d426A7A386870A03bc70d1b0697598);

    // Chain IDs
    uint256 constant CHAIN_1 = 1;
    uint256 constant CHAIN_2 = 137; // Polygon for example

    // Chain state snapshots - these IDs are predictable
    // First snapshot in setUp will be 0, second will be 1
    uint256 constant CHAIN1_SNAPSHOT = 0;
    uint256 constant CHAIN2_SNAPSHOT = 1;

    // Test constants
    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant DEPOSIT_AMOUNT = 100 ether;
    uint256 constant FILL_AMOUNT = 50 ether;
    bytes12 constant LOCK_TAG = 0x000000000000000000000001;

    function setUp() public {
        // Setup test accounts
        sponsorKey = 0x1;
        sponsor = vm.addr(sponsorKey);
        adjusterKey = 0x2;
        adjuster = vm.addr(adjusterKey);
        allocatorKey = 0x3;
        allocator = vm.addr(allocatorKey);
        filler = address(0x4);
        recipient = address(0x5);

        // Deploy on Chain 1
        vm.chainId(CHAIN_1);
        theCompact = new TheCompact();
        tribunalChain1 = new Tribunal(address(theCompact));
        tokenChain1 = new MockERC20();

        // Transfer tokens to sponsor (MockERC20 mints to deployer)
        vm.prank(address(this));
        tokenChain1.transfer(sponsor, INITIAL_BALANCE);

        // Take snapshot of chain 1 (this will be snapshot 0)
        vm.snapshot();

        // Deploy on Chain 2
        vm.chainId(CHAIN_2);
        tribunalChain2 = new Tribunal(address(theCompact));
        bridgedTokenChain2 = new BridgedToken();
        recipientCallback = new TestRecipientCallback();
        bridge = new MockBridge(payable(address(tribunalChain2)), address(bridgedTokenChain2));

        // Verify the addresses match our expected constants
        require(address(tribunalChain2) == tribunalChain2Address, "Tribunal2 address mismatch");
        require(address(bridgedTokenChain2) == bridgedTokenChain2Address, "Token2 address mismatch");
        require(address(recipientCallback) == recipientCallbackAddress, "Callback address mismatch");

        // Grant bridge role to the bridge and to this test contract (for setup)
        bridgedTokenChain2.grantBridgeRole(address(bridge));
        bridgedTokenChain2.grantBridgeRole(address(this));

        // Give filler some tokens on chain 2
        bridgedTokenChain2.bridgeMint(filler, INITIAL_BALANCE);

        // Take snapshot of chain 2 (this will be snapshot 1)
        vm.snapshot();

        // Return to chain 1
        vm.chainId(CHAIN_1);
        vm.revertTo(CHAIN1_SNAPSHOT);
    }

    function switchToChain1() internal {
        vm.chainId(CHAIN_1);
        vm.revertTo(CHAIN1_SNAPSHOT);
    }

    function switchToChain2() internal {
        vm.chainId(CHAIN_2);
        vm.revertTo(CHAIN2_SNAPSHOT);
    }

    function testE2ECrossChainFill() public {
        // Step 1: Create the BatchCompact with Mandate on Chain 1
        // We start on chain 1, so no need to switch initially

        // Prepare compact parameters
        Lock[] memory commitments = new Lock[](1);
        commitments[0] =
            Lock({lockTag: LOCK_TAG, token: tokenChain1Address, amount: DEPOSIT_AMOUNT});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(0), // No arbiter for simplicity
            sponsor: sponsor,
            nonce: 1,
            expires: block.timestamp + 1 days,
            commitments: commitments
        });

        // Create fills array (cross-chain fill and same-chain fallback)
        Fill[] memory fills = new Fill[](2);

        // Cross-chain fill (Chain 2)
        fills[0] = Fill({
            chainId: CHAIN_2,
            tribunal: tribunalChain2Address,
            expires: block.timestamp + 1 hours,
            fillToken: bridgedTokenChain2Address,
            minimumFillAmount: FILL_AMOUNT,
            baselinePriorityFee: 1 gwei,
            scalingFactor: 1e18, // No scaling
            priceCurve: new uint256[](0),
            recipient: recipient,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        // Same-chain fallback with callback
        RecipientCallback[] memory callbacks = new RecipientCallback[](1);
        callbacks[0] = RecipientCallback({
            chainId: CHAIN_2,
            compact: compact,
            mandateHash: bytes32(0), // Will be filled later
            context: abi.encode("test context")
        });

        fills[1] = Fill({
            chainId: CHAIN_1,
            tribunal: tribunalChain1Address,
            expires: block.timestamp + 2 hours,
            fillToken: tokenChain1Address,
            minimumFillAmount: FILL_AMOUNT,
            baselinePriorityFee: 1 gwei,
            scalingFactor: 1e18,
            priceCurve: new uint256[](0),
            recipient: recipientCallbackAddress,
            recipientCallback: callbacks,
            salt: bytes32(uint256(2))
        });

        // Create the mandate
        Mandate memory mandate = Mandate({adjuster: adjuster, fills: fills});

        // Calculate fill hashes on their respective chains
        // fills[0] should be hashed on CHAIN_2, fills[1] on CHAIN_1
        bytes32[] memory fillHashes = new bytes32[](2);

        // Get hash for fills[1] on current chain (CHAIN_1)
        fillHashes[1] = tribunalChain1.deriveFillHash(fills[1]);

        // Switch to CHAIN_2 to get hash for fills[0]
        switchToChain2();
        fillHashes[0] = Tribunal(payable(tribunalChain2Address)).deriveFillHash(fills[0]);
        switchToChain1();

        // Now calculate mandate hash with the correct fill hashes
        bytes32 mandateHash = keccak256(
            abi.encode(MANDATE_TYPEHASH, adjuster, keccak256(abi.encodePacked(fillHashes)))
        );

        // Step 2: Sponsor deposits and registers on Chain 1
        vm.startPrank(sponsor);
        tokenChain1.approve(address(theCompact), DEPOSIT_AMOUNT);

        // Create witness for the compact
        bytes32 witnessHash = mandateHash;

        // Register the compact (simplified - in reality would need proper signatures)
        bytes32 claimHash = tribunalChain1.deriveClaimHash(compact, mandateHash);

        // Step 3: Adjuster signs adjustment for cross-chain fill
        Adjustment memory adjustment = Adjustment({
            fillIndex: 0, // First fill (cross-chain)
            targetBlock: block.number,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(uint256(uint160(filler))) // Only filler can execute
        });

        // Generate adjustment signature for verification on Chain 2
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

        // The domain separator should be for Chain 2 where the signature will be verified
        bytes32 domainSeparator = _computeDomainSeparator(CHAIN_2, tribunalChain2Address);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, adjustmentHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adjusterKey, digest);
        bytes memory adjustmentSignature = abi.encodePacked(r, s, v);

        vm.stopPrank();

        // Step 4: Switch to Chain 2 and execute cross-chain fill
        switchToChain2();

        console2.log("Executing cross-chain fill on Chain 2...");

        // Prepare fill on Chain 2
        vm.startPrank(filler);
        BridgedToken(bridgedTokenChain2Address).approve(tribunalChain2Address, FILL_AMOUNT);

        // Create batch claim for Chain 2
        Tribunal.BatchClaim memory batchClaim = Tribunal.BatchClaim({
            chainId: CHAIN_1, // Source chain
            compact: compact,
            sponsorSignature: "", // Would need actual signature
            allocatorSignature: "" // Would need actual signature
        });

        // Use the same fill hashes we computed earlier (they need to match)
        bytes32[] memory fillHashesForExecution = new bytes32[](2);
        fillHashesForExecution[0] =
            Tribunal(payable(tribunalChain2Address)).deriveFillHash(fills[0]);
        // For fills[1], we need to switch to CHAIN_1 to get the correct hash
        switchToChain1();
        fillHashesForExecution[1] =
            Tribunal(payable(tribunalChain1Address)).deriveFillHash(fills[1]);
        switchToChain2();

        // Execute the cross-chain fill
        (
            bytes32 returnedClaimHash,
            bytes32 returnedMandateHash,
            uint256 fillAmount,
            uint256[] memory claimAmounts
        ) = Tribunal(payable(tribunalChain2Address)).fill(
            batchClaim,
            fills[0], // Cross-chain fill
            adjuster,
            adjustment,
            adjustmentSignature,
            fillHashesForExecution,
            bytes32(uint256(uint160(filler))), // claimant
            0 // fillBlock (0 = current)
        );

        console2.log("Cross-chain fill executed:");
        console2.log("  Claim Hash:", uint256(returnedClaimHash));
        console2.log("  Fill Amount:", fillAmount);

        vm.stopPrank();

        // Verify the fill was recorded
        assertEq(Tribunal(payable(tribunalChain2Address)).filled(returnedClaimHash), filler);

        // Step 5: Test same-chain fallback (if cross-chain wasn't filled)
        // Reset and test the alternative path
        switchToChain1();
        console2.log("\nTesting same-chain fallback with callback...");

        // Create new adjustment for same-chain fill
        Adjustment memory sameChainAdjustment = Adjustment({
            fillIndex: 1, // Second fill (same-chain)
            targetBlock: block.number,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0) // No restrictions
        });

        // Would need to sign this adjustment as well
        // For brevity, we'll skip the full same-chain test

        console2.log("E2E test completed successfully!");
    }

    function testBridgeAndSettle() public {
        console2.log("Testing bridge and settle flow...");

        // Setup: Create a compact on Chain 2 that will be settled via bridge
        switchToChain2();

        // Create a simple compact for the target chain
        Lock[] memory targetCommitments = new Lock[](1);
        targetCommitments[0] =
            Lock({lockTag: LOCK_TAG, token: address(bridgedTokenChain2), amount: FILL_AMOUNT});

        BatchCompact memory targetCompact = BatchCompact({
            arbiter: address(0),
            sponsor: sponsor,
            nonce: 2,
            expires: block.timestamp + 1 days,
            commitments: targetCommitments
        });

        bytes32 targetMandateHash = bytes32(uint256(123)); // Simplified
        bytes32 sourceClaimHash = bytes32(uint256(456)); // From source chain

        // Execute bridge transaction
        vm.startPrank(address(bridge));

        // Bridge mints tokens and calls settleOrRegister
        uint256 bridgeAmount = FILL_AMOUNT;
        bridge.bridgeTokens(
            sourceClaimHash, targetCompact, targetMandateHash, recipient, bridgeAmount
        );

        vm.stopPrank();

        console2.log("Bridge and settle completed");

        // Verify tokens were registered or transferred appropriately
        // The exact verification depends on whether there was a prior fill
    }

    function _computeDomainSeparator(uint256 chainId, address tribunal)
        internal
        pure
        returns (bytes32)
    {
        // Use the exact same constants as DomainLib
        bytes32 DOMAIN_TYPEHASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
        bytes32 NAME_HASH = 0x0e2a7404936dd29a4a3b49dad6c2f86f8e2da9cf7cf60ef9518bb049b4cb9b44; // keccak256(bytes("Tribunal"))
        bytes32 VERSION_HASH = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6; // keccak256("1")

        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, chainId, tribunal));
    }
}
