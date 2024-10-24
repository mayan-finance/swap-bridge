// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFeeManager {
    function calcProtocolBps(
        uint64 amountIn,
        address tokenIn,
        bytes32 tokenOut,
        uint16 destChain,
        uint8 referrerBps
    ) external view returns (uint8);

	function feeCollector() external view returns (address);
}
