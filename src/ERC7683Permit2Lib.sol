// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./OriginSettler.sol";
import "./DestinationSettler.sol";
import "./IPermit2.sol";
import {GaslessCrossChainOrder} from "./ERC7683.sol";

bytes constant CALL_BY_USER_TYPE = abi.encodePacked(
    "CallByUser(", "address user,", "Asset asset,", "uint64 chainId,", "bytes32 delegateCodeHash,", "Call[] calls)"
);

bytes constant CALL_TYPE = abi.encodePacked("Call(", "address target,", "bytes callData,", "uint256 value)");

bytes constant ASSET_TYPE = abi.encodePacked("Asset(", "address token,", "uint256 amount)");

bytes32 constant CALL_BY_USER_TYPE_HASH = keccak256(CALL_BY_USER_TYPE);

library ERC7683Permit2Lib {
    bytes internal constant GASLESS_CROSS_CHAIN_ORDER_TYPE = abi.encodePacked(
        "GaslessCrossChainOrder(",
        "address originSettler,",
        "address user,",
        "uint256 nonce,",
        "uint256 originChainId,",
        "uint32 openDeadline,",
        "uint32 fillDeadline,",
        "bytes32 orderDataType,",
        "CallByUser orderData)"
    );

    bytes internal constant GASLESS_CROSS_CHAIN_ORDER_EIP712_TYPE =
        abi.encodePacked(GASLESS_CROSS_CHAIN_ORDER_TYPE, CALL_BY_USER_TYPE, CALL_TYPE, ASSET_TYPE);
    bytes32 internal constant GASLESS_CROSS_CHAIN_ORDER_TYPE_HASH = keccak256(GASLESS_CROSS_CHAIN_ORDER_EIP712_TYPE);

    string private constant TOKEN_PERMISSIONS_TYPE = "TokenPermissions(address token,uint256 amount)";
    string internal constant PERMIT2_ORDER_TYPE = string(
        abi.encodePacked(
            "GaslessCrossChainOrder witness)", CALL_BY_USER_TYPE, GASLESS_CROSS_CHAIN_ORDER_TYPE, TOKEN_PERMISSIONS_TYPE
        )
    );

    // Hashes an order to get an order hash. Needed for permit2.
    function hashOrder(GaslessCrossChainOrder memory order, bytes32 orderDataHash) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                GASLESS_CROSS_CHAIN_ORDER_TYPE_HASH,
                order.originSettler,
                order.user,
                order.nonce,
                order.originChainId,
                order.openDeadline,
                order.fillDeadline,
                order.orderDataType,
                orderDataHash
            )
        );
    }

    function hashUserCallData(CallByUser memory userCallData) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                CALL_BY_USER_TYPE_HASH,
                userCallData.user,
                userCallData.asset,
                userCallData.chainId,
                userCallData.delegateCodeHash,
                userCallData.calls
            )
        );
    }
}
