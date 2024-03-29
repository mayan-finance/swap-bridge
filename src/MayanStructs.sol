// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract MayanStructs {
	struct Swap {
		uint8 payloadId;
		bytes32 tokenAddr;
		uint16 tokenChainId;
		bytes32 destAddr;
		uint16 destChainId;
		bytes32 sourceAddr;
		uint16 sourceChainId;
		uint64 sequence;
		uint64 amountOutMin;
		uint64 deadline;
		uint64 swapFee;
		uint64 redeemFee;
		uint64 refundFee;
		bytes32 auctionAddr;
		bool unwrapRedeem;
		bool unwrapRefund;
	}

	struct Redeem {
		uint8 payloadId;
		bytes32 recipient;
		uint64 relayerFee;
		bool unwrap;
		uint64 gasDrop;
		bytes customPayload;
	}
}