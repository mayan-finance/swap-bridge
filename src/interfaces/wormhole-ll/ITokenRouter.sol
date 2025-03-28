// SPDX-License-Identifier: Apache 2
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../IWormhole.sol";
import "./IPlaceMarketOrder.sol";
import "./IRedeemFill.sol";

interface ITokenRouter is IPlaceMarketOrder, IRedeemFill {

    function orderToken() external view returns (IERC20);   

    function wormhole() external view returns (IWormhole); 
}
