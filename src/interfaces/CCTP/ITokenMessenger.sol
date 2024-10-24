// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IMessageTransmitter.sol";
import "./ITokenMinter.sol";

interface ITokenMessenger {
	function localMessageTransmitter() external view returns (IMessageTransmitter);
	function localMinter() external view returns (ITokenMinter);

	function depositForBurnWithCaller(
		uint256 amount,
		uint32 destinationDomain,
		bytes32 mintRecipient,
		address burnToken,
		bytes32 destinationCaller
	) external returns (uint64 nonce);
}