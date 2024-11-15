// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MayanOkxForwarder {
    using SafeERC20 for IERC20;

    address public guardian;
    mapping(address => bool) public swapProtocols;

    error UnsupportedProtocol();

    constructor(address _guardian, address[] memory _swapProtocols) {
        guardian = _guardian;
        for (uint256 i = 0; i < _swapProtocols.length; i++) {
            swapProtocols[_swapProtocols[i]] = true;
        }
    }

    function setSwapProtocol(address swapProtocol, bool enabled) public {
        require(msg.sender == guardian, "only guardian");
        swapProtocols[swapProtocol] = enabled;
    }

    function approveAndForward(
        address tokenIn,
        uint256 amountIn,
        address tokenContract,
        address swapProtocol,
        bytes calldata swapData
    ) external payable {
        if (!swapProtocols[swapProtocol]) {
            revert UnsupportedProtocol();
        }

        maxApproveIfNeeded(tokenIn, tokenContract, amountIn);

        (bool success, bytes memory returnedData) = swapProtocol.call{value: 0}(
            swapData
        );
        require(success, string(returnedData));
    }

    function maxApproveIfNeeded(
        address tokenAddr,
        address spender,
        uint256 amount
    ) internal {
        IERC20 token = IERC20(tokenAddr);
        uint256 currentAllowance = token.allowance(address(this), spender);

        if (currentAllowance < amount) {
            token.safeApprove(spender, 0);
            token.safeApprove(spender, type(uint256).max);
        }
    }
}
