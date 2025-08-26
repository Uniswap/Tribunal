// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC7683Tribunal} from "../src/ERC7683Tribunal.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {BatchCompact, Lock} from "the-compact/src/types/EIP712Types.sol";
import {ITribunal} from "../src/interfaces/ITribunal.sol";
import {FixedPointMathLib} from "the-compact/lib/solady/src/utils/FixedPointMathLib.sol";
import {Mandate, Fill, Adjustment, RecipientCallback} from "../src/types/TribunalStructs.sol";
import {ADJUSTMENT_TYPEHASH} from "../src/types/TribunalTypeHashes.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {TheCompact} from "the-compact/src/TheCompact.sol";

abstract contract MockSetup is Test {
    struct ResolvedCrossChainOrder {
        /// @dev The address of the user who is initiating the transfer
        address user;
        /// @dev The chainId of the origin chain
        uint256 originChainId;
        /// @dev The timestamp by which the order must be opened
        uint32 openDeadline;
        /// @dev The timestamp by which the order must be filled on the destination chain(s)
        uint32 fillDeadline;
        /// @dev The unique identifier for this order within this settlement system
        bytes32 orderId;
        /// @dev The max outputs that the filler will send. It's possible the actual amount depends on the state of the destination
        ///      chain (destination dutch auction, for instance), so these outputs should be considered a cap on filler liabilities.
        Output[] maxSpent;
        /// @dev The minimum outputs that must be given to the filler as part of order settlement. Similar to maxSpent, it's possible
        ///      that special order types may not be able to guarantee the exact amount at open time, so this should be considered
        ///      a floor on filler receipts.
        Output[] minReceived;
        /// @dev Each instruction in this array is parameterizes a single leg of the fill. This provides the filler with the information
        ///      necessary to perform the fill on the destination(s).
        FillInstruction[] fillInstructions;
    }

    /// @notice Tokens that must be received for a valid order fulfillment
    struct Output {
        /// @dev The address of the ERC20 token on the destination chain
        /// @dev address(0) used as a sentinel for the native token
        bytes32 token;
        /// @dev The amount of the token to be sent
        uint256 amount;
        /// @dev The address to receive the output tokens
        bytes32 recipient;
        /// @dev The destination chain for this output
        uint256 chainId;
    }

    /// @title FillInstruction type
    /// @notice Instructions to parameterize each leg of the fill
    /// @dev Provides all the origin-generated information required to produce a valid fill leg
    struct FillInstruction {
        /// @dev The contract address that the order is meant to be settled by
        uint256 destinationChainId;
        /// @dev The contract address that the order is meant to be filled on
        bytes32 destinationSettler;
        /// @dev The data generated on the origin chain needed by the destinationSettler to process the fill
        bytes originData;
    }

    ERC7683Tribunal public tribunal;
    MockERC20 public token;
    address sponsor;
    address filler;
    address adjuster;
    uint256 adjusterPrivateKey;
    uint256 minimumFillAmount;
    uint256 claimAmount;
    uint256 targetBlock;
    uint256 sourceChainId;
    address arbiter;
    ResolvedCrossChainOrder public order;

    function setUp() public {
        tribunal = new ERC7683Tribunal(address(new TheCompact()));
        token = new MockERC20();
        sponsor = makeAddr("Sponsor");
        filler = makeAddr("Filler");
        (adjuster, adjusterPrivateKey) = makeAddrAndKey("Adjuster");
        minimumFillAmount = 1 ether;
        claimAmount = 10 ether;
        targetBlock = 100;
        arbiter = makeAddr("Arbiter");
        sourceChainId = 1;

        Output memory outputMaxSpent = Output({
            token: bytes32(uint256(uint160(address(token)))),
            amount: type(uint256).max,
            recipient: bytes32(uint256(uint160(sponsor))),
            chainId: sourceChainId
        });
        Output memory outputMinReceived = Output({
            token: bytes32(uint256(uint160(address(token)))),
            amount: claimAmount,
            recipient: bytes32(uint256(uint160(0))),
            chainId: 1
        });
        FillInstruction memory fillInstruction = FillInstruction({
            destinationChainId: 1,
            destinationSettler: bytes32(uint256(uint160(address(tribunal)))),
            originData: _getOriginData()
        });
        Output[] memory maxSpent = new Output[](1);
        maxSpent[0] = outputMaxSpent;
        Output[] memory minReceived = new Output[](1);
        minReceived[0] = outputMinReceived;
        FillInstruction[] memory fillInstructions = new FillInstruction[](1);
        fillInstructions[0] = fillInstruction;

        BatchCompact memory compact = _getBatchCompact();
        Mandate memory mandate = _getMandate();

        order = ResolvedCrossChainOrder({
            user: sponsor,
            originChainId: 1,
            openDeadline: uint32(compact.expires),
            fillDeadline: uint32(mandate.fills[0].expires),
            orderId: bytes32(compact.nonce),
            maxSpent: maxSpent,
            minReceived: minReceived,
            fillInstructions: fillInstructions
        });
    }

    function _getClaim() internal view returns (ITribunal.BatchClaim memory) {
        return ITribunal.BatchClaim({
            chainId: sourceChainId,
            compact: _getBatchCompact(),
            sponsorSignature: hex"abcd",
            allocatorSignature: hex"1234"
        });
    }

    function _getBatchCompact() internal view returns (BatchCompact memory) {
        Lock[] memory commitments = new Lock[](1);
        commitments[0] = Lock({lockTag: bytes12(0), token: address(token), amount: claimAmount});
        return BatchCompact({
            arbiter: arbiter,
            sponsor: sponsor,
            nonce: 1,
            expires: 1703116800,
            commitments: commitments
        });
    }

    function _getMandate() internal view returns (Mandate memory) {
        Fill[] memory fills = new Fill[](1);
        fills[0] = _getFill();
        return Mandate({adjuster: adjuster, fills: fills});
    }

    function _getFill() internal view returns (Fill memory) {
        return Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            fillToken: address(token),
            minimumFillAmount: minimumFillAmount,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: new uint256[](0),
            recipient: sponsor,
            recipientCallback: new RecipientCallback[](0),
            salt: bytes32(uint256(1))
        });
    }

    function _getAdjustment() internal view returns (Adjustment memory) {
        return Adjustment({
            fillIndex: 0,
            targetBlock: targetBlock,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });
    }

    function _getOriginData() internal view returns (bytes memory) {
        Mandate memory mandate = _getMandate();
        bytes32[] memory fillHashes = new bytes32[](mandate.fills.length);
        for (uint256 i = 0; i < mandate.fills.length; i++) {
            fillHashes[i] = tribunal.deriveFillHash(mandate.fills[i]);
        }
        return abi.encode(_getClaim(), mandate.fills[0], mandate.adjuster, fillHashes);
    }

    function _getFillerData() internal view returns (bytes memory) {
        Adjustment memory adjustment = _getAdjustment();
        bytes memory adjustmentAuthorization =
            _toAdjustmentSignature(adjustment, _getBatchCompact(), _getMandate());
        return abi.encode(
            adjustment, adjustmentAuthorization, bytes32(uint256(uint160(filler))), targetBlock
        );
    }

    function _toAdjustmentHash(
        Adjustment memory adjustment,
        BatchCompact memory compact,
        Mandate memory mandate
    ) internal view returns (bytes32 adjustmentHash) {
        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);
        bytes32 claimHash = tribunal.deriveClaimHash(compact, mandateHash);

        return keccak256(
            abi.encode(
                ADJUSTMENT_TYPEHASH,
                claimHash,
                adjustment.fillIndex,
                adjustment.targetBlock,
                keccak256(abi.encodePacked(adjustment.supplementalPriceCurve)),
                adjustment.validityConditions
            )
        );
    }

    function _toAdjustmentSignature(
        Adjustment memory adjustment,
        BatchCompact memory compact,
        Mandate memory mandate
    ) internal view returns (bytes memory) {
        bytes32 adjustmentHash = _toAdjustmentHash(adjustment, compact, mandate);
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
        return adjustmentSignature;
    }
}

contract ERC7683Tribunal_Fill is MockSetup {
    function test_revert_InvalidOriginData_InvalidClaimOffset() public {
        Mandate memory mandate = _getMandate();
        bytes32[] memory fillHashes = new bytes32[](mandate.fills.length);
        for (uint256 i = 0; i < mandate.fills.length; i++) {
            fillHashes[i] = tribunal.deriveFillHash(mandate.fills[i]);
        }

        bytes memory fillerData = _getFillerData();

        vm.expectRevert();
        tribunal.fill(
            order.orderId,
            abi.encode(
                _getClaim(), mandate.fills[0], mandate.adjuster, fillHashes, 1 /* invalid input */
            ),
            fillerData
        );
    }

    function test_revert_InvalidOriginData_InvlaidLength() public {
        ITribunal.BatchClaim memory claim = ITribunal.BatchClaim({
            chainId: sourceChainId,
            compact: BatchCompact({
                arbiter: arbiter,
                sponsor: sponsor,
                nonce: 1,
                expires: 1703116800,
                commitments: new Lock[](0) // minimal length
            }),
            sponsorSignature: "",
            allocatorSignature: ""
        });
        Fill memory fill = Fill({
            chainId: block.chainid,
            tribunal: address(tribunal),
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            fillToken: address(token),
            minimumFillAmount: minimumFillAmount,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            priceCurve: new uint256[](0), // minimal length
            recipient: sponsor,
            recipientCallback: new RecipientCallback[](0), // minimal length
            salt: bytes32(uint256(1))
        });
        bytes32[] memory fillHashes = new bytes32[](1); // minimal length
        fillHashes[0] = tribunal.deriveFillHash(fill);

        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: targetBlock,
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0)
        });
        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new Fill[](1)});
        mandate.fills[0] = fill;
        bytes memory adjustmentAuthorization =
            _toAdjustmentSignature(adjustment, claim.compact, mandate);

        // Transfer tokens, approval and roll to target block
        token.transfer(filler, minimumFillAmount);
        vm.prank(filler);
        token.approve(address(tribunal), minimumFillAmount);
        vm.roll(targetBlock);

        // Should succeed
        vm.prank(filler);
        tribunal.fill(
            order.orderId,
            abi.encode(claim, fill, adjuster, fillHashes),
            abi.encode(
                adjustment, adjustmentAuthorization, bytes32(uint256(uint160(filler))), targetBlock
            )
        );

        bytes memory fillerData = _getFillerData();

        // Expect a revert since the Mandate.fillHashes must be at least length 1
        vm.expectRevert();
        tribunal.fill(
            order.orderId,
            abi.encode(
                claim,
                fill,
                adjuster,
                new bytes32[](0) /* invalid input - Mandate.fillHashes must be at least length 1 */
            ),
            fillerData
        );
    }

    function test_revert_InvalidFillerData_InvalidAdjustmentOffset() public {
        Adjustment memory adjustment = _getAdjustment();
        bytes memory adjustmentAuthorization =
            _toAdjustmentSignature(adjustment, _getBatchCompact(), _getMandate());
        bytes memory originData = _getOriginData();

        vm.expectRevert();
        tribunal.fill(
            order.orderId,
            originData,
            abi.encode(
                adjustment,
                adjustmentAuthorization,
                bytes32(uint256(uint160(filler))),
                targetBlock,
                1 /* invalid input */
            )
        );
    }

    function test_revert_InvalidFillerData_InvalidAdjustmentLength() public {
        Adjustment memory adjustment = Adjustment({
            fillIndex: 0,
            targetBlock: targetBlock,
            supplementalPriceCurve: new uint256[](0), // minimal length
            validityConditions: bytes32(0)
        });
        bytes memory adjustmentAuthorization = "";
        bytes memory originData = _getOriginData();

        vm.roll(targetBlock);

        // Should succeed to pass the ERC7683Tribunal fill call, only fail at the Adjustment.validityConditions check
        vm.expectRevert(
            abi.encodeWithSelector(ITribunal.InvalidAdjustment.selector, address(tribunal))
        );
        tribunal.fill(
            order.orderId,
            originData,
            abi.encode(
                adjustment, adjustmentAuthorization, bytes32(uint256(uint160(filler))), targetBlock
            )
        );

        // Expect a revert
        vm.expectRevert();
        tribunal.fill(
            order.orderId,
            originData,
            abi.encode(
                adjustment,
                bytes32(0), /* replacing dynamic adjustmentAuthorization with fixed bytes32 */
                bytes32(uint256(uint160(filler))),
                targetBlock
            )
        );
    }

    function test_success(address filler_) public {
        token.transfer(filler_, minimumFillAmount);
        vm.prank(filler_);
        token.approve(address(tribunal), minimumFillAmount);

        BatchCompact memory compact = _getBatchCompact();
        Mandate memory mandate = _getMandate();
        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);
        bytes32 claimHash = tribunal.deriveClaimHash(compact, mandateHash);

        vm.roll(targetBlock);

        uint256[] memory claimAmounts = new uint256[](1);
        claimAmounts[0] = compact.commitments[0].amount;

        bytes memory fillerData = _getFillerData();

        vm.prank(filler_);
        vm.expectEmit(true, true, true, true, address(tribunal));
        emit ITribunal.CrossChainFill(
            sourceChainId, sponsor, filler, claimHash, minimumFillAmount, claimAmounts, targetBlock
        );
        tribunal.fill(order.orderId, order.fillInstructions[0].originData, fillerData);
    }
}
