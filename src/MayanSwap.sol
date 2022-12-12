// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/ITokenBridge.sol";
import "./interfaces/IWormhole.sol";

import "./MayanStructs.sol";
import "./libs/BytesLib.sol";

contract MayanSwap {
	event Redeemed(uint16 indexed emitterChainId, bytes32 indexed emitterAddress, uint64 indexed sequence);

	using SafeERC20 for IERC20;
	using BytesLib for bytes;

	ITokenBridge tokenBridge;
	address guardian;
	address nextGuardian;
	bool paused;

	struct RelayerFees {
		uint64 swapFee;
		uint64 redeemFee;
		uint64 refundFee;
	}

	struct Criteria {
		uint256 transferDeadline;
		uint64 swapDeadline;
		uint64 amountOutMin;
		bool unwrap;
		uint32 nonce;
	}

	struct Recepient {
		bytes32 mayanAddr;
		uint16 mayanChainId;
		bytes32 auctionAddr;
		bytes32 destAddr;
		uint16 destChainId;
	}

	constructor(address _tokenBridge) {
		tokenBridge = ITokenBridge(_tokenBridge);
		guardian = msg.sender;
	}

	function swap(RelayerFees memory relayerFees, Recepient memory recepient, bytes32 tokenOutAddr, uint16 tokenOutChainId, Criteria memory criteria, address tokenIn, uint256 amountIn) public payable returns (uint64 sequence) {
		require(paused == false, 'contract is paused');
		require(block.timestamp <= criteria.transferDeadline, 'deadline passed');

		uint8 decimals = decimalsOf(tokenIn);
		uint256 normalizedAmount = normalizeAmount(amountIn, decimals);

		require(relayerFees.swapFee < normalizedAmount, 'swap fee exceeds amount');
		require(relayerFees.redeemFee < criteria.amountOutMin, 'redeem fee exceeds min output');
		require(relayerFees.refundFee < normalizedAmount, 'refund fee exceeds amount');

		amountIn = deNormalizeAmount(normalizedAmount, decimals);

		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		IERC20(tokenIn).safeIncreaseAllowance(address(tokenBridge), amountIn);
		uint64 seq1 = tokenBridge.transferTokens{ value: msg.value/2 }(tokenIn, amountIn, recepient.mayanChainId, recepient.mayanAddr, 0, criteria.nonce);

		MayanStructs.Swap memory swapStruct = MayanStructs.Swap({
			payloadID: 1,
			tokenAddr: tokenOutAddr,
			tokenChainId: tokenOutChainId,
			destAddr: recepient.destAddr,
			destChainId: recepient.destChainId,
			sourceAddr: bytes32(uint256(uint160(msg.sender))),
			sourceChainId: tokenBridge.chainId(),
			sequence: seq1,
			amountOutMin: criteria.amountOutMin,
			deadline: criteria.swapDeadline,
			swapFee: relayerFees.swapFee,
			redeemFee: relayerFees.redeemFee,
			refundFee: relayerFees.refundFee,
			auctionAddr: recepient.auctionAddr,
			unwrapRedeem: criteria.unwrap,
			unwrapRefund: false
		});

		bytes memory encoded = encodeSwap(swapStruct)
			.concat(abi.encodePacked(swapStruct.unwrapRedeem, swapStruct.unwrapRefund));

		sequence = tokenBridge.wormhole().publishMessage{
			value : msg.value/2
		}(criteria.nonce, encoded, tokenBridge.finality());
	}

	function wrapAndSwapETH(RelayerFees memory relayerFees, Recepient memory recepient, bytes32 tokenOutAddr, uint16 tokenOutChainId, Criteria memory criteria) public payable returns (uint64 sequence) {
		require(paused == false, 'contract is paused');
		require(block.timestamp <= criteria.transferDeadline, 'deadline passed');
		uint wormholeFee = tokenBridge.wormhole().messageFee();

		uint256 normalizedAmount = normalizeAmount(msg.value - 2*wormholeFee, 18);
		
		require(relayerFees.swapFee < normalizedAmount, 'swap fee exceeds amount');
		require(relayerFees.redeemFee < criteria.amountOutMin, 'redeem fee exceeds min output');
		require(relayerFees.refundFee < normalizedAmount, 'refund fee exceeds amount');

		uint256 amountIn = deNormalizeAmount(normalizedAmount, 18);

		uint64 seq1 = tokenBridge.wrapAndTransferETH{ value: amountIn + wormholeFee }(recepient.mayanChainId, recepient.mayanAddr, 0, criteria.nonce);

		uint dust = msg.value - 2*wormholeFee - amountIn;
		if (dust > 0) {
			payable(msg.sender).transfer(dust);
		}

		MayanStructs.Swap memory swapStruct = MayanStructs.Swap({
			payloadID: 1,
			tokenAddr: tokenOutAddr,
			tokenChainId: tokenOutChainId,
			destAddr: recepient.destAddr,
			destChainId: recepient.destChainId,
			sourceAddr: bytes32(uint256(uint160(msg.sender))),
			sourceChainId: tokenBridge.chainId(),
			sequence: seq1,
			amountOutMin: criteria.amountOutMin,
			deadline: criteria.swapDeadline,
			swapFee: relayerFees.swapFee,
			redeemFee: relayerFees.redeemFee,
			refundFee: relayerFees.refundFee,
			auctionAddr: recepient.auctionAddr,
			unwrapRedeem: criteria.unwrap,
			unwrapRefund: true
		});

		bytes memory encoded = encodeSwap(swapStruct)
			.concat(abi.encodePacked(swapStruct.unwrapRedeem, swapStruct.unwrapRefund));

		sequence = tokenBridge.wormhole().publishMessage{
			value : wormholeFee
		}(criteria.nonce, encoded, tokenBridge.finality());
	}

	function redeem(bytes memory encodedVm) public {
		IWormhole.VM memory vm = tokenBridge.wormhole().parseVM(encodedVm);
		ITokenBridge.TransferWithPayload memory transferPayload = tokenBridge.parseTransferWithPayload(vm.payload);
		MayanStructs.Redeem memory redeemPayload = parseRedeemPayload(transferPayload.payload);

		address tokenAddr;
		if (transferPayload.tokenChain == tokenBridge.chainId()) {
			tokenAddr = truncateAddress(transferPayload.tokenAddress);
		} else {
			tokenAddr = tokenBridge.wrappedAsset(transferPayload.tokenChain, transferPayload.tokenAddress);
		}

		uint256 amount = IERC20(tokenAddr).balanceOf(address(this));
		tokenBridge.completeTransferWithPayload(encodedVm);
		amount = IERC20(tokenAddr).balanceOf(address(this)) - amount;

		uint256 relayerFee = deNormalizeAmount(uint256(redeemPayload.relayerFee), decimalsOf(tokenAddr));
		require(amount > relayerFee, 'relayer fee exeeds amount');

		address recepient = truncateAddress(redeemPayload.recepient);

		if (redeemPayload.unwrap && tokenAddr == address(tokenBridge.WETH())) {
			tokenBridge.WETH().withdraw(amount);
			payable(msg.sender).transfer(relayerFee);
			payable(recepient).transfer(amount - relayerFee);
		} else {
			IERC20(tokenAddr).safeTransfer(msg.sender, relayerFee);
			IERC20(tokenAddr).safeTransfer(recepient, amount - relayerFee);
		}

		emit Redeemed(vm.emitterChainId, vm.emitterAddress, vm.sequence);
    }

	function parseRedeemPayload(bytes memory encoded) public pure returns (MayanStructs.Redeem memory r) {
		uint index = 0;

		r.recepient = encoded.toBytes32(index);
		index += 32;

		r.relayerFee = encoded.toUint64(index);
		index += 8;

		if (encoded[index] != bytes1(0)) {
			r.unwrap = true;
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
			s.payloadID,
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

    receive() external payable {}
}