// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/ITokenBridge.sol";
import "./interfaces/IWormhole.sol";

import { MayanStructs, RelayerFees, Recepient, Criteria } from "./MayanStructs.sol";
import "./libs/BytesLib.sol";

contract MayanSwap {
	event Redeemed(uint16 indexed emitterChainId, bytes32 indexed emitterAddress, uint64 indexed sequence);

	using SafeERC20 for IERC20;
	using BytesLib for bytes;

	ITokenBridge tokenBridge;
	address guardian;
	address nextGuardian;
	bool paused;
	IWETH weth;
	uint16 homeChainId;

	constructor(address _tokenBridge, address _weth) {
		tokenBridge = ITokenBridge(_tokenBridge);
		homeChainId = tokenBridge.chainId();
		guardian = msg.sender;
		weth = IWETH(_weth);
	}

	function swap(RelayerFees memory relayerFees, Recepient memory recipient, bytes32 tokenOutAddr, uint16 tokenOutChainId, Criteria memory criteria, address tokenIn, uint256 amountIn) public payable returns (uint64 sequence) {
		require(paused == false, 'contract is paused');
		require(block.timestamp <= criteria.transferDeadline, 'deadline passed');
		if (criteria.unwrap) {
			require(criteria.gasDrop == 0, 'gas drop not allowed');
		}

		uint8 decimals = decimalsOf(tokenIn);
		uint256 normalizedAmount = normalizeAmount(amountIn, decimals);

		require(relayerFees.swapFee + relayerFees.refundFee < normalizedAmount, 'fees exceed amount');
		require(relayerFees.redeemFee < criteria.amountOutMin, 'redeem fee exceeds min output');

		amountIn = deNormalizeAmount(normalizedAmount, decimals);

		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		IERC20(tokenIn).safeIncreaseAllowance(address(tokenBridge), amountIn);
		uint64 seq1 = tokenBridge.transferTokens{ value: msg.value/2 }(tokenIn, amountIn, recipient.mayanChainId, recipient.mayanAddr, 0, 0);

		MayanStructs.Swap memory swapStruct = MayanStructs.Swap({
			payloadId: criteria.customPayload.length > 0 ? 2 : 1,
			tokenAddr: tokenOutAddr,
			tokenChainId: tokenOutChainId,
			destAddr: recipient.destAddr,
			destChainId: recipient.destChainId,
			sourceAddr: recipient.refundAddr,
			sourceChainId: homeChainId,
			sequence: seq1,
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

		sequence = tokenBridge.wormhole().publishMessage{
			value : msg.value/2
		}(0, encoded, tokenBridge.finality());
	}

	function wrapAndSwapETH(RelayerFees memory relayerFees, Recepient memory recipient, bytes32 tokenOutAddr, uint16 tokenOutChainId, Criteria memory criteria) public payable returns (uint64 sequence) {
		require(paused == false, 'contract is paused');
		require(block.timestamp <= criteria.transferDeadline, 'deadline passed');
		if (criteria.unwrap) {
			require(criteria.gasDrop == 0, 'gas drop not allowed');
		}

		uint wormholeFee = tokenBridge.wormhole().messageFee();

		uint256 normalizedAmount = normalizeAmount(msg.value - 2*wormholeFee, 18);
		
		require(relayerFees.swapFee + relayerFees.refundFee < normalizedAmount, 'fees exceed amount');
		require(relayerFees.redeemFee < criteria.amountOutMin, 'redeem fee exceeds min output');

		uint256 amountIn = deNormalizeAmount(normalizedAmount, 18);

		uint64 seq1 = tokenBridge.wrapAndTransferETH{ value: amountIn + wormholeFee }(recipient.mayanChainId, recipient.mayanAddr, 0, 0);

		uint dust = msg.value - 2*wormholeFee - amountIn;
		if (dust > 0) {
			payable(msg.sender).transfer(dust);
		}

		MayanStructs.Swap memory swapStruct = MayanStructs.Swap({
			payloadId: criteria.customPayload.length > 0 ? 2 : 1,
			tokenAddr: tokenOutAddr,
			tokenChainId: tokenOutChainId,
			destAddr: recipient.destAddr,
			destChainId: recipient.destChainId,
			sourceAddr: recipient.refundAddr,
			sourceChainId: homeChainId,
			sequence: seq1,
			amountOutMin: criteria.amountOutMin,
			deadline: criteria.swapDeadline,
			swapFee: relayerFees.swapFee,
			redeemFee: relayerFees.redeemFee,
			refundFee: relayerFees.refundFee,
			auctionAddr: recipient.auctionAddr,
			unwrapRedeem: criteria.unwrap,
			unwrapRefund: true
		});

		bytes memory encoded = encodeSwap(swapStruct)
			.concat(abi.encodePacked(swapStruct.unwrapRedeem, swapStruct.unwrapRefund, recipient.referrer, criteria.gasDrop));

		if (swapStruct.payloadId == 2) {
			require(swapStruct.destChainId == recipient.mayanChainId, 'invalid chain id with payload');
			encoded = encoded.concat(abi.encodePacked(criteria.customPayload));
		}

		sequence = tokenBridge.wormhole().publishMessage{
			value : wormholeFee
		}(0, encoded, tokenBridge.finality());
	}

	function redeem(bytes memory encodedVm) public payable {
		IWormhole.VM memory vm = tokenBridge.wormhole().parseVM(encodedVm);
		ITokenBridge.TransferWithPayload memory transferPayload = tokenBridge.parseTransferWithPayload(vm.payload);
		MayanStructs.Redeem memory redeemPayload = parseRedeemPayload(transferPayload.payload);

		address recipient = truncateAddress(redeemPayload.recipient);
		if (redeemPayload.payloadId == 2) {
			require(msg.sender == recipient, 'not recipient');
		}

		address tokenAddr;
		if (transferPayload.tokenChain == homeChainId) {
			tokenAddr = truncateAddress(transferPayload.tokenAddress);
		} else {
			tokenAddr = tokenBridge.wrappedAsset(transferPayload.tokenChain, transferPayload.tokenAddress);
		}

		uint256 amount = IERC20(tokenAddr).balanceOf(address(this));
		tokenBridge.completeTransferWithPayload(encodedVm);
		amount = IERC20(tokenAddr).balanceOf(address(this)) - amount;

		uint256 relayerFee = deNormalizeAmount(uint256(redeemPayload.relayerFee), decimalsOf(tokenAddr));
		require(amount > relayerFee, 'relayer fee exeeds amount');

		if (redeemPayload.gasDrop > 0) {
			uint256 gasDrop = deNormalizeAmount(uint256(redeemPayload.gasDrop), decimalsOf(address(weth)));
			require(msg.value == gasDrop, 'incorrect gas drop');
			payable(recipient).transfer(gasDrop);
		}

		if (redeemPayload.unwrap && tokenAddr == address(weth)) {
			weth.withdraw(amount);
			payable(msg.sender).transfer(relayerFee);
			payable(recipient).transfer(amount - relayerFee);
		} else {
			IERC20(tokenAddr).safeTransfer(msg.sender, relayerFee);
			IERC20(tokenAddr).safeTransfer(recipient, amount - relayerFee);
		}

		emit Redeemed(vm.emitterChainId, vm.emitterAddress, vm.sequence);
	}

	function redeemAndUnwrap(bytes memory encodedVm) public {
		IWormhole.VM memory vm = tokenBridge.wormhole().parseVM(encodedVm);

		ITokenBridge.TransferWithPayload memory transferPayload = tokenBridge.parseTransferWithPayload(vm.payload);
		require(transferPayload.tokenChain == homeChainId, 'not home chain');
		
		address tokenAddr = truncateAddress(transferPayload.tokenAddress);
		require(tokenAddr == address(weth), 'not weth');

		MayanStructs.Redeem memory redeemPayload = parseRedeemPayload(transferPayload.payload);
		require(redeemPayload.unwrap, 'not unwrap');

		address recipient = truncateAddress(redeemPayload.recipient);
		if (redeemPayload.payloadId == 2) {
			require(msg.sender == recipient, 'not recipient');
		}

		uint256 amount = address(this).balance;
		tokenBridge.completeTransferAndUnwrapETHWithPayload(encodedVm);
		amount = address(this).balance - amount;

		uint256 relayerFee = deNormalizeAmount(uint256(redeemPayload.relayerFee), 18);
		require(amount > relayerFee, 'relayer fee exeeds amount');

		payable(msg.sender).transfer(relayerFee);
		payable(recipient).transfer(amount - relayerFee);

		emit Redeemed(vm.emitterChainId, vm.emitterAddress, vm.sequence);
	}

	function parseRedeemPayload(bytes memory encoded) public pure returns (MayanStructs.Redeem memory r) {
		uint index = 0;

		r.payloadId = encoded.toUint8(index);
		index += 1;

		require(r.payloadId == 1 || r.payloadId == 2, 'payload id not supported');

		r.recipient = encoded.toBytes32(index);
		index += 32;

		r.relayerFee = encoded.toUint64(index);
		index += 8;

		r.unwrap = encoded[index] != bytes1(0);
		index += 1;

		r.gasDrop = encoded.toUint64(index);
		index += 8;

		if (r.payloadId == 2) {
			r.customPayload = encoded.slice(index, encoded.length - index);
		} else {
			require(index == encoded.length, 'invalid payload length');
		}
	}

	function truncateAddress(bytes32 b) internal pure returns (address) {
		require(bytes12(b) == 0, 'invalid EVM address');
		return address(uint160(uint256(b)));
	}

	function decimalsOf(address token) internal view returns(uint8) {
		(,bytes memory queriedDecimals) = token.staticcall(abi.encodeWithSignature('decimals()'));
		return abi.decode(queriedDecimals, (uint8));
	}

	function normalizeAmount(uint256 amount, uint8 decimals) internal pure returns(uint256) {
		if (decimals > 8) {
			amount /= 10 ** (decimals - 8);
		}
		return amount;
	}

	function deNormalizeAmount(uint256 amount, uint8 decimals) internal pure returns(uint256) {
		if (decimals > 8) {
			amount *= 10 ** (decimals - 8);
		}
		return amount;
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

	function setPause(bool _pause) public {
		require(msg.sender == guardian, 'only guardian');
		paused = _pause;
	}

	function isPaused() public view returns(bool) {
		return paused;
	}

	function changeGuardian(address newGuardian) public {
		require(msg.sender == guardian, 'only guardian');
		nextGuardian = newGuardian;
	}

	function claimGuardian() public {
		require(msg.sender == nextGuardian, 'only next guardian');
		guardian = nextGuardian;
	}

	function sweepToken(address token, uint256 amount, address to) public {
		require(msg.sender == guardian, 'only guardian');
		IERC20(token).safeTransfer(to, amount);
	}

	function sweepEth(uint256 amount, address payable to) public {
		require(msg.sender == guardian, 'only guardian');
		require(to != address(0), 'transfer to the zero address');
		to.transfer(amount);
	}

	function getWeth() public view returns(address) {
		return address(weth);
	}

    receive() external payable {}
}