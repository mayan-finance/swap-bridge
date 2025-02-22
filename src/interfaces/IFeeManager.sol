// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFeeManager {
    event ProtocolFeeCalced(uint8 bps);
    event FeeDeposited(address relayer, address token, uint256 amount);
    event FeeWithdrawn(address token, uint256 amount);

    function calcProtocolBps(
        uint64 amountIn,
        address tokenIn,
        bytes32 tokenOut,
        uint16 destChain,
        uint8 referrerBps
    ) external returns (uint8);

	function feeCollector() external view returns (address);

    function depositFee(address owner, address token, uint256 amount) payable external;
    function withdrawFee(address token, uint256 amount) external;
}
