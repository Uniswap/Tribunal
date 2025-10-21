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
import {Mandate, Fill, FillComponent, Adjustment, RecipientCallback} from "../src/types/TribunalStructs.sol";
import {
    BatchCompact,
    Lock,
    BATCH_COMPACT_TYPEHASH,
    LOCK_TYPEHASH
} from "the-compact/src/types/EIP712Types.sol";
import {COMPACT_TYPEHASH_WITH_MANDATE} from "../src/types/TribunalTypeHashes.sol";

contract TribunalFillSuccessTest is DeployTheCompact, ITribunalCallback {
    using FixedPointMathLib for uint256;

    Tribunal public tribunal;
    TheCompact public compactContract;
    MockERC20 public token;
    address sponsor;
    uint256 sponsorPrivateKey;
    address adjuster;
    uint256 adjusterPrivateKey;
    FillerContract public filler;
    uint96 allocatorId;

    uint256[] public emptyPriceCurve;

    receive() external payable {}

    function _generateSponsorSignature(BatchCompact memory compact, bytes32 mandateHash)
        internal
        view
        returns (bytes memory)
    {
        // TheCompact constructs the full typestring by combining:
        // 1. BatchCompact prefix and "Mandate("
        // 2. The witness typestring from Tribunal (which includes ) after arguments but no final ))
        // 3. A closing parenthesis at the very end

        // Import the actual witness typestring that Tribunal sends
        string memory witnessTypestring =
            "address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,address fillToken,uint256 minimumFillAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,address recipient,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context";

        // Construct the full typestring as TheCompact would
        string memory fullTypestring = string.concat(
            "BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Lock[] commitments,Mandate mandate)Lock(bytes12 lockTag,address token,uint256 amount)Mandate(",
            witnessTypestring,
            ")"
        );

        // Compute the typehash from the full typestring
        bytes32 computedTypehash = keccak256(bytes(fullTypestring));

        // Generate the struct hash for the batch compact with mandate
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

        // Get TheCompact's domain separator
        bytes32 domainSeparator = compactContract.DOMAIN_SEPARATOR();

        // Create the EIP-712 digest
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign with compact format (r, vs)
        bytes32 r;
        bytes32 vs;
        (r, vs) = vm.signCompact(sponsorPrivateKey, digest);

        return abi.encodePacked(r, vs);
    }

    function setUp() public {
        compactContract = deployTheCompact();

        // Register an allocator for same-chain fills
        vm.prank(address(this));
        allocatorId = compactContract.__registerAllocator(address(this), "");

        tribunal = new Tribunal();
        token = new MockERC20();
        (sponsor, sponsorPrivateKey) = makeAddrAndKey("sponsor");
        (adjuster, adjusterPrivateKey) = makeAddrAndKey("adjuster");
        filler = new FillerContract();

        emptyPriceCurve = new uint256[](0);

        // Fund the sponsor and filler
        vm.deal(sponsor, 100 ether);
        vm.deal(address(filler), 100 ether);

        // Transfer some tokens to the filler for the ERC20 test
        token.transfer(address(filler), 100e18);
    }

    // Implement ITribunalCallback
    function tribunalCallback(
        bytes32,
        Lock[] calldata,
        uint256[] calldata,
        address,
        uint256,
        uint256
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
        // Simply approve the claim
        return this.authorizeClaim.selector;
    }

    function test_FillSettlesNativeToken() public {
        // Deposit native tokens to TheCompact for the sponsor
        uint256 depositAmount = 2 ether;

        vm.prank(sponsor);
        compactContract.depositNative{value: depositAmount}(bytes12(uint96(allocatorId)), sponsor);

        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            recipient: address(0xBEEF),
            applyScaling: false
        });

        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            components: components,
            baselinePriorityFee: 0,
            scalingFactor: 1e18, // Use neutral scaling factor
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] =
            Lock({lockTag: bytes12(uint96(allocatorId)), token: address(0), amount: 1 ether});

        // Generate the mandate hash
        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);

        // Generate sponsor signature for the BatchCompact with mandate witness
        // Note: TheCompact uses msg.sender (Tribunal) as the arbiter when verifying
        bytes memory sponsorSig = _generateSponsorSignature(
            BatchCompact({
                arbiter: address(tribunal), // TheCompact will use msg.sender which is Tribunal
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            mandateHash
        );

        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
            chainId: block.chainid,
            compact: BatchCompact({
                arbiter: address(tribunal), // Must match what's signed
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

        // Derive the actual claim hash
        bytes32 claimHash = tribunal.deriveClaimHash(claim.compact, mandateHash);

        // Sign the adjustment
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
        bytes memory adjustmentSignature = abi.encodePacked(r, s, v);

        uint256 initialFillerBalance = address(filler).balance;
        vm.prank(address(filler));
        tribunal.fill{value: 1 ether}(
            claim,
            fill,
            adjuster,
            adjustment,
            adjustmentSignature,
            fillHashes,
            bytes32(uint256(uint160(address(filler)))),
            0
        );

        assertEq(address(0xBEEF).balance, 1 ether);
        assertEq(address(filler).balance, initialFillerBalance); // Filler balance unchanged (paid 1 ether, received 1 ether from TheCompact)
    }

    function test_FillSettlesERC20Token() public {
        // Transfer tokens to sponsor and deposit to TheCompact
        uint256 depositAmount = 200e18;
        token.transfer(sponsor, depositAmount);

        vm.startPrank(sponsor);
        token.approve(address(compactContract), depositAmount);
        compactContract.depositERC20(
            address(token), bytes12(uint96(allocatorId)), depositAmount, sponsor
        );
        vm.stopPrank();

        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 100e18,
            recipient: address(0xBEEF),
            applyScaling: false
        });

        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: uint256(block.timestamp + 1),
            components: components,
            baselinePriorityFee: 0,
            scalingFactor: 1e18, // Use neutral scaling factor
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] =
            Lock({lockTag: bytes12(uint96(allocatorId)), token: address(token), amount: 100e18});

        // Generate the mandate hash
        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);

        // Generate sponsor signature for the BatchCompact with mandate witness
        // Note: TheCompact uses msg.sender (Tribunal) as the arbiter when verifying
        bytes memory sponsorSig = _generateSponsorSignature(
            BatchCompact({
                arbiter: address(tribunal), // TheCompact will use msg.sender which is Tribunal
                sponsor: sponsor,
                nonce: 0,
                expires: block.timestamp + 1 hours,
                commitments: commitments
            }),
            mandateHash
        );

        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
            chainId: block.chainid,
            compact: BatchCompact({
                arbiter: address(tribunal), // Must match what's signed
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

        vm.prank(address(filler));
        token.approve(address(tribunal), type(uint256).max);

        uint256 initialFillerBalance = token.balanceOf(address(filler));

        // Derive the actual claim hash
        bytes32 claimHash = tribunal.deriveClaimHash(claim.compact, mandateHash);

        // Sign the adjustment
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
        bytes memory adjustmentSignature = abi.encodePacked(r, s, v);

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = commitments[0].amount;


        vm.prank(address(filler));
        tribunal.fill(
            claim,
            fill,
            adjuster,
            adjustment,
            adjustmentSignature,
            fillHashes,
            bytes32(uint256(uint160(address(filler)))),
            0
        );

        assertEq(token.balanceOf(address(0xBEEF)), 100e18);
        assertEq(token.balanceOf(address(filler)), initialFillerBalance); // Filler balance unchanged (paid 100e18, received 100e18 from TheCompact)
    }
}
