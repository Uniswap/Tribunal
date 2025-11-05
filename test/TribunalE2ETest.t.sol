// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {TheCompact} from "../lib/the-compact/src/TheCompact.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {DeployTheCompact} from "./helpers/DeployTheCompact.sol";
import {BatchCompact, Lock, LOCK_TYPEHASH} from "../lib/the-compact/src/types/EIP712Types.sol";
import {
    Mandate,
    FillParameters,
    FillComponent,
    RecipientCallback,
    Adjustment,
    FillRecipient
} from "../src/types/TribunalStructs.sol";
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
        Tribunal(tribunal).settleOrRegister(sourceClaimHash, compact, mandateHash, recipient, "");
    }
}

contract TribunalE2ETest is DeployTheCompact {
    // Storage for addresses - these survive between tests
    address[] public contractAddresses; // Will store all contract addresses
    uint256[] public snapshots; // Will store snapshot IDs
    uint96[] public allocatorIds; // Will store allocator IDs
    bytes12[] public lockTags; // Will store lock tags

    // Indices for contractAddresses array
    uint256 constant COMPACT_ADDR = 0;
    uint256 constant TRIBUNAL_CHAIN1_ADDR = 1;
    uint256 constant TOKEN_CHAIN1_ADDR = 2;
    uint256 constant TRIBUNAL_CHAIN2_ADDR = 3;
    uint256 constant BRIDGED_TOKEN_CHAIN2_ADDR = 4;
    uint256 constant RECIPIENT_CALLBACK_ADDR = 5;
    uint256 constant BRIDGE_ADDR = 6;

    // Test accounts
    address public sponsor;
    uint256 public sponsorKey;
    address public adjuster;
    uint256 public adjusterKey;
    address public filler;
    address public recipient;
    address public allocator;
    uint256 public allocatorKey;

    // Chain IDs
    uint256 constant CHAIN_1 = 1;
    uint256 constant CHAIN_2 = 137; // Polygon for example

    // Test constants
    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant DEPOSIT_AMOUNT = 100 ether;
    uint256 constant FILL_AMOUNT = 50 ether;

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

        // Take a snapshot of initial state
        uint256 initialState = vm.snapshot();

        // Deploy on Chain 1
        vm.chainId(CHAIN_1);
        TheCompact theCompactChain1 = deployTheCompact();
        Tribunal tribunalChain1Temp = new Tribunal{salt: 0}();
        MockERC20 tokenChain1Temp = new MockERC20();

        // Transfer tokens to sponsor (MockERC20 mints to deployer)
        vm.prank(address(this));
        tokenChain1Temp.transfer(sponsor, INITIAL_BALANCE);

        // Register allocator on Chain 1
        vm.prank(allocator);
        uint96 allocatorIdChain1Temp = theCompactChain1.__registerAllocator(allocator, "");

        // Construct lock tag for Chain 1: scope (2 bytes) + resetPeriod (4 bytes) + allocatorId (6 bytes) = 12 bytes
        // Using scope 0, resetPeriod 0, and the allocatorId we just registered
        bytes12 lockTagChain1Temp = bytes12(uint96(allocatorIdChain1Temp));

        // Store Chain 1 addresses before reverting (as raw addresses, not contract types)
        address theCompactChain1Addr = address(theCompactChain1);
        address tribunalChain1Addr = address(tribunalChain1Temp);
        address tokenChain1Addr = address(tokenChain1Temp);

        // Take snapshot of chain 1
        uint256 chain1SnapshotId = vm.snapshot();
        vm.revertTo(initialState);

        // Deploy on Chain 2
        vm.chainId(CHAIN_2);

        TheCompact theCompactChain2 = deployTheCompact();
        Tribunal tribunalChain2Temp = new Tribunal{salt: 0}();
        BridgedToken bridgedTokenChain2Temp = new BridgedToken{salt: 0}();
        TestRecipientCallback recipientCallbackTemp = new TestRecipientCallback{salt: 0}();
        MockBridge bridgeTemp = new MockBridge{
            salt: 0
        }(payable(address(tribunalChain2Temp)), address(bridgedTokenChain2Temp));

        // Grant bridge role to the bridge and to this test contract (for setup)
        bridgedTokenChain2Temp.grantBridgeRole(address(bridgeTemp));
        bridgedTokenChain2Temp.grantBridgeRole(address(this));

        // Give filler some tokens on chain 2
        bridgedTokenChain2Temp.bridgeMint(filler, INITIAL_BALANCE);

        // Register allocator on Chain 2 (might get different ID since it's a separate deployment)
        vm.prank(allocator);
        uint96 allocatorIdChain2Temp = theCompactChain2.__registerAllocator(allocator, "");

        // Construct lock tag for Chain 2
        bytes12 lockTagChain2Temp = bytes12(uint96(allocatorIdChain2Temp));

        require(
            address(theCompactChain2) == theCompactChain1Addr,
            "deployment address for The Compact differs across chains"
        );

        // Store Chain 2 addresses before taking snapshot (as raw addresses)
        address tribunalChain2Addr = address(tribunalChain2Temp);
        address bridgedTokenChain2Addr = address(bridgedTokenChain2Temp);
        address recipientCallbackAddr = address(recipientCallbackTemp);
        address bridgeAddr = address(bridgeTemp);

        // Take snapshot of chain 2
        uint256 chain2SnapshotId = vm.snapshot();

        // Store all addresses and data in storage arrays
        contractAddresses = new address[](7);
        contractAddresses[COMPACT_ADDR] = theCompactChain1Addr;
        contractAddresses[TRIBUNAL_CHAIN1_ADDR] = tribunalChain1Addr;
        contractAddresses[TOKEN_CHAIN1_ADDR] = tokenChain1Addr;
        contractAddresses[TRIBUNAL_CHAIN2_ADDR] = tribunalChain2Addr;
        contractAddresses[BRIDGED_TOKEN_CHAIN2_ADDR] = bridgedTokenChain2Addr;
        contractAddresses[RECIPIENT_CALLBACK_ADDR] = recipientCallbackAddr;
        contractAddresses[BRIDGE_ADDR] = bridgeAddr;

        snapshots = new uint256[](2);
        snapshots[0] = chain1SnapshotId;
        snapshots[1] = chain2SnapshotId;

        allocatorIds = new uint96[](2);
        allocatorIds[0] = allocatorIdChain1Temp;
        allocatorIds[1] = allocatorIdChain2Temp;

        lockTags = new bytes12[](2);
        lockTags[0] = lockTagChain1Temp;
        lockTags[1] = lockTagChain2Temp;
    }

    function switchToChain1(uint256 chain1Snapshot, uint256 chain2Snapshot)
        internal
        returns (uint256, uint256)
    {
        // Save current chain2 state before switching
        if (block.chainid == CHAIN_2) {
            chain2Snapshot = vm.snapshot();
        }
        vm.chainId(CHAIN_1);
        vm.revertTo(chain1Snapshot);
        return (chain1Snapshot, chain2Snapshot);
    }

    function switchToChain2(uint256 chain1Snapshot, uint256 chain2Snapshot)
        internal
        returns (uint256, uint256)
    {
        // Save current chain1 state before switching
        if (block.chainid == CHAIN_1) {
            chain1Snapshot = vm.snapshot();
        }
        vm.chainId(CHAIN_2);
        vm.revertTo(chain2Snapshot);
        return (chain1Snapshot, chain2Snapshot);
    }

    function testE2ECrossChainFill() public {
        // Load all addresses and data from storage into memory
        TheCompact theCompact = TheCompact(contractAddresses[COMPACT_ADDR]);
        Tribunal tribunalChain1 = Tribunal(payable(contractAddresses[TRIBUNAL_CHAIN1_ADDR]));
        MockERC20 tokenChain1 = MockERC20(contractAddresses[TOKEN_CHAIN1_ADDR]);
        Tribunal tribunalChain2 = Tribunal(payable(contractAddresses[TRIBUNAL_CHAIN2_ADDR]));
        BridgedToken bridgedTokenChain2 = BridgedToken(contractAddresses[BRIDGED_TOKEN_CHAIN2_ADDR]);
        TestRecipientCallback recipientCallback =
            TestRecipientCallback(contractAddresses[RECIPIENT_CALLBACK_ADDR]);

        uint256 chain1SnapshotId = snapshots[0];
        uint256 chain2SnapshotId = snapshots[1];

        bytes12 lockTagChain1 = lockTags[0];

        // Switch to Chain 1
        (chain1SnapshotId, chain2SnapshotId) = switchToChain1(chain1SnapshotId, chain2SnapshotId);

        // Prepare compact parameters
        Lock[] memory commitments = new Lock[](1);
        commitments[0] =
            Lock({lockTag: lockTagChain1, token: address(tokenChain1), amount: DEPOSIT_AMOUNT});

        BatchCompact memory compact = BatchCompact({
            arbiter: address(0),
            sponsor: sponsor,
            nonce: 1,
            expires: block.timestamp + 1 days,
            commitments: commitments
        });

        // Create fills array (cross-chain fill and same-chain fallback)
        FillParameters[] memory fills = new FillParameters[](2);

        // Cross-chain fill (Chain 2)
        FillComponent[] memory components0 = new FillComponent[](1);
        components0[0] = FillComponent({
            fillToken: address(bridgedTokenChain2),
            minimumFillAmount: FILL_AMOUNT,
            recipient: recipient,
            applyScaling: false
        });

        fills[0] = FillParameters({
            chainId: CHAIN_2,
            tribunal: address(tribunalChain2),
            expires: block.timestamp + 1 hours,
            components: components0,
            baselinePriorityFee: 1 gwei,
            scalingFactor: 1e18, // No scaling
            priceCurve: new uint256[](0),
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

        FillComponent[] memory components1 = new FillComponent[](1);
        components1[0] = FillComponent({
            fillToken: address(tokenChain1),
            minimumFillAmount: FILL_AMOUNT,
            recipient: address(recipientCallback),
            applyScaling: false
        });

        fills[1] = FillParameters({
            chainId: CHAIN_1,
            tribunal: address(tribunalChain1),
            expires: block.timestamp + 2 hours,
            components: components1,
            baselinePriorityFee: 1 gwei,
            scalingFactor: 1e18,
            priceCurve: new uint256[](0),
            recipientCallback: callbacks,
            salt: bytes32(uint256(2))
        });

        // Calculate fill hashes on their respective chains
        bytes32[] memory fillHashes = new bytes32[](2);

        // Get hash for fills[1] on current chain (CHAIN_1)
        fillHashes[1] = tribunalChain1.deriveFillHash(fills[1]);

        // Switch to CHAIN_2 to get hash for fills[0]
        (chain1SnapshotId, chain2SnapshotId) = switchToChain2(chain1SnapshotId, chain2SnapshotId);
        fillHashes[0] = tribunalChain2.deriveFillHash(fills[0]);
        (chain1SnapshotId, chain2SnapshotId) = switchToChain1(chain1SnapshotId, chain2SnapshotId);

        // Calculate mandate hash
        bytes32 mandateHash = keccak256(
            abi.encode(MANDATE_TYPEHASH, adjuster, keccak256(abi.encodePacked(fillHashes)))
        );

        // Sponsor deposits and registers on Chain 1
        vm.startPrank(sponsor);
        tokenChain1.approve(address(theCompact), DEPOSIT_AMOUNT);

        bytes32 claimHash = tribunalChain1.deriveClaimHash(compact, mandateHash);

        // Adjuster signs adjustment for cross-chain fill
        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: block.number,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(uint256(uint160(filler)))
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
        bytes32 domainSeparator = _computeDomainSeparator(CHAIN_2, address(tribunalChain2));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, adjustmentHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adjusterKey, digest);
        bytes memory adjustmentSignature = abi.encodePacked(r, s, v);

        vm.stopPrank();

        bytes32[] memory fillHashesForExecution = new bytes32[](2);
        fillHashesForExecution[1] = tribunalChain1.deriveFillHash(fills[1]);

        // Switch to Chain 2 and execute cross-chain fill
        (chain1SnapshotId, chain2SnapshotId) = switchToChain2(chain1SnapshotId, chain2SnapshotId);

        fillHashesForExecution[0] = tribunalChain2.deriveFillHash(fills[0]);

        // Set up the filler's approval
        vm.startPrank(filler);
        bridgedTokenChain2.approve(address(tribunalChain2), FILL_AMOUNT);

        // Create batch claim for Chain 2
        ITribunal.BatchClaim memory batchClaim =
            ITribunal.BatchClaim({compact: compact, sponsorSignature: "", allocatorSignature: ""});

        // Execute the cross-chain fill
        (bytes32 returnedClaimHash,, uint256[] memory fillAmounts,) = tribunalChain2.fill(
            batchClaim.compact,
            fills[0],
            adjuster,
            adjustment,
            adjustmentSignature,
            fillHashesForExecution,
            bytes32(uint256(uint160(filler))),
            0
        );

        vm.stopPrank();

        // Verify the fill was recorded
        assertEq(tribunalChain2.filled(returnedClaimHash), bytes32(uint256(uint160(filler))));
        assertEq(fillAmounts[0], FILL_AMOUNT);
    }

    function testBridgeAndSettle() public {
        // Load all addresses and data from storage into memory
        BridgedToken bridgedTokenChain2 = BridgedToken(contractAddresses[BRIDGED_TOKEN_CHAIN2_ADDR]);
        MockBridge bridge = MockBridge(contractAddresses[BRIDGE_ADDR]);

        uint256 chain1SnapshotId = snapshots[0];
        uint256 chain2SnapshotId = snapshots[1];

        bytes12 lockTagChain2 = lockTags[1];

        // Setup: Create a compact on Chain 2 that will be settled via bridge
        (chain1SnapshotId, chain2SnapshotId) = switchToChain2(chain1SnapshotId, chain2SnapshotId);

        // Create a simple compact for the target chain
        Lock[] memory targetCommitments = new Lock[](1);
        targetCommitments[0] =
            Lock({lockTag: lockTagChain2, token: address(bridgedTokenChain2), amount: FILL_AMOUNT});

        BatchCompact memory targetCompact = BatchCompact({
            arbiter: address(0),
            sponsor: sponsor,
            nonce: 1, // Use non-zero nonce to avoid on-chain allocation
            expires: block.timestamp + 1 days,
            commitments: targetCommitments
        });

        bytes32 targetMandateHash = bytes32(uint256(123));
        bytes32 sourceClaimHash = bytes32(uint256(456));

        // Execute bridge transaction
        vm.startPrank(address(bridge));

        // Bridge mints tokens and calls settleOrRegister
        uint256 bridgeAmount = FILL_AMOUNT;
        bridge.bridgeTokens(
            sourceClaimHash, targetCompact, targetMandateHash, recipient, bridgeAmount
        );

        vm.stopPrank();

        // Additional verification could be added here based on specific requirements
    }

    function _computeDomainSeparator(uint256 chainId, address tribunal)
        internal
        pure
        returns (bytes32)
    {
        bytes32 DOMAIN_TYPEHASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
        bytes32 NAME_HASH = 0x0e2a7404936dd29a4a3b49dad6c2f86f8e2da9cf7cf60ef9518bb049b4cb9b44;
        bytes32 VERSION_HASH = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, chainId, tribunal));
    }
}
