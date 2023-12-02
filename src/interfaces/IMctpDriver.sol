// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IMctpDriver {
	function mctpSwap(
		address tokenIn,
		uint64 amountIn,
		address tokenOut,
		uint64 promisedAmountOut,
		uint64 gasDrop
	) external;
}