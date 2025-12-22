// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {DeployTheCompact} from "./helpers/DeployTheCompact.sol";
import {TheCompact} from "the-compact/src/TheCompact.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockDispatchTarget} from "./mocks/MockDispatchTarget.sol";
import {FillerContract} from "./mocks/FillerContract.sol";
import {ITribunalCallback} from "../src/interfaces/ITribunalCallback.sol";
import {
    Mandate,
    FillParameters,
    FillComponent,
    Adjustment,
    RecipientCallback,
    DispatchParameters,
    BatchClaim,
    FillRecipient,
    FillRequirement
} from "../src/types/TribunalStructs.sol";
import {BatchCompact, Lock, LOCK_TYPEHASH} from "the-compact/src/types/EIP712Types.sol";
import {
    COMPACT_TYPEHASH_WITH_MANDATE,
    CONDITIONAL_MANDATE_TYPEHASH,
    CONDITIONAL_CLAIM_TYPEHASH,
    MANDATE_TYPEHASH,
    ADJUSTMENT_TYPEHASH
} from "../src/types/TribunalTypeHashes.sol";

contract TribunalConditionalTest is DeployTheCompact, ITribunalCallback {
    using FixedPointMathLib for uint256;

    Tribunal public tribunal;
    TheCompact public compactContract;
    MockERC20 public token;
    MockDispatchTarget public dispatchTarget;
    FillerContract public filler;

    address sponsor;
    uint256 sponsorPrivateKey;
    address adjuster;
    uint256 adjusterPrivateKey;

    uint256[] public emptyPriceCurve;

    event Fill(
        address indexed sponsor,
        bytes32 indexed claimant,
        bytes32 claimHash,
        FillRecipient[] fillRecipients,
        uint256[] claimAmounts,
        uint256 targetBlock
    );

    event Dispatch(
        address indexed dispatchTarget,
        uint256 indexed chainId,
        bytes32 indexed claimant,
        bytes32 claimHash
    );

    function setUp() public {
        compactContract = deployTheCompact();
        tribunal = new Tribunal();
        token = new MockERC20();
        dispatchTarget = new MockDispatchTarget();
        filler = new FillerContract();

        (sponsor, sponsorPrivateKey) = makeAddrAndKey("sponsor");
        (adjuster, adjusterPrivateKey) = makeAddrAndKey("adjuster");

        emptyPriceCurve = new uint256[](0);

        // Fund accounts
        vm.deal(sponsor, 100 ether);
        vm.deal(address(filler), 100 ether);
        token.transfer(sponsor, 1000e18);
        token.transfer(address(filler), 1000e18);

        // Approvals
        vm.prank(sponsor);
        token.approve(address(compactContract), type(uint256).max);

        vm.prank(address(filler));
        token.approve(address(tribunal), type(uint256).max);
    }

    // Implement ITribunalCallback
    function tribunalCallback(
        bytes32,
        Lock[] calldata,
        uint256[] calldata,
        FillRequirement[] calldata
    ) external {}

    function testFillConditional_Success() public {
        // 1. Setup a regular fill
        (
            BatchCompact memory compact,
            FillParameters memory mandate,
            Adjustment memory adjustment,
            bytes32[] memory fillHashes,
            // mandateHash unused
        ) = _createFillScenario();

        // 2. Fill the original claim
        bytes32 claimant = bytes32(uint256(uint160(address(filler))));
        vm.prank(address(filler));
        (bytes32 originalClaimHash,,,) =
            tribunal.fill(compact, mandate, adjustment, fillHashes, claimant, block.number);

        // 3. Prepare tag along
        bytes32 conditionalClaimant = bytes32(uint256(uint160(address(this))));

        // 4. Execute fillConditional
        vm.prank(address(filler)); // Must be original filler
        (bytes32 claimHash, bytes32 conditionalMandateHash, uint256[] memory claimAmounts) =
            tribunal.fillConditional(compact, originalClaimHash, conditionalClaimant);

        // 5. Verify results
        assertTrue(claimHash == _deriveConditionalClaimHash(compact, originalClaimHash));
        assertTrue(
            conditionalMandateHash
                == keccak256(abi.encode(CONDITIONAL_MANDATE_TYPEHASH, originalClaimHash))
        );

        // Verify claim amounts (should match original if scaling is neutral, or scaled)
        // In _createFillScenario, scaling factor is 1e18 (neutral), so claim amounts should match commitment amounts
        assertEq(claimAmounts.length, compact.commitments.length);
        assertEq(claimAmounts[0], compact.commitments[0].amount);

        // Verify disposition
        assertEq(tribunal.filled(claimHash), conditionalClaimant);
    }

    function testFillConditional_Cancelled(address anyCaller) public {
        // 1. Setup a regular fill scenario
        (
            BatchCompact memory compact,
            /* mandate */,
            /* adjustment */,
            /* fillHashes */,
            bytes32 mandateHash
        ) = _createFillScenario();

        // 2. Cancel the original claim
        vm.prank(sponsor);
        bytes32 cancelledClaimHash = tribunal.cancel(compact, mandateHash);

        // 3. Execute fillConditional (can be anyone)
        bytes32 conditionalClaimant = bytes32(uint256(uint160(address(this))));

        vm.prank(anyCaller); // Random caller
        (bytes32 claimHash,, uint256[] memory claimAmounts) =
            tribunal.fillConditional(compact, cancelledClaimHash, conditionalClaimant);

        // 4. Verify amounts are zero
        assertEq(claimAmounts[0], 0);

        // Verify disposition
        assertEq(tribunal.filled(claimHash), conditionalClaimant);
    }

    function testFillConditional_WithScalingReduction() public {
        // 1. Setup scenario with exact-out parameters (scalingFactor < 1e18)

        // Create commitment
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(token), amount: 100e18});

        // Create compact
        BatchCompact memory compact = BatchCompact({
            arbiter: address(tribunal),
            sponsor: sponsor,
            nonce: uint256(keccak256("nonce")),
            expires: block.timestamp + 1000,
            commitments: commitments
        });

        // Create mandate with scalingFactor < 1e18
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 100e18,
            recipient: sponsor,
            applyScaling: false
        });

        FillParameters memory mandate = FillParameters({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: block.timestamp + 1000,
            components: components,
            baselinePriorityFee: 0,
            scalingFactor: 0.9e18, // < 1e18 triggers exact-out logic
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(0)
        });

        // Create adjustment
        Adjustment memory adjustment = Adjustment({
            adjuster: address(0),
            fillIndex: 0,
            targetBlock: block.number,
            supplementalPriceCurve: emptyPriceCurve,
            validityConditions: bytes32(uint256(uint160(address(filler)))),
            adjustmentAuthorization: ""
        });

        // Derive hashes
        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(mandate);

        bytes32 mandateHash = keccak256(
            abi.encode(MANDATE_TYPEHASH, adjuster, keccak256(abi.encodePacked(fillHashes)))
        );

        // Sign adjustment
        bytes32 claimHash = _deriveClaimHash(compact, mandateHash);
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
                keccak256(bytes("Tribunal")),
                keccak256(bytes("1")),
                block.chainid,
                address(tribunal)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, adjustmentHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adjusterPrivateKey, digest);
        adjustment.adjuster = adjuster;
        adjustment.adjustmentAuthorization = abi.encodePacked(r, s, v);

        // 2. Fill original claim with priority fee to trigger scaling
        // scalingFactor = 0.9e18
        // priorityFee = 1 wei
        // multiplier = 1e18 - (0.1e18 * 1) = 0.9e18

        vm.txGasPrice(block.basefee + 1);

        bytes32 claimant = bytes32(uint256(uint160(address(filler))));
        vm.prank(address(filler));
        (
            bytes32 originalClaimHash,
            ,
            /* uint256[] memory originalFillAmounts */,
            uint256[] memory originalClaimAmounts
        ) = tribunal.fill(compact, mandate, adjustment, fillHashes, claimant, block.number);

        // Check that original claim was scaled
        assertEq(originalClaimAmounts[0], components[0].minimumFillAmount * 9 / 10); // 100e18 * 0.9
        assertEq(tribunal.claimReductionScalingFactor(originalClaimHash), 0.9e18);

        // 3. Execute fillConditional
        bytes32 conditionalClaimant = bytes32(uint256(uint160(address(this))));
        vm.prank(address(filler));
        (bytes32 conditionalClaimHash,, uint256[] memory conditionalClaimAmounts) =
            tribunal.fillConditional(compact, originalClaimHash, conditionalClaimant);

        // 4. Verify tag along results
        // Should also be scaled by the stored factor (0.9e18)
        assertEq(conditionalClaimAmounts[0], compact.commitments[0].amount * 9 / 10);

        // Verify disposition
        assertEq(tribunal.filled(conditionalClaimHash), conditionalClaimant);

        // Verify scaling factor is stored for tag along claim as well
        assertEq(tribunal.claimReductionScalingFactor(conditionalClaimHash), 0.9e18);
    }

    function testFillConditional_Revert_NotOriginalFiller() public {
        // 1. Setup and fill original
        (
            BatchCompact memory compact,
            FillParameters memory mandate,
            Adjustment memory adjustment,
            bytes32[] memory fillHashes,
            // mandateHash unused
        ) = _createFillScenario();

        bytes32 claimant = bytes32(uint256(uint160(address(filler))));
        vm.prank(address(filler));
        (bytes32 originalClaimHash,,,) =
            tribunal.fill(compact, mandate, adjustment, fillHashes, claimant, block.number);

        // 2. Try to fill tag along as someone else
        bytes32 conditionalClaimant = bytes32(uint256(uint160(address(this))));
        vm.prank(address(0xBad));

        // Should revert with ValidityConditionsNotMet (encoded as 0x6770cd44 in assembly)
        vm.expectRevert(bytes4(0x6770cd44));
        tribunal.fillConditional(compact, originalClaimHash, conditionalClaimant);
    }

    function testFillConditional_Revert_AlreadyFilled() public {
        // 1. Setup and fill original
        (
            BatchCompact memory compact,
            FillParameters memory mandate,
            Adjustment memory adjustment,
            bytes32[] memory fillHashes,
            // mandateHash unused
        ) = _createFillScenario();

        bytes32 claimant = bytes32(uint256(uint160(address(filler))));
        vm.prank(address(filler));
        (bytes32 originalClaimHash,,,) =
            tribunal.fill(compact, mandate, adjustment, fillHashes, claimant, block.number);

        // 2. Fill tag along first time
        bytes32 conditionalClaimant = bytes32(uint256(uint160(address(this))));
        vm.prank(address(filler));
        tribunal.fillConditional(compact, originalClaimHash, conditionalClaimant);

        // 3. Try to fill tag along again
        vm.prank(address(filler));
        vm.expectRevert(ITribunal.AlreadyFilled.selector);
        tribunal.fillConditional(compact, originalClaimHash, conditionalClaimant);
    }

    function testFillAndDispatchConditional() public {
        // 1. Setup and fill original
        (
            BatchCompact memory compact,
            FillParameters memory mandate,
            Adjustment memory adjustment,
            bytes32[] memory fillHashes,
            // mandateHash unused
        ) = _createFillScenario();

        bytes32 claimant = bytes32(uint256(uint160(address(filler))));
        vm.prank(address(filler));
        (bytes32 originalClaimHash,,,) =
            tribunal.fill(compact, mandate, adjustment, fillHashes, claimant, block.number);

        // 2. Prepare dispatch params
        DispatchParameters memory dispatchParams = DispatchParameters({
            target: address(dispatchTarget), chainId: block.chainid, value: 0, context: ""
        });

        // 3. Execute fillAndDispatchConditional
        bytes32 conditionalClaimant = bytes32(uint256(uint160(address(this))));
        vm.prank(address(filler));

        vm.expectEmit(true, true, true, true);
        emit Dispatch(
            address(dispatchTarget),
            block.chainid,
            conditionalClaimant,
            _deriveConditionalClaimHash(compact, originalClaimHash)
        );

        tribunal.fillAndDispatchConditional(
            compact, originalClaimHash, conditionalClaimant, dispatchParams
        );

        // Verify dispatch target received callback
        assertEq(
            dispatchTarget.receivedClaimHash(),
            _deriveConditionalClaimHash(compact, originalClaimHash)
        );
    }

    // Helper to derive tag along claim hash for assertions
    function _deriveConditionalClaimHash(BatchCompact memory compact, bytes32 conditionalClaimHash)
        internal
        pure
        returns (bytes32)
    {
        bytes32 mandateHash =
            keccak256(abi.encode(CONDITIONAL_MANDATE_TYPEHASH, conditionalClaimHash));

        bytes32[] memory commitmentsHashes = new bytes32[](compact.commitments.length);
        for (uint256 i = 0; i < compact.commitments.length; i++) {
            commitmentsHashes[i] = keccak256(
                abi.encode(
                    LOCK_TYPEHASH,
                    compact.commitments[i].lockTag,
                    compact.commitments[i].token,
                    compact.commitments[i].amount
                )
            );
        }
        bytes32 commitmentsHash = keccak256(abi.encodePacked(commitmentsHashes));

        return keccak256(
            abi.encode(
                CONDITIONAL_CLAIM_TYPEHASH,
                compact.arbiter,
                compact.sponsor,
                compact.nonce,
                compact.expires,
                commitmentsHash,
                mandateHash
            )
        );
    }

    function _createFillScenario()
        internal
        view
        returns (
            BatchCompact memory compact,
            FillParameters memory mandate,
            Adjustment memory adjustment,
            bytes32[] memory fillHashes,
            bytes32 mandateHash
        )
    {
        // Create commitment
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(token), amount: 100e18});

        // Create compact
        compact = BatchCompact({
            arbiter: address(tribunal),
            sponsor: sponsor,
            nonce: uint256(keccak256("nonce")),
            expires: block.timestamp + 1000,
            commitments: commitments
        });

        // Create mandate
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 100e18,
            recipient: sponsor,
            applyScaling: false
        });

        mandate = FillParameters({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: block.timestamp + 1000,
            components: components,
            baselinePriorityFee: 0,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(0)
        });

        // Create adjustment
        adjustment = Adjustment({
            adjuster: address(0),
            fillIndex: 0,
            targetBlock: block.number,
            supplementalPriceCurve: emptyPriceCurve,
            validityConditions: bytes32(uint256(uint160(address(filler)))),
            adjustmentAuthorization: ""
        });

        // Derive hashes
        fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(mandate);

        mandateHash = keccak256(
            abi.encode(MANDATE_TYPEHASH, adjuster, keccak256(abi.encodePacked(fillHashes)))
        );

        // Sign adjustment
        bytes32 claimHash = _deriveClaimHash(compact, mandateHash);
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
                keccak256(bytes("Tribunal")),
                keccak256(bytes("1")),
                block.chainid,
                address(tribunal)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, adjustmentHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adjusterPrivateKey, digest);
        adjustment.adjuster = adjuster;
        adjustment.adjustmentAuthorization = abi.encodePacked(r, s, v);
    }

    function _deriveClaimHash(BatchCompact memory compact, bytes32 mandateHash)
        internal
        pure
        returns (bytes32)
    {
        bytes32 commitmentsHash = _deriveCommitmentsHash(compact.commitments);
        return keccak256(
            abi.encode(
                COMPACT_TYPEHASH_WITH_MANDATE,
                compact.arbiter,
                compact.sponsor,
                compact.nonce,
                compact.expires,
                commitmentsHash,
                mandateHash
            )
        );
    }

    function _deriveCommitmentsHash(Lock[] memory commitments) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](commitments.length);
        for (uint256 i = 0; i < commitments.length; i++) {
            hashes[i] = keccak256(
                abi.encode(
                    LOCK_TYPEHASH,
                    commitments[i].lockTag,
                    commitments[i].token,
                    commitments[i].amount
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }
}
