// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IMessageTransmitterV2.sol";
import "./ITokenMinterV2.sol";

interface ITokenMessengerV2 {
	function localMessageTransmitter() external view returns (IMessageTransmitterV2);
	function localMinter() external view returns (ITokenMinterV2);

	function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;
}