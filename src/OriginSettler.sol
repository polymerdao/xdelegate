pragma solidity ^0.8.0;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GaslessCrossChainOrder, ResolvedCrossChainOrder, IOriginSettler, Output, FillInstruction} from "./ERC7683.sol";
import {EIP7702AuthData, CallByUser, Call, Asset} from "./Structs.sol";
import {IPermit2} from "./IPermit2.sol";
import {ERC7683Permit2Lib} from "./ERC7683Permit2Lib.sol";

contract OriginSettler {
    using SafeERC20 for IERC20;

    IPermit2 public immutable PERMIT2 = IPermit2(address(0xf00d));

    error WrongSettlementContract();
    error WrongChainId();
    error WrongOrderDataType();
    error WrongExclusiveRelayer();

    event Requested7702Delegation(EIP7702AuthData authData);

    bytes32 immutable ORDER_DATA_TYPE_HASH = keccak256("TODO");

    mapping(bytes32 => Asset) public pendingOrders;

    // @dev We don't use the last parameter `originFillerData` in this function.
    function openFor(GaslessCrossChainOrder calldata order, bytes calldata permit2Signature, bytes calldata) external {
        (
            ResolvedCrossChainOrder memory resolvedOrder,
            CallByUser memory calls,
            EIP7702AuthData memory authData,
            Asset memory inputAsset
        ) = _resolveFor(order);

        // Verify Permit2 signature and pull user funds into this contract. The signature should include
        // the UserOp and any prerequisite EIP7702 delegation authorizations as witness data so we will doubly
        // verify the user signed the data to be emitted as originData.
        _processPermit2Order(order, calls, authData, inputAsset, permit2Signature);

        // TODO: Permit2 will pull assets into this contract, and they should only be releaseable to the filler
        // on this chain once a proof of fill is submitted in a separate function. Ideally we can use RIP7755
        // to implement the storage proof escrow system.
        require(pendingOrders[resolvedOrder.orderId].amount > 0, "Order already pending");
        pendingOrders[resolvedOrder.orderId] = inputAsset;

        // If a 7702 delegation is a prerequisite to executing the user's calldata on the destination chain,
        // emit the authData here.
        if (authData.authlist.length > 0) {
            emit Requested7702Delegation(authData);
        }

        // The OpenEvent contains originData which is required to make the destination chain fill, so we only
        // emit the user calls.
        emit IOriginSettler.Open(keccak256(resolvedOrder.fillInstructions[0].originData), resolvedOrder);
    }

    function decode7683OrderData(bytes memory orderData)
        public
        pure
        returns (CallByUser memory calls, EIP7702AuthData memory authData, Asset memory asset)
    {
        return (abi.decode(orderData, (CallByUser, EIP7702AuthData, Asset)));
    }

    function _resolveFor(GaslessCrossChainOrder calldata order)
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

        (calls, authData, inputAsset) = decode7683OrderData(order.orderData);

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

        // OriginData will be included on destination chain fill() and it should contain the data needed to execute the
        // user's intended call. We don't include the authData here as the calldata execution will revert if the
        // authData isn't submitted as a prerequisite to delegate the user's code. Instead, we emit the authData
        // in this contract so that the filler submitting the destination chain calldata can use it.
        bytes memory originData = abi.encode(calls);
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
            orderId: _getOrderId(calls)
        });
    }

    // This needs to be a unique representation of the user op. The CallByUser struct contains a nonce
    // so the user can guarantee this order is unique by using the nonce+user combination.
    function _getOrderId(CallByUser memory calls) internal pure returns (bytes32) {
        return keccak256(abi.encode(calls));
    }

    function _processPermit2Order(
        GaslessCrossChainOrder memory order,
        CallByUser memory calls,
        EIP7702AuthData memory authData,
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

        // Pull user funds into this contract.
        PERMIT2.permitWitnessTransferFrom(
            permit,
            signatureTransferDetails,
            order.user,
            // User should have signed a permit2 blob including the destination chain UserOp and any prerequisite
            // EIP7702 delegation authorizations.
            ERC7683Permit2Lib.hashOrder(
                order, ERC7683Permit2Lib.hashUserCallData(calls), ERC7683Permit2Lib.hashAuthData(authData)
            ), // witness data hash
            ERC7683Permit2Lib.PERMIT2_ORDER_TYPE, // witness data type string
            signature
        );
    }

    function _toBytes32(address input) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(input)));
    }
}
