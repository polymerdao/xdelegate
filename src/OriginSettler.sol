pragma solidity ^0.8.0;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GaslessCrossChainOrder, ResolvedCrossChainOrder, IOriginSettler, Output, FillInstruction} from "./ERC7683.sol";
import {CallByUser, Call, Asset} from "./DestinationSettler.sol";
import "./IPermit2.sol";
import "./ERC7683Permit2Lib.sol";

contract OriginSettler {
    using SafeERC20 for IERC20;

    IPermit2 public immutable PERMIT2 = IPermit2(address(0xf00d));

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

    error WrongSettlementContract();
    error WrongChainId();
    error WrongOrderDataType();
    error WrongExclusiveRelayer();

    bytes32 immutable ORDER_DATA_TYPE_HASH = keccak256("TODO");

    function openFor(GaslessCrossChainOrder calldata order, bytes calldata signature, bytes calldata originFillerData)
        external
    {
        // TODO: Do we need to verify that signature is the signed order so that the filler can't just pass in any
        // order data here? Or will this be implicitly handled by passing the signature into _processPermit2Order?
        (
            ResolvedCrossChainOrder memory resolvedOrder,
            CallByUser memory calls,
            EIP7702AuthData memory authData,
            Asset memory inputAsset
        ) = _resolveFor(order, originFillerData);

        // TODO: Support permit2 or approve+transferFrom flow or something else?
        // // Verify Permit2 signature and pull user funds into this contract
        _processPermit2Order(order, calls, inputAsset, signature);

        // TODO: Escrow funds in this contract and release post 7755 proof of settlement? Or use some other
        // method.
        // _setEscrowedFunds(inputAsset);

        emit IOriginSettler.Open(keccak256(resolvedOrder.fillInstructions[0].originData), resolvedOrder);
    }

    function _processPermit2Order(
        GaslessCrossChainOrder memory order,
        CallByUser memory calls,
        Asset memory inputAsset,
        bytes memory signature
    ) internal {
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({token: inputAsset.token, amount: inputAsset.amount}),
            nonce: order.nonce,
            deadline: order.openDeadline
        });

        IPermit2.SignatureTransferDetails memory signatureTransferDetails =
            IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: inputAsset.amount});

        // Pull user funds.
        PERMIT2.permitWitnessTransferFrom(
            permit,
            signatureTransferDetails,
            order.user,
            // Make sure signature includes the UserCallData. TODO: We probably need to include AuthData here too.
            ERC7683Permit2Lib.hashOrder(order, ERC7683Permit2Lib.hashUserCallData(calls)), // witness data hash
            ERC7683Permit2Lib.PERMIT2_ORDER_TYPE, // witness data type string
            signature
        );
    }

    function decode(bytes memory orderData)
        public
        pure
        returns (CallByUser memory calls, EIP7702AuthData memory authData, Asset memory asset)
    {
        return (abi.decode(orderData, (CallByUser, EIP7702AuthData, Asset)));
    }

    function _resolveFor(GaslessCrossChainOrder calldata order, bytes calldata fillerData)
        internal
        view
        returns (
            ResolvedCrossChainOrder memory resolvedOrder,
            CallByUser memory calls,
            EIP7702AuthData memory authData,
            Asset memory inputAsset
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
            token: _toBytes32(calls.asset.token),
            amount: calls.asset.amount,
            recipient: _toBytes32(calls.user),
            chainId: calls.chainId
        });

        // Minimum outputs that must be pulled from caller on this chain.
        Output[] memory minReceived = new Output[](1);
        minReceived[0] = Output({
            token: _toBytes32(inputAsset.token),
            amount: inputAsset.amount,
            recipient: _toBytes32(msg.sender), // We assume that msg.sender is filler and wants to be repaid on this chain.
            chainId: block.chainid
        });

        FillInstruction[] memory fillInstructions = new FillInstruction[](1);
        // TODO: Decide what to set as the origin data.
        bytes memory originData = abi.encode(calls, authData);
        fillInstructions[0] = FillInstruction({
            destinationChainId: calls.chainId,
            destinationSettler: _toBytes32(address(123)), // TODO: Should be address of destination settler for destination chain.
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
