// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC7683Tribunal} from "../src/ERC7683Tribunal.sol";
import {Tribunal} from "../src/Tribunal.sol";
import {FixedPointMathLib} from "the-compact/lib/solady/src/utils/FixedPointMathLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

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
    uint256 minimumFillAmount;
    uint256 claimAmount;
    uint256 targetBlock;
    uint256 maximumBlocksAfterTarget;
    ResolvedCrossChainOrder public order;
    Tribunal.Claim public claim;

    function setUp() public {
        tribunal = new ERC7683Tribunal();
        token = new MockERC20();
        sponsor = makeAddr("Sponsor");
        filler = makeAddr("Filler");
        minimumFillAmount = 1 ether;
        claimAmount = 10 ether;
        targetBlock = 100;
        maximumBlocksAfterTarget = 10;
        address arbiter = makeAddr("Arbiter");

        ERC7683Tribunal.Mandate memory mandate = _getMandate();
        claim = Tribunal.Claim({
            chainId: block.chainid,
            compact: Tribunal.Compact({
                arbiter: arbiter,
                sponsor: sponsor,
                nonce: uint256(bytes32(abi.encodePacked(sponsor, uint96(0)))),
                expires: 1703116800,
                id: 1,
                amount: claimAmount
            }),
            sponsorSignature: hex"abcd",
            allocatorSignature: hex"1234"
        });
        Output memory outputMaxSpent = Output({
            token: bytes32(uint256(uint160(address(token)))),
            amount: type(uint256).max,
            recipient: bytes32(uint256(uint160(sponsor))),
            chainId: block.chainid
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
            originData: abi.encode(claim, mandate, targetBlock, maximumBlocksAfterTarget)
        });
        Output[] memory maxSpent = new Output[](1);
        maxSpent[0] = outputMaxSpent;
        Output[] memory minReceived = new Output[](1);
        minReceived[0] = outputMinReceived;
        FillInstruction[] memory fillInstructions = new FillInstruction[](1);
        fillInstructions[0] = fillInstruction;

        order = ResolvedCrossChainOrder({
            user: sponsor,
            originChainId: 1,
            openDeadline: 100,
            fillDeadline: 200,
            orderId: bytes32(0),
            maxSpent: maxSpent,
            minReceived: minReceived,
            fillInstructions: fillInstructions
        });
    }

    function _getMandate() internal view returns (Tribunal.Mandate memory) {
        return Tribunal.Mandate({
            recipient: sponsor,
            expires: 1703116800, // 2023-12-21 00:00:00 UTC
            token: address(token),
            minimumAmount: minimumFillAmount,
            baselinePriorityFee: 100 wei,
            scalingFactor: 1e18,
            decayCurve: new uint256[](0),
            salt: bytes32(uint256(1))
        });
    }
}

contract ERC7683Tribunal_Fill is MockSetup {
    function test_revert_InvalidOriginData() public {
        vm.expectRevert();
        ERC7683Tribunal.Mandate memory mandate = _getMandate();

        tribunal.fill(
            order.orderId,
            abi.encode(claim, mandate, targetBlock, maximumBlocksAfterTarget, uint8(1)),
            abi.encode(filler)
        );
    }

    function test_revert_InvalidFillerData() public {
        vm.expectRevert();
        ERC7683Tribunal.Mandate memory mandate = _getMandate();

        tribunal.fill(
            order.orderId,
            abi.encode(claim, mandate, targetBlock, maximumBlocksAfterTarget),
            abi.encode(filler, makeAddr("AdditionalAddress"))
        );
    }

    function test_success() public {
        token.transfer(sponsor, minimumFillAmount);
        token.approve(address(tribunal), minimumFillAmount);

        Tribunal.Mandate memory mandate = _getMandate();
        bytes32 mandateHash = tribunal.deriveMandateHash(mandate);
        bytes32 claimHash = tribunal.deriveClaimHash(claim.compact, mandateHash);

        vm.roll(targetBlock);

        vm.expectEmit(true, true, false, true, address(tribunal));
        emit Tribunal.Fill(sponsor, filler, claimHash, minimumFillAmount, claimAmount, targetBlock);
        tribunal.fill(order.orderId, order.fillInstructions[0].originData, abi.encode(filler));
    }
}
