// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

contract MayanStructs {
	struct Swap {
		// PayloadID uint8 = 1
		uint8 payloadID;
		// Amount being transferred (big-endian uint256)
		uint256 amountIn;
		// Address of the ouput token. Left-zero-padded if shorter than 32 bytes
		bytes32 tokenAddress;
		// Chain ID of the ouput token
		uint16 tokenChain;
		// Address of the recipient. Left-zero-padded if shorter than 32 bytes
		bytes32 to;
		// Chain ID of the recipient
		uint16 toChain;
		// Address of sender (for revert scenario)
		bytes32 from;
		// ChainId of sender (for revert scenario)
		uint16 fromChain;
		// Sequence of transfer vaa
		uint64 sequence;
		// Minimum amount our
		uint256 amountOutMin;
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