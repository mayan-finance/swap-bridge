// write interface for SwiftDest.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "../swift/SwiftStructs.sol";

interface IFulfill {
	function fulfillOrder(
		uint256 fulfillAmount,
		bytes memory encodedVm,
		OrderParams memory params,
		ExtraParams memory extraParams,
		bytes32 recipient,
		bool batch,
		PermitParams calldata permit
	) external payable returns (uint64 sequence);

	function fulfillSimple(
		uint256 fulfillAmount,
		bytes32 orderHash,
		OrderParams memory params,
		ExtraParams memory extraParams,
		bytes32 recipient,
		bool batch,
		PermitParams calldata permit
	) external payable returns (uint64 sequence);
}