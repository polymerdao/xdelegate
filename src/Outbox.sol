pragma solidity ^0.8.0;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";


 interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function forceApprove(address spender, uint256 amount) external returns (bool);
 }


/**
 * @notice Destination chain entrypoint contract for fillers relaying cross chain message containing delegated
 * calldata.
 * @dev This is a simple escrow contract that is encouraged to be modified by different xchain settlement systems
 * that might want to add features such as exclusive filling, deadlines, fee-collection, etc.
 * @dev This could be replaced by the Across SpokePool, for example, which gives fillers many features with which
 * to protect themselves from malicious users and moreover allows them to provide transparent pricing to users.
 * However, this contract could be bypassed almost completely by lightweight settlement systems that could essentially
 * combine its logic with the XAccount contract to avoid the extra transferFrom and approve steps required in a more
 * complex escrow system.
 */
 contract Outbox {
    // The address of the singleton XAccount contract that users have set as their delegate code.
    address public xAccount = address(2);

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
        Asset asset; // token & amount, used to fund execution of calldata
        Call[] calls; // calldata to execute 
    }

    // Pull funds into this settlement contract as escrow and use to execute user's calldata. Escrowed
    // funds will be paid back to filler after this contract successfully verifies the settled intent.
    // This step could be skipped by lightweight escrow systems that don't need to perform additional
    // validation on the filler's actions.
    function fundUserAndApproveXAccount(CallByUser memory call) public {
        // TODO: Link the escrowed funds back to the user in case the delegation step fails, we don't want
        // user to lose access to funds.
        call.asset.token.transferFrom(msg.sender, address(this), call.asset.amount);
        call.asset.token.forceApprove(xAccount, call.asset.amount);
    }

    // Called by filler, who sees ERC7683 intent emitted on origin chain
    // containing the callsByUser data to be executed following a 7702 delegation.
    function fill(
        address publicKey,
        bytes calldata signature,
        CallByUser memory callsByUser,
        bytes32 signedCallDataHash
    ) external {
        // Pull funds into this settlement contract and perform any steps necessary to ensure that filler
        // receives a refund of their assets.
        fundUserAndApproveXAccount(callsByUser);

        // TODO: Protect against duplicate fills.
        // require(!signedCallDataHash, "Already filled");
        // fills[signedCallDataHash] = true;

        // TODO: Protect fillers from collisions with other fillers.

        // The following call will only succeed if the user has set a 7702 authorization to set its code 
        // equal to the XAccount contract. The filler should have
        // seen the calldata emitted in an `Open` ERC7683 event on the sending chain.
        XAccount(callsByUser.user).xExecute(
                publicKey,
                callsByUser,
                signature,
                signedCallDataHash
            );

        // Perform any final steps required to prove that filler has successfully filled the ERC7683 intent.
        // e.g. emit Executed(...) // this gets picked up on sending chain via receipt proof 
    }
}

/**
 * @notice Singleton contract used by all users who want to sign data on origin chain and delegate execution of 
 * their calldata on this chain to this contract. 
 * @dev User must trust that this contract's logic.
 */
contract XAccount {
    error CallReverted(uint256 index, Outbox.Call[] calls);

    // Entrypoint function to be called by Outbox contract on this chain. Should pull funds from Outbox
    // to user's EOA and then execute calldata that will have it msg.sender = user EOA. 
    // Assume user has 7702-delegated code already to this contract.
    function xExecute(
        address publicKey,
        Outbox.CallByUser memory callByUser,
        bytes calldata signature,
        bytes32 signedCallDataHash
    ) external {
        _verify(publicKey, signature, signedCallDataHash);
        _fundUser(callByUser);
        _attemptCalls(callByUser.calls);
    }

    function _verify(
        address publicKey,
        bytes calldata signature,
        bytes32 signedCallDataHash
    ) internal view returns (bool) {
        // TODO: Verify signed call data hash includes both the expected callByUser data.
        return SignatureChecker.isValidSignatureNow(publicKey, signedCallDataHash, signature);
    }

    function _attemptCalls(Outbox.Call[] memory calls) internal {
        for (uint256 i = 0; i < calls.length; ++i) {

            // TODO: Validate target

            // TODO: Handle msg.value
            (bool success, ) = calls[i].target.call(calls[i].callData);
            if (!success) revert CallReverted(i, calls);
        }
    }

    function _fundUser(Outbox.CallByUser memory call) internal {
        call.asset.token.transferFrom(msg.sender, call.user, call.asset.amount);
    }
}