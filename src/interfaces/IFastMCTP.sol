// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import { ITokenMessengerV2 } from "./CCTP/v2/ITokenMessengerV2.sol";

interface IFastMCTP {
    struct OrderPayload {
		uint8 payloadType;
		bytes32 destAddr;
		bytes32 tokenOut;
		uint64 amountOutMin;
		uint64 gasDrop;
		uint64 redeemFee;
		uint64 refundFee;
		uint64 deadline;
		bytes32 referrerAddr;
		uint8 referrerBps;
	}

    function bridge(
		address tokenIn,
		uint256 amountIn,
		uint64 redeemFee,
		uint256 circleMaxFee,
		uint64 gasDrop,
		bytes32 destAddr,
		uint32 destDomain,
		bytes32 referrerAddress,
		uint8 referrerBps,
		uint8 payloadType,
		uint32 minFinalityThreshold,
		bytes memory customPayload
	) external;

    function createOrder(
		address tokenIn,
		uint256 amountIn,
		uint256 circleMaxFee,
		uint32 destDomain,
		uint32 minFinalityThreshold,
		OrderPayload memory orderPayload
	) external;

    function redeem(
		bytes memory cctpMsg,
		bytes memory cctpSigs
	) external payable;

    function cctpTokenMessengerV2() external view returns (ITokenMessengerV2);
}
