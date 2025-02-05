// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract OkxHelper {
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

        pullTokenIn(tokenIn, amountIn);
        maxApproveIfNeeded(tokenIn, tokenContract, amountIn);

        (bool success, bytes memory returnedData) = swapProtocol.call{value: 0}(
            swapData
        );
        require(success, string(returnedData));

        transferBackRemaining(tokenIn, amountIn);
    }

    function pullTokenIn(address tokenIn, uint256 amountIn) internal {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
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

    function transferBackRemaining(address token, uint256 maxAmount) internal {
        uint256 remaining = IERC20(token).balanceOf(address(this));
        if (remaining > 0 && remaining <= maxAmount) {
            IERC20(token).safeTransfer(msg.sender, remaining);
        }
    }

    function rescueToken(address token, uint256 amount, address to) public {
        require(msg.sender == guardian, "only guardian");
        IERC20(token).safeTransfer(to, amount);
    }

    function rescueEth(uint256 amount, address payable to) public {
        require(msg.sender == guardian, "only guardian");
        require(to != address(0), "transfer to the zero address");
        to.transfer(amount);
    }
}
