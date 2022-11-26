// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

contract MayanStructs {
	struct Swap {
		// PayloadID uint8 = 1
		uint8 payloadID;
		// Address of the ouput token. Left-zero-padded if shorter than 32 bytes
		bytes32 tokenAddr;
		// Chain ID of the ouput token
		uint16 tokenChainId;
		// Address of the recipient. Left-zero-padded if shorter than 32 bytes
		bytes32 destAddr;
		// Chain ID of the recipient
		uint16 destChainId;
		// Address of sender (for revert scenario)
		bytes32 sourceAddr;
		// ChainId of sender (for revert scenario)
		uint16 sourceChainId;
		// Sequence of transfer vaa
		uint64 sequence;
		// Minimum amount our
		uint64 amountOutMin;
		// deadline of swap
		uint64 deadline;
		// Swap relayer fee
		uint64 swapFee;
		// Redeem relayer fee
		uint64 redeemFee;
		// Refund relayer fee
		uint64 refundFee;
	}
}