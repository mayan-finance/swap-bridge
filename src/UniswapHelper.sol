// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPermit2} from "@uniswap/permit2/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract UniswapHelper {
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
        address permit2,
        address swapProtocol,
        bytes calldata swapData
    ) external payable {
        if (!swapProtocols[swapProtocol]) {
            revert UnsupportedProtocol();
        }

        pullTokenIn(tokenIn, amountIn);
        maxApproveIfNeeded(tokenIn, permit2, swapProtocol, amountIn);

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
        address permit2Addr,
        address swapProtocol,
        uint256 amount
    ) internal {
        IERC20 token = IERC20(tokenAddr);
        uint256 tokenAllowance = token.allowance(address(this), permit2Addr);

        if (tokenAllowance < amount) {
            token.safeApprove(permit2Addr, 0);
            token.safeApprove(permit2Addr, type(uint256).max);
        }

        IPermit2 permit2 = IPermit2(permit2Addr);
        (uint160 permitAllowance, uint48 expiration, uint48 nonce) = permit2
            .allowance(address(this), tokenAddr, swapProtocol);

        if (block.timestamp > expiration || permitAllowance < amount) {
            permit2.approve(
                tokenAddr,
                swapProtocol,
                type(uint160).max,
                type(uint48).max
            );
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
