// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICrossL2Prover} from "vibc-core-smart-contracts/contracts/interfaces/ICrossL2Prover.sol";

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
import {Bytes} from "optimism/packages/contracts-bedrock/src/libraries/Bytes.sol";

contract SimpleOriginSettler is ReentrancyGuard {
    error WrongSettlementContract();
    error WrongChainId();
    error OrderAlreadyPending();
    error InsufficientValue();
    error invalidEventSender();
    error invalidCounterpartyEvent();

    event OrderExecuted(bytes32 indexed orderId); // Event emitted by destination settler on fill
    event FillerRepaid(bytes32 indexed orderId);

    // Maps orderId to ETH amount that will be paid to filler
    mapping(bytes32 => uint256) public pendingRewards;

    address public immutable DESTINATION_SETTLER;
    ICrossL2Prover immutable CROSS_L2_PROVER;

    constructor(address destinationSettler_, ICrossL2Prover crossL2Prover_) {
        // NB: This is for testing purposes only. In production, the destination settler should 
        // be passed in as a part of the order.
        DESTINATION_SETTLER = destinationSettler_;
        CROSS_L2_PROVER = crossL2Prover_;
    }

    /**
     * @notice Opens a cross-chain order where user directly signs and submits
     * @param callsByUser The user's cross-chain calls and metadata
     */
    function open(CallByUser calldata callsByUser) external payable nonReentrant {
        if (msg.value == 0) revert InsufficientValue();

        // Create CallByUser struct for destination chain
        bytes32 orderId = ResolvedCrossChainOrderLib.getOrderId(callsByUser);

        if (pendingRewards[orderId] > 0) revert OrderAlreadyPending();
        pendingRewards[orderId] = msg.value;

        // Create and emit the resolved order
        ResolvedCrossChainOrder memory resolvedOrder = _createResolvedOrder(
            msg.sender,
            callsByUser,
            msg.value
        );

        emit IOriginSettler.Open(keccak256(abi.encode(callsByUser)), resolvedOrder);
    }

    /**
     * @notice Repays the filler after they complete the order on destination chain
     * @param orderId The unique identifier of the completed order
     * @param filler Address of the filler to repay
     * @param proof Proof of fill completion on destination chain
     */
    function repayFiller(bytes32 orderId, address filler, uint256 logIndex, bytes calldata proof)
        external
        nonReentrant
    {
        uint256 reward = pendingRewards[orderId];
        require(reward > 0, "Order not found or already repaid");

        // First we fetch the event at the log index and proof from the verifier contract
        (string memory proofChainId, address emittingContract, bytes[] memory topics, bytes memory unindexedData) =
            CROSS_L2_PROVER.validateEvent(logIndex, proof);

        // Now we validate that the event itself was emitted from the destination settler address in the form emit OrderExecuted(orderId);.

        // NB: we'd usually need to validate the chainId but we can skip it in this example 
        // since we're only dealing with one counterparty chain.
        if (emittingContract != DESTINATION_SETTLER) {
            // This check prevents addresses spoofing the destination settler to emit
            revert invalidEventSender();
        }

        // Verify that an event was emitted in the source contract with the orderID.
        bytes[] memory expectedTopics = new bytes[](2);
        expectedTopics[0] = bytes.concat(OrderExecuted.selector);
        expectedTopics[1] = bytes.concat(orderId);

        if (!Bytes.equal(abi.encode(topics), abi.encode(expectedTopics))) {
            revert invalidCounterpartyEvent();
        }

        // There should be no additional data in this event since all args are indexed
        if (!Bytes.equal(unindexedData, hex"")) {
            revert invalidCounterpartyEvent();
        }

        delete pendingRewards[orderId];

        (bool success,) = filler.call{value: reward}("");
        require(success, "ETH transfer failed");

        emit FillerRepaid(orderId);
    }

    function _createResolvedOrder(
        address user,
        CallByUser memory calls,
        uint256 rewardAmount
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
            destinationChainId: uint64(calls.chainId),
            destinationSettler: _toBytes32(DESTINATION_SETTLER),
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
