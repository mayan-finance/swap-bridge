// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import { IWormhole } from "./IWormhole.sol";
import { ITokenMessenger } from "./CCTP/ITokenMessenger.sol";


interface IMayanCircle {
    struct OrderParams {
		address tokenIn;
		uint256 amountIn;
		uint64 gasDrop;
		bytes32 destAddr;
		uint16 destChain;
		bytes32 tokenOut;
		uint64 minAmountOut;
		uint64 deadline;
		uint64 redeemFee;
		bytes32 referrerAddr;
		uint8 referrerBps;
	}

    struct BridgeWithFeeParams {
		uint8 payloadType;
		bytes32 destAddr;
		uint64 gasDrop;
		uint64 redeemFee;
		uint64 burnAmount;
		bytes32 burnToken;
		bytes32 customPayload;		
	}

    struct BridgeWithFeeMsg {
		uint8 action;
		uint8 payloadType;
		uint64 cctpNonce;
		uint32 cctpDomain;
		bytes32 destAddr;
		uint64 gasDrop;
		uint64 redeemFee;
		uint64 burnAmount;
		bytes32 burnToken;
		bytes32 customPayload;
	}

    function bridgeWithFee(
		address tokenIn,
		uint256 amountIn,
		uint64 redeemFee,
		uint64 gasDrop,
		bytes32 destAddr,
		uint32 destDomain,
		uint8 payloadType,
		bytes memory customPayload
	) external payable returns (uint64 sequence);

    function createOrder(
		OrderParams memory params
	) external payable returns (uint64 sequence);

    function redeemWithFee(
		bytes memory cctpMsg,
		bytes memory cctpSigs,
		bytes memory encodedVm,
		BridgeWithFeeParams memory bridgeParams
	) external payable;

    function wormhole() external view returns (IWormhole);

    function cctpTokenMessenger() external view returns (ITokenMessenger);
}
