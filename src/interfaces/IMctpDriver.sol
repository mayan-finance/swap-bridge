// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IMctpDriver {
	function mctpSwap(
		address tokenIn,
		uint256 amountIn,
		address tokenOut,
		uint256 promisedAmountOut,
		uint256 gasDrop
	) external;
}