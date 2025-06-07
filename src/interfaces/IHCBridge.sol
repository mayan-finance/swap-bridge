// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IHCBridge {
	struct DepositWithPermit {
		address user;
		uint64 usd;
		uint64 deadline;
		Signature signature;
	}

	struct Signature {
		uint256 r;
		uint256 s;
		uint8 v;
	}

	function batchedDepositWithPermit(
		DepositWithPermit[] memory deposits
	) external;
}