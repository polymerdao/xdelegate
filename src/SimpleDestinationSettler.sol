// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Call, CallByUser} from "./Structs.sol";
import {GaslessCrossChainOrder} from "./ERC7683.sol";
import {ResolvedCrossChainOrderLib} from "./ResolvedCrossChainOrderLib.sol";

/**
 * @notice Minimal destination chain contract that only executes user calls
 * @dev This is a bare-bones version that skips verification, funding, and delegation logic
 */
contract SimpleDestinationSettler {
    error CallReverted(uint256 index, Call[] calls);
    error InvalidCall(uint256 index, Call[] calls);
    error InvalidOrderId();
    error OrderAlreadyFilled();

    event OrderExecuted(bytes32 indexed orderId);

    // Track which orders have been filled
    mapping(bytes32 => bool) public filledOrders;

    /**
     * @notice Fills an ERC-7683 order by executing the user's calls
     * @param orderId The unique identifier of the order
     * @param originData The encoded CallByUser data from the origin chain
     */
    function fill(bytes32 orderId, bytes calldata originData) external {
        (CallByUser memory callsByUser) = abi.decode(originData, (CallByUser));
        if (ResolvedCrossChainOrderLib.getOrderId(callsByUser) != orderId) revert InvalidOrderId();

        // Check if order has already been filled
        if (filledOrders[orderId]) revert OrderAlreadyFilled();

        // Execute the calls directly without any additional checks
        _attemptCalls(callsByUser.calls);

        // Emit event that can be proven on origin chain
        emit OrderExecuted(orderId);

        // Mark order as filled before execution to prevent reentrancy
        filledOrders[orderId] = true;
    }

    function _attemptCalls(Call[] memory calls) internal {
        for (uint256 i = 0; i < calls.length; ++i) {
            Call memory call = calls[i];

            // Basic check to ensure we're not calling an EOA with calldata
            if (call.callData.length > 0 && call.target.code.length == 0) {
                revert InvalidCall(i, calls);
            }

            (bool success,) = call.target.call{value: call.value}(call.callData);
            if (!success) revert CallReverted(i, calls);
        }
    }

    // Allow contract to receive native token
    receive() external payable {}
} 