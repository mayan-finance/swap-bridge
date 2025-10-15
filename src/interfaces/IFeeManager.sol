// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../swift/SwiftStructs.sol";

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

     function calcSwiftProtocolBps(
        address tokenIn,
        uint256 amountIn,
        OrderParams memory params
    )  external returns (uint8);

    function calcFastMCTPProtocolBps(
        uint8 payloadType,
        address localToken,
        uint256 recievedAmount,
        address tokenOut,
        address referrerAddr,
        uint8 referrerBps
    ) external returns (uint8);

	function feeCollector() external view returns (address);

    function depositFee(address owner, address token, uint256 amount) payable external;
    function withdrawFee(address token, uint256 amount) external;
}
