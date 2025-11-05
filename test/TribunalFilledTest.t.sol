// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {
    Mandate,
    FillParameters,
    FillComponent,
    Adjustment,
    RecipientCallback,
    FillRecipient
} from "../src/types/TribunalStructs.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {MANDATE_TYPEHASH} from "../src/types/TribunalTypeHashes.sol";

contract TribunalFilledTest is Test {
    using FixedPointMathLib for uint256;

    Tribunal public tribunal;
    address theCompact;
    address sponsor;
    address adjuster;
    uint256 adjusterPrivateKey;

    uint256[] public emptyPriceCurve;

    receive() external payable {}

    function setUp() public {
        theCompact = address(0xC0);
        tribunal = new Tribunal();
        (sponsor,) = makeAddrAndKey("sponsor");
        (adjuster, adjusterPrivateKey) = makeAddrAndKey("adjuster");

        emptyPriceCurve = new uint256[](0);
    }

    function test_FilledReturnsTrueForUsedClaim() public {
        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(0),
            minimumFillAmount: 1 ether,
            recipient: address(0xCAFE),
            applyScaling: true
        });

        FillParameters memory fill = FillParameters({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: 1703116800,
            components: components,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: emptyPriceCurve,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });

        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(0), amount: 1 ether});

        // Make it a cross-chain fill to avoid needing to mock TheCompact
        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
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

        // Build a Mandate struct to compute the hash properly
        Mandate memory mandateStruct = Mandate({adjuster: adjuster, fills: new FillParameters[](1)});
        mandateStruct.fills[0] = fill;

        bytes32 mandateHash = tribunal.deriveMandateHash(mandateStruct);
        bytes32 claimHash = tribunal.deriveClaimHash(claim.compact, mandateHash);
        assertEq(tribunal.filled(claimHash), bytes32(0));

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = commitments[0].amount;

        // The actual claimHash will be computed in _fill using the mandateHash from _deriveMandateHash
        // We need to compute it the same way for the adjustment signature
        // The mandate hash typehash should match MANDATE_TYPEHASH from TribunalTypeHashes.sol
        bytes32 actualMandateHash = keccak256(
            abi.encode(MANDATE_TYPEHASH, adjuster, keccak256(abi.encodePacked(fillHashes)))
        );
        bytes32 actualClaimHash = tribunal.deriveClaimHash(claim.compact, actualMandateHash);

        FillRecipient[] memory fillRecipients = new FillRecipient[](1);
        fillRecipients[0] = FillRecipient({fillAmount: 1 ether, recipient: address(0xCAFE)});

        // Expect Fill event for cross-chain fills
        vm.expectEmit(true, true, true, true, address(tribunal));
        emit ITribunal.Fill(
            sponsor,
            bytes32(uint256(uint160(address(this)))),
            actualClaimHash,
            fillRecipients,
            claimAmounts,
            adjustment.targetBlock
        );

        // Sign the adjustment with the actual claimHash that will be computed in _fill
        bytes32 adjustmentHash = keccak256(
            abi.encode(
                keccak256(
                    "Adjustment(bytes32 claimHash,uint256 fillIndex,uint256 targetBlock,uint256[] supplementalPriceCurve,bytes32 validityConditions)"
                ),
                actualClaimHash,
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

        tribunal.fill{
            value: 1 ether
        }(
            claim.compact,
            fill,
            adjuster,
            adjustment,
            adjustmentSignature,
            fillHashes,
            bytes32(uint256(uint160(address(this)))),
            0
        );
        assertEq(tribunal.filled(actualClaimHash), bytes32(uint256(uint160(address(this)))));
    }
}
