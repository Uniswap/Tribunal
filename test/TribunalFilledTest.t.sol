// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Mandate, Fill, Adjustment, RecipientCallback} from "../src/types/TribunalStructs.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";

contract TribunalFilledTest is Test {
    using FixedPointMathLib for uint256;

    Tribunal public tribunal;
    address theCompact;
    address sponsor;
    address adjuster;

    uint256[] public emptyPriceCurve;

    receive() external payable {}

    function setUp() public {
        theCompact = address(0xC0);
        tribunal = new Tribunal(theCompact);
        (sponsor,) = makeAddrAndKey("sponsor");
        (adjuster,) = makeAddrAndKey("adjuster");

        emptyPriceCurve = new uint256[](0);
    }

    function test_FilledReturnsTrueForUsedClaim() public {
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
}
