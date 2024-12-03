pragma solidity ^0.8.0;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GaslessCrossChainOrder, ResolvedCrossChainOrder, IOriginSettler, Output, FillInstruction} from "./ERC7683.sol";
import {CallByUser, Call, Asset} from "./DestinationSettler.sol";

contract OriginSettler {
    using SafeERC20 for IERC20;

    // codeAddress will be set as the user's `code` on the `chainId` chain.
    struct Authorization {
        uint256 chainId;
        address codeAddress;
        uint256 nonce;
        bytes signature;
    }

    struct EIP7702AuthData {
        Authorization[] authlist;
    }

    struct InputAsset {
        IERC20 token;
        uint256 amount;
    }

    error WrongSettlementContract();
    error WrongChainId();
    error WrongOrderDataType();
    error WrongExclusiveRelayer();

    bytes32 immutable ORDER_DATA_TYPE_HASH = keccak256("TODO");

    function openFor(GaslessCrossChainOrder calldata order, bytes calldata signature, bytes calldata originFillerData)
        external
    {
        (
            ResolvedCrossChainOrder memory resolvedOrder,
            CallByUser memory calls,
            EIP7702AuthData memory authData,
            InputAsset memory inputAsset
        ) = _resolveFor(order, originFillerData);

        // TODO: Support permit2 or approve+transferFrom flow or something else?
        // // Verify Permit2 signature and pull user funds into this contract
        // _processPermit2Order(order, acrossOrderData, signature);

        // TODO: Escrow funds in this contract and release post 7755 proof of settlement? Or use some other
        // method.
        // _setEscrowedFunds(inputAsset);

        emit IOriginSettler.Open(keccak256(resolvedOrder.fillInstructions[0].originData), resolvedOrder);
    }

    function decode(bytes memory orderData)
        public
        pure
        returns (CallByUser memory calls, EIP7702AuthData memory authData, InputAsset memory asset)
    {
        return (abi.decode(orderData, (CallByUser, EIP7702AuthData, InputAsset)));
    }

    function _resolveFor(GaslessCrossChainOrder calldata order, bytes calldata fillerData)
        internal
        view
        returns (
            ResolvedCrossChainOrder memory resolvedOrder,
            CallByUser memory calls,
            EIP7702AuthData memory authData,
            InputAsset memory inputAsset
        )
    {
        if (order.originSettler != address(this)) {
            revert WrongSettlementContract();
        }

        if (order.originChainId != block.chainid) {
            revert WrongChainId();
        }

        if (order.orderDataType != ORDER_DATA_TYPE_HASH) {
            revert WrongOrderDataType();
        }

        // TODO: Handle fillerData
        (calls, authData, inputAsset) = decode(order.orderData);

        // Max outputs that filler should spend on destination chain.
        Output[] memory maxSpent = new Output[](1);
        maxSpent[0] = Output({
            token: _toBytes32(address(calls.asset.token)),
            amount: calls.asset.amount,
            recipient: _toBytes32(calls.user),
            chainId: calls.chainId
        });

        // Minimum outputs that must be pulled from claler on this chain.
        Output[] memory minReceived = new Output[](1);
        minReceived[0] = Output({
            token: _toBytes32(address(inputAsset.token)),
            amount: inputAsset.amount,
            recipient: _toBytes32(calls.user),
            chainId: block.chainid
        });

        FillInstruction[] memory fillInstructions = new FillInstruction[](1);
        // TODO: Decide what to set as the origin data.
        bytes memory originData = abi.encode(calls, authData);
        fillInstructions[0] = FillInstruction({
            destinationChainId: calls.chainId,
            destinationSettler: _toBytes32(address(123)), // TODO:
            originData: originData
        });

        resolvedOrder = ResolvedCrossChainOrder({
            user: order.user,
            originChainId: order.originChainId,
            openDeadline: order.openDeadline,
            fillDeadline: order.fillDeadline,
            minReceived: minReceived,
            maxSpent: maxSpent,
            fillInstructions: fillInstructions,
            orderId: keccak256(originData) // TODO: decide what to set as unique orderId.
        });
    }

    function _toBytes32(address input) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(input)));
    }
}
