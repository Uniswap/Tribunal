// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {DeployTheCompact} from "./helpers/DeployTheCompact.sol";
import {TheCompact} from "the-compact/src/TheCompact.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ITribunalCallback} from "../src/interfaces/ITribunalCallback.sol";
import {
    Mandate,
    FillParameters,
    FillComponent,
    FillRequirement,
    Adjustment,
    RecipientCallback,
    BatchClaim
} from "../src/types/TribunalStructs.sol";
import {BatchCompact, Lock, LOCK_TYPEHASH} from "the-compact/src/types/EIP712Types.sol";
import {ADJUSTMENT_TYPEHASH} from "../src/types/TribunalTypeHashes.sol";

/**
 * @title TribunalClaimAndFillInvalidAdjusterTest
 * @notice Test coverage for invalid adjuster authorization during claimAndFill execution
 * @dev Covers lines 841-847 in Tribunal.sol (_claimAndFill function)
 */
contract TribunalClaimAndFillInvalidAdjusterTest is DeployTheCompact, ITribunalCallback {
    Tribunal public tribunal;
    TheCompact public compactContract;
    MockERC20 public token;
    address sponsor;
    uint256 sponsorPrivateKey;
    address adjuster;
    uint256 adjusterPrivateKey;
    uint96 allocatorId;

    uint256[] public emptyPriceCurve;

    receive() external payable {}

    function setUp() public {
        compactContract = deployTheCompact();

        // Register an allocator for same-chain fills
        vm.prank(address(this));
        allocatorId = compactContract.__registerAllocator(address(this), "");

        tribunal = new Tribunal();
        token = new MockERC20();
        (sponsor, sponsorPrivateKey) = makeAddrAndKey("sponsor");
        (adjuster, adjusterPrivateKey) = makeAddrAndKey("adjuster");

        emptyPriceCurve = new uint256[](0);

        // Fund accounts
        vm.deal(sponsor, 100 ether);
        vm.deal(address(this), 100 ether);

        // Transfer tokens to sponsor and test contract (which will be the filler)
        token.transfer(sponsor, 200e18);
        token.transfer(address(this), 100e18);

        // Sponsor deposits tokens
        vm.startPrank(sponsor);
        token.approve(address(compactContract), 200e18);
        compactContract.depositERC20(address(token), bytes12(uint96(allocatorId)), 200e18, sponsor);
        vm.stopPrank();

        // Test contract (filler) approves tribunal
        token.approve(address(tribunal), type(uint256).max);
    }

    // Implement ITribunalCallback
    function tribunalCallback(
        bytes32,
        Lock[] calldata,
        uint256[] calldata,
        FillRequirement[] calldata
    ) external {
        // Empty implementation for testing
    }

    // Implement allocator interface for TheCompact
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

    /**
     * @notice Test that claimAndFill reverts with InvalidAdjustment when adjustment authorization is invalid
     * @dev This covers the uncovered lines 841-847 in the _claimAndFill function
     */
    function test_ClaimAndFill_InvalidAdjusterAuthorization() public {
        BatchCompact memory compact = _createCompact();
        FillParameters memory fillParams = _createFillParams();
        bytes32 mandateHash = _deriveMandateHash(fillParams);

        BatchClaim memory claim = _createBatchClaim(compact, mandateHash);
        bytes32[] memory fillHashes = _createFillHashes(fillParams);
        Adjustment memory adjustment = _createInvalidAdjustment(compact, mandateHash);

        // Attempt claimAndFill - should revert with InvalidAdjustment
        vm.expectRevert(ITribunal.InvalidAdjustment.selector);
        tribunal.claimAndFill(
            claim, fillParams, adjustment, fillHashes, bytes32(uint256(uint160(address(this)))), 0
        );
    }

    function _createCompact() internal view returns (BatchCompact memory) {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] =
            Lock({lockTag: bytes12(uint96(allocatorId)), token: address(token), amount: 100e18});

        return BatchCompact({
            arbiter: address(tribunal),
            sponsor: sponsor,
            nonce: 0,
            expires: block.timestamp + 1 hours,
            commitments: commitments
        });
    }

    function _createFillParams() internal view returns (FillParameters memory) {
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 100e18,
            recipient: address(0xBEEF),
            applyScaling: false
        });

        return FillParameters({
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
    }

    function _deriveMandateHash(FillParameters memory fillParams) internal view returns (bytes32) {
        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new FillParameters[](1)});
        mandate.fills[0] = fillParams;
        return tribunal.deriveMandateHash(mandate);
    }

    function _createBatchClaim(BatchCompact memory compact, bytes32 mandateHash)
        internal
        view
        returns (BatchClaim memory)
    {
        bytes memory sponsorSig = _generateSponsorSignature(compact, mandateHash);
        return BatchClaim({
            compact: compact, sponsorSignature: sponsorSig, allocatorSignature: new bytes(0)
        });
    }

    function _createFillHashes(FillParameters memory fillParams)
        internal
        view
        returns (bytes32[] memory)
    {
        bytes32[] memory fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fillParams);
        return fillHashes;
    }

    function _createInvalidAdjustment(BatchCompact memory compact, bytes32 mandateHash)
        internal
        returns (Adjustment memory)
    {
        Adjustment memory adjustment = Adjustment({
            adjuster: adjuster,
            fillIndex: 0,
            targetBlock: vm.getBlockNumber(),
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0),
            adjustmentAuthorization: ""
        });

        // Sign with wrong private key to create invalid signature
        (, uint256 wrongPrivateKey) = makeAddrAndKey("wrongAdjuster");
        bytes32 claimHash = tribunal.deriveClaimHash(compact, mandateHash);
        adjustment.adjustmentAuthorization = _signAdjustment(adjustment, claimHash, wrongPrivateKey);

        return adjustment;
    }

    function _signAdjustment(Adjustment memory adjustment, bytes32 claimHash, uint256 privateKey)
        internal
        view
        returns (bytes memory)
    {
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

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
        bytes32 commitmentsHash = _deriveCommitmentsHash(compact.commitments);

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

        (bytes32 r, bytes32 vs) = vm.signCompact(sponsorPrivateKey, digest);
        return abi.encodePacked(r, vs);
    }

    function _deriveCommitmentsHash(Lock[] memory commitments) internal pure returns (bytes32) {
        bytes32[] memory lockHashes = new bytes32[](commitments.length);
        for (uint256 i = 0; i < commitments.length; i++) {
            lockHashes[i] = keccak256(
                abi.encode(
                    LOCK_TYPEHASH,
                    commitments[i].lockTag,
                    commitments[i].token,
                    commitments[i].amount
                )
            );
        }
        return keccak256(abi.encodePacked(lockHashes));
    }
}
