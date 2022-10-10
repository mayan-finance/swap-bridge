// contracts/Structs.sol
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

        uint64 sequence;

        uint256 amountOutMin;
        uint64 deadline;

        // Swap fee
        uint64 swapFee;
        // Redeem fee
        uint64 redeemFee;
        // Refund fee
        uint64 refundFee;
    }
}