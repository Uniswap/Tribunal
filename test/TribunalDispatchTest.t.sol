// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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
    FillRequirement,
    Adjustment,
    RecipientCallback,
    DispatchParameters,
    BatchClaim
} from "../src/types/TribunalStructs.sol";
import {BatchCompact, Lock, LOCK_TYPEHASH} from "the-compact/src/types/EIP712Types.sol";

contract TribunalDispatchTest is DeployTheCompact, ITribunalCallback {
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
    uint96 allocatorId;

    uint256[] public emptyPriceCurve;

    event Dispatch(
        address indexed dispatchTarget,
        uint256 indexed chainId,
        bytes32 indexed claimant,
        bytes32 claimHash
    );

    receive() external payable {}

    function setUp() public {
        compactContract = deployTheCompact();

        // Register an allocator for same-chain fills
        vm.prank(address(this));
        allocatorId = compactContract.__registerAllocator(address(this), "");

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

        // Set dispatch target to success mode by default
        dispatchTarget.setMode(MockDispatchTarget.Mode.Success);
    }

    // Implement ITribunalCallback
    function tribunalCallback(
        bytes32,
        Lock[] calldata,
        uint256[] calldata,
        FillRequirement[] calldata
    ) external {}

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

        bytes32 domainSeparator = compactContract.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        bytes32 r;
        bytes32 vs;
        (r, vs) = vm.signCompact(sponsorPrivateKey, digest);

        return abi.encodePacked(r, vs);
    }

    function _signAdjustment(Adjustment memory adjustment, bytes32 claimHash)
        internal
        view
        returns (bytes memory)
    {
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
        return abi.encodePacked(r, s, v);
    }

    function _setupFill()
        internal
        returns (
            BatchClaim memory claim,
            FillParameters memory fill,
            Adjustment memory adjustment,
            bytes32[] memory fillHashes,
            bytes32 mandateHash,
            bytes32 claimHash
        )
    {
        // Deposit tokens to TheCompact
        vm.startPrank(sponsor);
        token.approve(address(compactContract), 100e18);
        compactContract.depositERC20(address(token), bytes12(uint96(allocatorId)), 100e18, sponsor);
        vm.stopPrank();

        FillComponent[] memory components = new FillComponent[](1);
        components[0] = FillComponent({
            fillToken: address(token),
            minimumFillAmount: 100e18,
            recipient: address(0xBEEF),
            applyScaling: false
        });

        fill = FillParameters({
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

        Mandate memory mandate = Mandate({adjuster: adjuster, fills: new FillParameters[](1)});
        mandate.fills[0] = fill;

        Lock[] memory commitments = new Lock[](1);
        commitments[0] =
            Lock({lockTag: bytes12(uint96(allocatorId)), token: address(token), amount: 100e18});

        mandateHash = tribunal.deriveMandateHash(mandate);

        BatchCompact memory compact = BatchCompact({
            arbiter: address(tribunal),
            sponsor: sponsor,
            nonce: 0,
            expires: block.timestamp + 1 hours,
            commitments: commitments
        });

        bytes memory sponsorSig = _generateSponsorSignature(compact, mandateHash);

        // Use a different chainId for cross-chain fill (e.g., Ethereum mainnet)
        claim = BatchClaim({
            compact: compact, sponsorSignature: sponsorSig, allocatorSignature: new bytes(0)
        });

        fillHashes = new bytes32[](1);
        fillHashes[0] = tribunal.deriveFillHash(fill);

        claimHash = tribunal.deriveClaimHash(claim.compact, mandateHash);

        adjustment = Adjustment({
            adjuster: adjuster,
            fillIndex: 0,
            targetBlock: vm.getBlockNumber(),
            supplementalPriceCurve: new uint256[](0),
            validityConditions: bytes32(0),
            adjustmentAuthorization: new bytes(0)
        });
    }

    function test_FillAndDispatch_Success() public {
        (
            BatchClaim memory claim,
            FillParameters memory fill,
            Adjustment memory adjustment,
            bytes32[] memory fillHashes,
            bytes32 mandateHash,
            bytes32 claimHash
        ) = _setupFill();

        bytes memory adjustmentSignature = _signAdjustment(adjustment, claimHash);

        // Set up expected values in the mock
        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = 100e18;

        uint256 targetChainId = 42161; // Arbitrum
        bytes memory context = abi.encode("test context");

        dispatchTarget.setExpectedValues(
            targetChainId,
            claim.compact,
            mandateHash,
            claimHash,
            bytes32(uint256(uint160(address(filler)))),
            1e18, // No reduction
            expectedAmounts,
            context
        );

        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: targetChainId,
            target: address(dispatchTarget),
            value: 0.5 ether,
            context: context
        });

        vm.prank(address(filler));
        token.approve(address(tribunal), type(uint256).max);

        vm.recordLogs();

        adjustment.adjustmentAuthorization = adjustmentSignature;

        vm.prank(address(filler));
        tribunal.fillAndDispatch{
            value: 0.5 ether
        }(
            claim.compact,
            fill,
            adjustment,
            fillHashes,
            bytes32(uint256(uint160(address(filler)))),
            0,
            dispatchParams
        );

        // Verify callback was called
        assertTrue(dispatchTarget.callbackCalled());
        assertEq(dispatchTarget.receivedChainId(), targetChainId);
        assertEq(dispatchTarget.receivedValue(), 0.5 ether);

        // Check that Dispatch event was emitted with correct parameters
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool dispatchEventFound = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Dispatch(address,uint256,bytes32,bytes32)")) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(dispatchTarget));
                assertEq(uint256(logs[i].topics[2]), targetChainId);
                assertEq(logs[i].topics[3], bytes32(uint256(uint160(address(filler)))));
                assertEq(abi.decode(logs[i].data, (bytes32)), claimHash);
                dispatchEventFound = true;
                break;
            }
        }
        assertTrue(dispatchEventFound, "Dispatch event not found");
    }

    function test_FillThenDispatch_Success() public {
        (
            BatchClaim memory claim,
            FillParameters memory fill,
            Adjustment memory adjustment,
            bytes32[] memory fillHashes,
            bytes32 mandateHash,
            bytes32 claimHash
        ) = _setupFill();

        bytes memory adjustmentSignature = _signAdjustment(adjustment, claimHash);

        vm.prank(address(filler));
        token.approve(address(tribunal), type(uint256).max);

        adjustment.adjustmentAuthorization = adjustmentSignature;

        // First, perform the fill
        vm.prank(address(filler));
        tribunal.fill(
            claim.compact,
            fill,
            adjustment,
            fillHashes,
            bytes32(uint256(uint160(address(filler)))),
            0
        );

        // Now dispatch separately
        uint256 targetChainId = 137; // Polygon
        bytes memory context = abi.encode("separate dispatch");

        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = 100e18;

        dispatchTarget.reset();
        dispatchTarget.setExpectedValues(
            targetChainId,
            claim.compact,
            mandateHash,
            claimHash,
            bytes32(uint256(uint160(address(filler)))),
            1e18,
            expectedAmounts,
            context
        );

        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: targetChainId,
            target: address(dispatchTarget),
            value: 1 ether,
            context: context
        });

        vm.recordLogs();

        vm.prank(address(filler));
        tribunal.dispatch{value: 1 ether}(claim.compact, mandateHash, dispatchParams);

        assertTrue(dispatchTarget.callbackCalled());
        assertEq(dispatchTarget.receivedChainId(), targetChainId);
        assertEq(dispatchTarget.receivedValue(), 1 ether);

        // Check that Dispatch event was emitted with correct parameters
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool dispatchEventFound = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Dispatch(address,uint256,bytes32,bytes32)")) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(dispatchTarget));
                assertEq(uint256(logs[i].topics[2]), targetChainId);
                assertEq(logs[i].topics[3], bytes32(uint256(uint160(address(filler)))));
                assertEq(abi.decode(logs[i].data, (bytes32)), claimHash);
                dispatchEventFound = true;
                break;
            }
        }
        assertTrue(dispatchEventFound, "Dispatch event not found");
    }

    function test_CancelAndDispatch_Success() public {
        (BatchClaim memory claim,,,, bytes32 mandateHash, bytes32 claimHash) = _setupFill();

        uint256 targetChainId = 10; // Optimism
        bytes memory context = abi.encode("cancel dispatch");

        // Set up expected values with zero amounts (cancelled)
        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = 0; // Cancelled, so zero amounts

        dispatchTarget.setExpectedValues(
            targetChainId,
            claim.compact,
            mandateHash,
            claimHash,
            bytes32(uint256(uint160(sponsor))), // Sponsor is claimant for cancel
            0, // Scaling factor is 0 for cancelled claims
            expectedAmounts,
            context
        );

        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: targetChainId,
            target: address(dispatchTarget),
            value: 0.1 ether,
            context: context
        });

        // Expect the Dispatch event
        vm.expectEmit(true, true, true, true);
        emit Dispatch(
            address(dispatchTarget), targetChainId, bytes32(uint256(uint160(sponsor))), claimHash
        );

        vm.prank(sponsor);
        tribunal.cancelAndDispatch{value: 0.1 ether}(claim.compact, mandateHash, dispatchParams);

        assertTrue(dispatchTarget.callbackCalled());
        assertEq(dispatchTarget.receivedChainId(), targetChainId);
        assertEq(dispatchTarget.receivedValue(), 0.1 ether);
    }

    function test_CancelThenDispatch_Success() public {
        (BatchClaim memory claim,,,, bytes32 mandateHash, bytes32 claimHash) = _setupFill();

        // First cancel
        vm.prank(sponsor);
        tribunal.cancel(claim.compact, mandateHash);

        // Then dispatch
        uint256 targetChainId = 8453; // Base
        bytes memory context = abi.encode("post cancel dispatch");

        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = 0;

        dispatchTarget.setExpectedValues(
            targetChainId,
            claim.compact,
            mandateHash,
            claimHash,
            bytes32(uint256(uint160(sponsor))),
            0,
            expectedAmounts,
            context
        );

        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: targetChainId, target: address(dispatchTarget), value: 0, context: context
        });

        // Expect the Dispatch event
        vm.expectEmit(true, true, true, true);
        emit Dispatch(
            address(dispatchTarget), targetChainId, bytes32(uint256(uint160(sponsor))), claimHash
        );

        vm.prank(sponsor);
        tribunal.dispatch(claim.compact, mandateHash, dispatchParams);

        assertTrue(dispatchTarget.callbackCalled());
        assertEq(dispatchTarget.receivedChainId(), targetChainId);
    }

    function test_FillAndDispatch_RevertsOnCallbackRevert() public {
        (
            BatchClaim memory claim,
            FillParameters memory fill,
            Adjustment memory adjustment,
            bytes32[] memory fillHashes,
            ,
            bytes32 claimHash
        ) = _setupFill();

        bytes memory adjustmentSignature = _signAdjustment(adjustment, claimHash);

        // Set mock to revert
        dispatchTarget.setMode(MockDispatchTarget.Mode.Revert);

        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: 1, target: address(dispatchTarget), value: 0, context: ""
        });

        vm.prank(address(filler));
        token.approve(address(tribunal), type(uint256).max);

        adjustment.adjustmentAuthorization = adjustmentSignature;

        vm.prank(address(filler));
        vm.expectRevert("MockDispatchTarget: forced revert");
        tribunal.fillAndDispatch(
            claim.compact,
            fill,
            adjustment,
            fillHashes,
            bytes32(uint256(uint160(address(filler)))),
            0,
            dispatchParams
        );
    }

    function test_FillAndDispatch_RevertsOnWrongSelector() public {
        (
            BatchClaim memory claim,
            FillParameters memory fill,
            Adjustment memory adjustment,
            bytes32[] memory fillHashes,
            ,
            bytes32 claimHash
        ) = _setupFill();

        bytes memory adjustmentSignature = _signAdjustment(adjustment, claimHash);

        // Set mock to return wrong selector
        dispatchTarget.setMode(MockDispatchTarget.Mode.WrongSelector);

        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: 1, target: address(dispatchTarget), value: 0, context: ""
        });

        vm.prank(address(filler));
        token.approve(address(tribunal), type(uint256).max);

        adjustment.adjustmentAuthorization = adjustmentSignature;

        vm.prank(address(filler));
        vm.expectRevert(ITribunal.InvalidDispatchCallback.selector);
        tribunal.fillAndDispatch(
            claim.compact,
            fill,
            adjustment,
            fillHashes,
            bytes32(uint256(uint160(address(filler)))),
            0,
            dispatchParams
        );
    }

    function test_Dispatch_RevertsOnCallbackRevert() public {
        (
            BatchClaim memory claim,
            FillParameters memory fill,
            Adjustment memory adjustment,
            bytes32[] memory fillHashes,
            bytes32 mandateHash,
            bytes32 claimHash
        ) = _setupFill();

        bytes memory adjustmentSignature = _signAdjustment(adjustment, claimHash);

        vm.prank(address(filler));
        token.approve(address(tribunal), type(uint256).max);

        adjustment.adjustmentAuthorization = adjustmentSignature;

        // Perform fill first
        vm.prank(address(filler));
        tribunal.fill(
            claim.compact,
            fill,
            adjustment,
            fillHashes,
            bytes32(uint256(uint160(address(filler)))),
            0
        );

        // Reset and set mock to revert
        dispatchTarget.reset();
        dispatchTarget.setMode(MockDispatchTarget.Mode.Revert);

        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: 1, target: address(dispatchTarget), value: 0, context: ""
        });

        vm.prank(address(filler));
        vm.expectRevert("MockDispatchTarget: forced revert");
        tribunal.dispatch(claim.compact, mandateHash, dispatchParams);
    }

    function test_Dispatch_RevertsOnWrongSelector() public {
        (
            BatchClaim memory claim,
            FillParameters memory fill,
            Adjustment memory adjustment,
            bytes32[] memory fillHashes,
            bytes32 mandateHash,
            bytes32 claimHash
        ) = _setupFill();

        bytes memory adjustmentSignature = _signAdjustment(adjustment, claimHash);

        vm.prank(address(filler));
        token.approve(address(tribunal), type(uint256).max);

        adjustment.adjustmentAuthorization = adjustmentSignature;

        // Perform fill first
        vm.prank(address(filler));
        tribunal.fill(
            claim.compact,
            fill,
            adjustment,
            fillHashes,
            bytes32(uint256(uint160(address(filler)))),
            0
        );

        // Reset and set mock to return wrong selector
        dispatchTarget.reset();
        dispatchTarget.setMode(MockDispatchTarget.Mode.WrongSelector);

        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: 1, target: address(dispatchTarget), value: 0, context: ""
        });

        vm.prank(address(filler));
        vm.expectRevert(ITribunal.InvalidDispatchCallback.selector);
        tribunal.dispatch(claim.compact, mandateHash, dispatchParams);
    }

    function test_CancelAndDispatch_RevertsOnWrongSelector() public {
        (BatchClaim memory claim,,,, bytes32 mandateHash,) = _setupFill();

        // Set mock to return wrong selector
        dispatchTarget.setMode(MockDispatchTarget.Mode.WrongSelector);

        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: 1, target: address(dispatchTarget), value: 0, context: ""
        });

        vm.prank(sponsor);
        vm.expectRevert(ITribunal.InvalidDispatchCallback.selector);
        tribunal.cancelAndDispatch(claim.compact, mandateHash, dispatchParams);
    }

    function test_FillAndDispatch_ReturnsExcessETH() public {
        (
            BatchClaim memory claim,
            FillParameters memory fill,
            Adjustment memory adjustment,
            bytes32[] memory fillHashes,
            bytes32 mandateHash,
            bytes32 claimHash
        ) = _setupFill();

        bytes memory adjustmentSignature = _signAdjustment(adjustment, claimHash);

        // Set up expected values in the mock
        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = 100e18;

        uint256 targetChainId = 42161; // Arbitrum
        bytes memory context = abi.encode("test context");

        dispatchTarget.setExpectedValues(
            targetChainId,
            claim.compact,
            mandateHash,
            claimHash,
            bytes32(uint256(uint160(address(filler)))),
            1e18, // No reduction
            expectedAmounts,
            context
        );

        // Dispatch target will receive 0.5 ether, but we send 2 ether to tribunal
        // The excess 1.5 ether should be returned to filler
        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: targetChainId,
            target: address(dispatchTarget),
            value: 0.5 ether,
            context: context
        });

        vm.prank(address(filler));
        token.approve(address(tribunal), type(uint256).max);

        adjustment.adjustmentAuthorization = adjustmentSignature;

        // Record filler's balance before
        uint256 fillerBalanceBefore = address(filler).balance;

        // Send 2 ether, but only 0.5 ether will be used by dispatch callback
        vm.prank(address(filler));
        tribunal.fillAndDispatch{
            value: 2 ether
        }(
            claim.compact,
            fill,
            adjustment,
            fillHashes,
            bytes32(uint256(uint160(address(filler)))),
            0,
            dispatchParams
        );

        // Verify callback was called with correct value
        assertTrue(dispatchTarget.callbackCalled());
        assertEq(dispatchTarget.receivedValue(), 0.5 ether);

        // Verify excess ETH (1.5 ether) was returned to filler
        uint256 fillerBalanceAfter = address(filler).balance;
        assertEq(fillerBalanceAfter, fillerBalanceBefore - 0.5 ether, "Excess ETH not returned");
    }

    function test_Dispatch_ReturnsExcessETH() public {
        (
            BatchClaim memory claim,
            FillParameters memory fill,
            Adjustment memory adjustment,
            bytes32[] memory fillHashes,
            bytes32 mandateHash,
            bytes32 claimHash
        ) = _setupFill();

        bytes memory adjustmentSignature = _signAdjustment(adjustment, claimHash);

        vm.prank(address(filler));
        token.approve(address(tribunal), type(uint256).max);

        adjustment.adjustmentAuthorization = adjustmentSignature;

        // First, perform the fill
        vm.prank(address(filler));
        tribunal.fill(
            claim.compact,
            fill,
            adjustment,
            fillHashes,
            bytes32(uint256(uint160(address(filler)))),
            0
        );

        // Now dispatch separately with excess ETH
        uint256 targetChainId = 137; // Polygon
        bytes memory context = abi.encode("separate dispatch");

        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = 100e18;

        dispatchTarget.reset();
        dispatchTarget.setExpectedValues(
            targetChainId,
            claim.compact,
            mandateHash,
            claimHash,
            bytes32(uint256(uint160(address(filler)))),
            1e18,
            expectedAmounts,
            context
        );

        // Dispatch target will receive 0.3 ether, but we send 1 ether to tribunal
        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: targetChainId,
            target: address(dispatchTarget),
            value: 0.3 ether,
            context: context
        });

        // Record filler's balance before
        uint256 fillerBalanceBefore = address(filler).balance;

        // Send 1 ether, but only 0.3 ether will be used
        vm.prank(address(filler));
        tribunal.dispatch{value: 1 ether}(claim.compact, mandateHash, dispatchParams);

        assertTrue(dispatchTarget.callbackCalled());
        assertEq(dispatchTarget.receivedValue(), 0.3 ether);

        // Verify excess ETH (0.7 ether) was returned to filler
        uint256 fillerBalanceAfter = address(filler).balance;
        assertEq(fillerBalanceAfter, fillerBalanceBefore - 0.3 ether, "Excess ETH not returned");
    }

    function test_CancelAndDispatch_ReturnsExcessETH() public {
        (BatchClaim memory claim,,,, bytes32 mandateHash, bytes32 claimHash) = _setupFill();

        uint256 targetChainId = 10; // Optimism
        bytes memory context = abi.encode("cancel dispatch");

        // Set up expected values with zero amounts (cancelled)
        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = 0; // Cancelled, so zero amounts

        dispatchTarget.setExpectedValues(
            targetChainId,
            claim.compact,
            mandateHash,
            claimHash,
            bytes32(uint256(uint160(sponsor))), // Sponsor is claimant for cancel
            0, // Scaling factor is 0 for cancelled claims
            expectedAmounts,
            context
        );

        // Dispatch target will receive 0.2 ether, but we send 1.5 ether to tribunal
        DispatchParameters memory dispatchParams = DispatchParameters({
            chainId: targetChainId,
            target: address(dispatchTarget),
            value: 0.2 ether,
            context: context
        });

        // Record sponsor's balance before
        uint256 sponsorBalanceBefore = sponsor.balance;

        // Send 1.5 ether, but only 0.2 ether will be used
        vm.prank(sponsor);
        tribunal.cancelAndDispatch{value: 1.5 ether}(claim.compact, mandateHash, dispatchParams);

        assertTrue(dispatchTarget.callbackCalled());
        assertEq(dispatchTarget.receivedValue(), 0.2 ether);

        // Verify excess ETH (1.3 ether) was returned to sponsor
        uint256 sponsorBalanceAfter = sponsor.balance;
        assertEq(sponsorBalanceAfter, sponsorBalanceBefore - 0.2 ether, "Excess ETH not returned");
    }
}
