pragma solidity ^0.8.0;

 interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function forceApprove(address spender, uint256 amount) external returns (bool);
 }


/**
 * @notice Destination chain entrypoint contract for fillers relaying cross chain message containing 7702 delegated
 * calldata.
 * @dev This is a simple pass-through contract that is encouraged to be modified by different xchain settlement systems
 * that might want to add features such as exclusive filling, deadlines, fee-collection, etc.
 * @dev This could be replaced by the Across SpokePool, for example, which would then delegate execution
 * to the XAccount contract that the user trusts.
 */
 contract Outbox {
    address xAccount = address(123456789);

    struct Asset {
        IERC20 token;
        uint256 amount;
    }
    struct Call {
        address target;
        bytes callData;
    }
    struct CallByUser {
        address user; // User who delegated calldata and funded assets on origin chain.
        Asset[] assets; // token & amount, used to fund execution of calldata
        Call[] calls; // calldata to execute 
    }

    function fundUserAndApproveXAccount(CallByUser memory call) public {
        for (uint i = 0; i < call.assets.length; i++) {
            call.assets[i].token.transferFrom(msg.sender, xAccount, call.assets[i].amount);
            call.assets[i].token.forceApprove(xAccount, call.assets[i].amount);
        }
    }

    function fill(
        address userPublicKey,
        bytes calldata signature,
        CallByUser memory callsByUser
    ) external {
        fundUserAndApproveXAccount(callsByUser);

        // TODO: Protect against duplicate fills.
        // require(!fillhash, "Already filled");
        // fills[fillhash] = true;

        // execute calls
        XAccount(callsByUser.user).xExecute(
                userPublicKey,
                callsByUser,
                signature
            );
        // emit Executed(...) // this gets picked up on sending chain via receipt proof 
    }
}

/**
 * @notice Singleton contract used by all users who want to sign data on origin chain and delegate execution of 
 * their calldata on this chain to this contract. 
 * @dev User must trust that this contract does what it they want it to do.
 */
contract XAccount {
    error NotSelf();
    error CallReverted(uint256 index, Outbox.Call[] calls);

    modifier onlySelf() {
        _requireSelf();
        _;
    }

    // Entrypoint function to be called by Outbox contract on this chain. Should pull funds from Outbox
    // to user and then execute calldata. Assume user has 7702-delegated msg.sender already to this contract.
    function xExecute(
        address publicKey,
        Outbox.CallByUser memory callByUser,
        bytes calldata signature
    ) external {
        _verify(publicKey, signature, callByUser);
        _fundUser(callByUser);
        _attemptCalls(callByUser.calls);
    }

    function _verify(
        address publicKey,
        bytes calldata signature,
        Outbox.CallByUser memory callByUser
    ) internal view returns (bool) {
        // verify signature by user emitted on origin chain over calls & assets
        return true;
    }

    function _attemptCalls(Outbox.Call[] memory calls) internal onlySelf {
        for (uint256 i = 0; i < calls.length; ++i) {

            // TODO: Validate target

            // TODO: Handle msg.value
            (bool success, ) = calls[i].target.call(calls[i].callData);
            if (!success) revert CallReverted(i, calls);
        }
    }

    // Pulls tokens from settlement contract to user. We assume user has delegated execution to this contract
    // via EIP7702.
    function _fundUser(Outbox.CallByUser memory call) internal {
        for (uint i = 0; i < call.assets.length; i++) {
            call.assets[i].token.transferFrom(msg.sender, call.user, call.assets[i].amount);
        }
    }

    function _requireSelf() internal view {
        // Must be called by this contract to ensure that this cannot be triggered without the explicit consent of the
        // depositor (for a valid relay).
        if (msg.sender != address(this)) revert NotSelf();
    }
}