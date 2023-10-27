// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MayanStructs, RelayerFees, Recepient, Criteria } from "./MayanStructs.sol";
import "./libs/BytesLib.sol";
import "./interfaces/ITokenMessenger.sol";
import "./interfaces/IWormhole.sol";

contract MayanCCTP {
	using SafeERC20 for IERC20;
	using BytesLib for bytes;

	address public usdcAddr;
	ITokenMessenger cctpTokenMessenger;
	IWormhole wormhole;
	uint16 public consistencyLevel;
	address public guardian;
	address public nextGuardian;
	bool public paused;
	uint16 public homeChainId;

	constructor(address _usdcAddr, address _cctpTokenMessenger, address _wormhole, uint16 _consistencyLevel) {
		usdcAddr = _usdcAddr;
		cctpTokenMessenger = ITokenMessenger(_cctpTokenMessenger);
		IWormhole = IWormhole(_wormhole);
		homeChainId = _wormhole.chainId();
		consistencyLevel = _consistencyLevel;
		guardian = msg.sender;
	}

	function swapUSDC(RelayerFees memory relayerFees, Recepient memory recipient, bytes32 tokenOutAddr, uint16 tokenOutChainId, Criteria memory criteria, uint256 amountIn) public payable returns (uint64 sequence) {
		require(paused == false, 'contract is paused');
		require(block.timestamp <= criteria.transferDeadline, 'deadline passed');
		if (criteria.unwrap) {
			require(criteria.gasDrop == 0, 'gas drop not allowed');
		}

		require(relayerFees.swapFee + relayerFees.refundFee < amountIn, 'fees exceed amount');
		require(relayerFees.redeemFee < criteria.amountOutMin, 'redeem fee exceeds min output');

		IERC20(usdcAddr).safeTransferFrom(msg.sender, address(this), amountIn);
		cctpTokenMessenger.depositForBurnWithCaller(amountIn, 1, recipient.mayanAddr, usdcAddr, recipient.mayanAddr);

		MayanStructs.Swap memory swapStruct = MayanStructs.Swap({
			payloadId: criteria.customPayload.length > 0 ? 2 : 1,
			tokenAddr: tokenOutAddr,
			tokenChainId: tokenOutChainId,
			destAddr: recipient.destAddr,
			destChainId: recipient.destChainId,
			sourceAddr: recipient.refundAddr,
			sourceChainId: homeChainId,
			sequence: 0,
			amountOutMin: criteria.amountOutMin,
			deadline: criteria.swapDeadline,
			swapFee: relayerFees.swapFee,
			redeemFee: relayerFees.redeemFee,
			refundFee: relayerFees.refundFee,
			auctionAddr: recipient.auctionAddr,
			unwrapRedeem: criteria.unwrap,
			unwrapRefund: false
		});

		bytes memory encoded = encodeSwap(swapStruct)
			.concat(abi.encodePacked(swapStruct.unwrapRedeem, swapStruct.unwrapRefund, recipient.referrer, criteria.gasDrop));

		if (swapStruct.payloadId == 2) {
			require(swapStruct.destChainId == recipient.mayanChainId, 'invalid chain id with payload');
			encoded = encoded.concat(abi.encodePacked(criteria.customPayload));
		}

		sequence = wormhole.publishMessage{
			value : msg.value
		}(0, encoded, consistencyLevel);
	}

	function encodeSwap(MayanStructs.Swap memory s) public pure returns(bytes memory encoded) {
		encoded = abi.encodePacked(
			s.payloadId,
			s.tokenAddr,
			s.tokenChainId,
			s.destAddr,
			s.destChainId,
			s.sourceAddr,
			s.sourceChainId,
			s.sequence,
			s.amountOutMin,
			s.deadline,
			s.swapFee,
			s.redeemFee,
			s.refundFee,
			s.auctionAddr
		);
	}

	function fulfill(bytes memory cctpMsg, bytes memory cctpSigs, bytes memory encodedVm) public {
		cctpTokenMessenger.localMessageTransmitter().receiveMessage(cctpMsg, cctpSigs);

		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);
		require(vm.emitterChainId == auctionChainId, 'invalid auction chain');
		require(vm.emitterAddress == auctionAddr, 'invalid auction address');

		FulfillMsg memory fulfillMsg = parseFulfillPayload(vm.payload);

		require(fulfillMsg.destChainId == wormhole.chainId(), 'wrong chain id');
		require(truncateAddress(fulfillMsg.driver) == msg.sender, 'invalid driver');


	}
}