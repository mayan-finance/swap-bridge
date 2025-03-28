// SPDX-License-Identifier: Apache 2
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IPlaceMarketOrder.sol";
import "./IRedeemFill.sol";

interface ITokenRouter is IPlaceMarketOrder, IRedeemFill {
    /**
     * @notice Returns allow listed token address for this router.
     */
    function orderToken() external view returns (IERC20);    
}
