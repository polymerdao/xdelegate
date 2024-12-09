# Motivation

This repository demonstrates how EIP7702 can allow a user to delegate a cross chain action via an ERC7683 order.

## Summary

[ERC7683](https://eips.ethereum.org/EIPS/eip-7683) generally supports a cross-chain user flow where the user can create an intent on an origin chain containing call data to be executed on a destination chain. This destination chain execution should be funded by assets deposited on the origin chain.

This 7683 intent can be combined with an [EIP7702](https://github.com/ethereum/EIPs/blob/master/EIPS/eip-7702.md)-compatible smart contract wallet deployed on the destination chain to allow the destination chain calldata execution to look like it was sent from the user's EOA, instead of from the smart contract wallet address.

This repository contains contracts and scripts demonstrating this flow.

## Intended cross-chain flow

1. User signs destination UserOp (`UserOp = [{calldata, target},{},...]`).
2. (optional) User signs destination 7702 delegation.
3. User creates 7683 order containing 1 & 2.
4. User sends `open` transaction on origin chain `OriginSettler`
5. Relayer sees 7683 order
6. Relayer sends fill on destination chain `DestinationSettler`
7. (optional) If fill requires user delegation to be set up, relayer must include this in their fill txn, which should be a type 4 txn.
8. Fill pulls funds from filler's account to the user’s EOA and then calls `XAccount.xExecute` on user’s EOA with the UserOp
10. **`XAccount` now executes UserOp within the context of the user's EOA** where the `msg.sender` is now set to the user's EOA and the `code` is set to the `XAccount`
11. If fill is submitted successfully and as user ordered in 7683 order, filler can get refund

## On-chain Components

- `OriginSettler`: Origin chain contract that user interacts with to open an ERC7683 cross-chain intent. The `open` function helps the user to form an ERC7683 intent correctly containing the `calldata` that the user wants to delegate to a filler to execute on the destination chain. `openFor` can be used to help a user pass their signed order to a filler off-chain and subsequently allows the filler to create the 7683 order on the user's behalf. Therefore, `openFor` allows the user to experience a totally gas-free experience from origin to destination chain.
  - The `open` functionality also optionally lets the user include a 7702 authorization that the user wants the filler to submit on-chain on their behalf. This can be used to allow the user to set the `code` of their destination chain EOA to the `XAccount` contract.
  - The 7683 order contains the destination chain calldata in a [`FillInstruction`](https://eips.ethereum.org/EIPS/eip-7683#fillerdata). If the 7702 delegation is a prerequisite for executing this calldata on the destination chain, then the filler should get the delegation data from the `OriginSettler` events.
- `DestinationSettler`: Destination chain contract that filler interacts with to fulfill a ERC7683 cross-chain intent. The `fill` function is used by the `filler` to credit the user's EOA with any assets that they had deposited on the `OriginSettler` when initiating the 7683 intent and subsequently execute any `calldata` on behalf of the user that was included in the 7683 intent.
  - The `fill` function will delegate execution of `calldata` to the `XAccount` 7702-compatible proxy contract so it is a prerequisite that the user has already set their destination chain EOA's `code` to `XAccount` via a 7702 transaction. The authorization should submitted by the user or delegated
  to the filler to set.
  - As stated above, the `OriginSettler#open` function can be used by the user to include a 7702 authorization to be submitted by the filler on the destination chain. This way the user can complete the prerequisite 7702 transaction and delegate the `calldata` execution in the same 7683 intent.
- `XAccount`: Destination chain proxy contract that users should set as their `code` via a 7702 type 4 transaction. Verifies that any calldata execution delegated to it was signed by the expected user.

## Differences between DestinationSettler.sol variants

This repository contains multiple DestinationSettler{2,3}.sol contracts that demonstrate different ways of setting up the `XAccount` smart contract wallet and how they interact with the `DestinationSettler` contract. 

The `DestinationSettler.sol` contract delegates all signature and UserOp verification to the `XAccount` wallet so that users need to only trust the `XAccount` contract and can use this wallet with any settlement system.

The `DestinationSettler2.sol` performs all signature and UserOp verification and only uses the `XAccount` wallet as a Multicaller or Multisender contract to execute the calls. This reduces gas costs compared to `DestinationSettler.sol` but it means the user needs to trust the `DestinationSettler2.sol`. There are reasons not to combine the escrow logic with the verification logic so this is offered as an alternative to `DestinationSettler.sol` which separates the concerns.

The `DestinationSettler3.sol` offers similar UX to the `DestinationSettler2.sol` in that the user must trust the settlement contract to perform verification, but this contract also performs the Multicaller duties. Its even more gas efficient than `DestinationSettler2.sol` because there is no `XAccount` contract to call.

## Off-chain components

- Relayer that will pick up 7683 order and fill it on destination.

## Security

The main architecture decision we made was whether to place the destination chain signature verification logic in the `DestinationSettler` or the `XAccount` contract. By placing this in the latter, we are implicitly encouraging there to be many different types of destination chain settlement contracts, that offer different fulfillment guarantees and features to fillers, that all delegate UserOp execution to a singleton `XAccount` contract. The user needs to trust that `XAccount` will do what its supposed to do.

The alternative would be to instead encourage that the `DestinationSettler` contract is a singleton contract that should be trusted by users. Any UserOp verification logic enforced in the settlement contract would be shared across all users. This would make the `XAccount` contract much simpler. We decided against this as the default option because we believe there are opinionated settlement contract features that would greatly improve user and filler UX but that we didn't want to include in a singleton contract.

For example, the settlement contract should ideally protect against duplicate fulfillment of the same 7683 order and simultaneously allow the user to protect fillers from colliding fill transactions. These features would require the `fill` function on the settlement contract to include parameters like `exclusiveRelayer` and enforce logic like checking if `fillStatuses[fillHash] = true`. But, we believe there are strong arguments for why these features are opinionated and do not belong in a generalized `DestinationSettler` contract.

We also think its better for users if they only need to designate a smart contract wallet they trust that can work with any settlement system, rather than have to trust each settlement system they interact with. This assumes there will be multiple settlement systems offered to users eventually.

## EIP7702 resources

[This best-practices document](https://hackmd.io/@rimeissner/eip7702-best-practices) was very useful in guiding design of `XAccount`
