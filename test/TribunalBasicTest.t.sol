// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Mandate, Fill, Adjustment, RecipientCallback} from "../src/types/TribunalStructs.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {WITNESS_TYPESTRING} from "../src/types/TribunalTypeHashes.sol";

contract TribunalBasicTest is Test {
    using FixedPointMathLib for uint256;

    Tribunal public tribunal;
    address theCompact;
    address sponsor;
    address adjuster;

    uint256[] public emptyPriceCurve;

    bytes32 constant MANDATE_TYPEHASH = keccak256(
        "Mandate(address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,address fillToken,uint256 minimumFillAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,address recipient,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)"
    );

    bytes32 constant COMPACT_TYPEHASH_WITH_MANDATE = keccak256(
        "BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Lock[] commitments,Mandate mandate)Lock(bytes12 lockTag,address token,uint256 amount)Mandate(address adjuster,Mandate_Fill[] fills)Mandate_BatchCompact(address arbiter,address sponsor,uint256 nonce,uint256 expires,Mandate_Lock[] commitments,Mandate mandate)Mandate_Fill(uint256 chainId,address tribunal,uint256 expires,address fillToken,uint256 minimumFillAmount,uint256 baselinePriorityFee,uint256 scalingFactor,uint256[] priceCurve,address recipient,Mandate_RecipientCallback[] recipientCallback,bytes32 salt)Mandate_Lock(bytes12 lockTag,address token,uint256 amount)Mandate_RecipientCallback(uint256 chainId,Mandate_BatchCompact compact,bytes context)"
    );

    bytes32 constant MANDATE_LOCK_TYPEHASH =
        keccak256("Mandate_Lock(bytes12 lockTag,address token,uint256 amount)");

    bytes32 constant LOCK_TYPEHASH = keccak256("Lock(bytes12 lockTag,address token,uint256 amount)");

    receive() external payable {}

    function setUp() public {
        theCompact = address(0xC0);
        tribunal = new Tribunal();
        (sponsor,) = makeAddrAndKey("sponsor");
        (adjuster,) = makeAddrAndKey("adjuster");

        emptyPriceCurve = new uint256[](0);
    }

    function test_Name() public view {
        assertEq(tribunal.name(), "Tribunal");
    }

    function test_DeriveMandateHash() public view {
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

        bytes32 fillsHash = keccak256(abi.encodePacked(tribunal.deriveFillHash(fill)));

        bytes32 expectedHash = keccak256(abi.encode(MANDATE_TYPEHASH, mandate.adjuster, fillsHash));

        assertEq(tribunal.deriveMandateHash(mandate), expectedHash);
    }

    function test_DeriveMandateHash_DifferentSalt() public view {
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
            salt: bytes32(uint256(2))
        });

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;

        bytes32 fillsHash = keccak256(abi.encodePacked(tribunal.deriveFillHash(fill)));

        bytes32 expectedHash = keccak256(abi.encode(MANDATE_TYPEHASH, mandate.adjuster, fillsHash));

        assertEq(tribunal.deriveMandateHash(mandate), expectedHash);
    }

    function test_DeriveClaimHash() public view {
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

        BatchCompact memory compact = BatchCompact({
            arbiter: address(this),
            sponsor: sponsor,
            nonce: 0,
            expires: block.timestamp + 1 hours,
            commitments: commitments
        });

        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);

        bytes32 commitmentsHash = keccak256(
            abi.encodePacked(
                keccak256(
                    abi.encode(
                        LOCK_TYPEHASH,
                        compact.commitments[0].lockTag,
                        compact.commitments[0].token,
                        compact.commitments[0].amount
                    )
                )
            )
        );

        bytes32 expectedHash = keccak256(
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

        assertEq(tribunal.deriveClaimHash(compact, mandateHash), expectedHash);
    }

    function test_GetCompactWitnessDetails() public view {
        (string memory witnessTypeString, ITribunal.ArgDetail[] memory details) =
            tribunal.getCompactWitnessDetails();

        assertEq(witnessTypeString, string.concat("Mandate(", WITNESS_TYPESTRING, ")"));
        assertEq(details.length, 1);
        assertEq(details[0].tokenPath, "fills[].fillToken");
        assertEq(details[0].argPath, "fills[].minimumFillAmount");
        assertEq(
            details[0].description,
            "Output token and minimum amount for each fill in the Fills array"
        );
    }
}
