// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import {OrderResponse} from "./ITokenRouterTypes.sol";

struct RedeemedFill {
    // The address of the `PlaceMarketOrder` caller on the source chain.
    bytes32 sender;
    // The chain ID of the source chain.
    uint16 senderChain;
    // The address of the USDC token that was transferred.
    address token;
    // The amount of USDC that was transferred.
    uint256 amount;
    // The arbitrary bytes message that was sent to the `redeemer` contract.
    bytes message;
}

interface IRedeemFill {
    /**
     * @notice Redeems a `Fill` or `FastFill` Wormhole message from a registered router
     * (or the `MatchingEngine` in the case of a `FastFill`). The `token` and `message`
     * are sent to the `redeemer` contract on the target chain.
     * @dev The caller must be the encoded `redeemer` in the `Fill` message.
     * @param response The `OrderResponse` struct containing the `Fill` message.
     * @return redeemedFill The `RedeemedFill` struct.
     */
    function redeemFill(OrderResponse memory response) external returns (RedeemedFill memory);
}
