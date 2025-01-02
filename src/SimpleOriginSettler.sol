// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    OnchainCrossChainOrder,
    GaslessCrossChainOrder,
    ResolvedCrossChainOrder,
    IOriginSettler,
    Output,
    FillInstruction
} from "./ERC7683.sol";
import {CallByUser, Call, Asset} from "./Structs.sol";
import {ResolvedCrossChainOrderLib} from "./ResolvedCrossChainOrderLib.sol";

contract SimpleOriginSettler is ReentrancyGuard {
    error WrongSettlementContract();
    error WrongChainId();
    error OrderAlreadyPending();
    error InsufficientValue();

    // Maps orderId to ETH amount that will be paid to filler
    mapping(bytes32 => uint256) public pendingRewards;

    /**
     * @notice Opens a cross-chain order where user directly signs and submits
     * @param destinationChainId The chain ID where the calls should be executed
     * @param destinationCalls Array of calls to execute on destination chain
     * @param destinationSettler Address of the settler contract on destination chain
     */
    function open(
        uint256 destinationChainId,
        Call[] calldata destinationCalls,
        address destinationSettler
    ) external payable nonReentrant {
        if (msg.value == 0) revert InsufficientValue();

        // Create CallByUser struct for destination chain
        CallByUser memory calls = CallByUser({
            user: msg.sender,
            chainId: uint64(destinationChainId),
            calls: destinationCalls,
            asset: Asset({token: address(0), amount: 0}), // No asset required on destination
            nonce: 0,
            signature: "" // No signature needed since msg.sender is user
        });

        bytes32 orderId = ResolvedCrossChainOrderLib.getOrderId(calls);
        
        if (pendingRewards[orderId] > 0) revert OrderAlreadyPending();
        pendingRewards[orderId] = msg.value;

        // Create and emit the resolved order
        ResolvedCrossChainOrder memory resolvedOrder = _createResolvedOrder(
            msg.sender,
            destinationChainId,
            calls,
            msg.value,
            destinationSettler
        );

        emit IOriginSettler.Open(keccak256(abi.encode(calls)), resolvedOrder);
    }

    /**
     * @notice Repays the filler after they complete the order on destination chain
     * @param orderId The unique identifier of the completed order
     * @param filler Address of the filler to repay
     * @param proof Proof of fill completion on destination chain
     */
    function repayFiller(bytes32 orderId, address filler, bytes calldata proof) external nonReentrant {
        // TODO: Verify proof of destination chain fill

        uint256 reward = pendingRewards[orderId];
        require(reward > 0, "Order not found or already repaid");
        
        delete pendingRewards[orderId];
        
        (bool success,) = filler.call{value: reward}("");
        require(success, "ETH transfer failed");
    }

    function _createResolvedOrder(
        address user,
        uint256 destinationChainId,
        CallByUser memory calls,
        uint256 rewardAmount,
        address destinationSettler
    ) internal view returns (ResolvedCrossChainOrder memory) {
        // Only minReceived is relevant - what filler gets paid in ETH
        Output[] memory minReceived = new Output[](1);
        minReceived[0] = Output({
            token: bytes32(0), // Zero address for ETH
            amount: rewardAmount,
            recipient: bytes32(0), // Will be set to actual filler address
            chainId: block.chainid
        });

        // No maxSpent since filler doesn't need to provide tokens
        Output[] memory maxSpent = new Output[](0);

        // Create fill instructions
        FillInstruction[] memory fillInstructions = new FillInstruction[](1);
        fillInstructions[0] = FillInstruction({
            destinationChainId: uint64(destinationChainId),
            destinationSettler: _toBytes32(destinationSettler),
            originData: abi.encode(calls)
        });

        return ResolvedCrossChainOrder({
            user: user,
            originChainId: block.chainid,
            openDeadline: type(uint32).max,
            fillDeadline: type(uint32).max,
            minReceived: minReceived,
            maxSpent: maxSpent,
            fillInstructions: fillInstructions,
            orderId: ResolvedCrossChainOrderLib.getOrderId(calls)
        });
    }

    function _toBytes32(address input) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(input)));
    }

    // Allow contract to receive ETH
    receive() external payable {}
} 