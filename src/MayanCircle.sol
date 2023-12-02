// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libs/BytesLib.sol";
import "./interfaces/IReceiver.sol";
import "./interfaces/ITokenMessenger.sol";
import "./interfaces/IWormhole.sol";
import "./interfaces/IMctpDriver.sol";

contract MayanCircle {
	using SafeERC20 for IERC20;
	using BytesLib for bytes;

	event Fulfilled(uint64 sequence);

	address public usdcAddr;
	IReceiver cctpReceiver;
	ITokenMessenger cctpTokenMessenger;
	IWormhole wormhole;
	uint8 public consistencyLevel;
	address public guardian;
	address public nextGuardian;
	bool public paused;
	uint8 public mayanDefaultBps;
	bytes32 public auctionEmitter;

	struct Criteria {
		uint256 transferDeadline;
		uint64 swapDeadline;
		bytes32 tokenOutAddr;
		uint64 amountOutMin;
		uint64 gasDrop;
		bytes customPayload;
	}

	struct Recipient {
		bytes32 mayanAddr;
		bytes32 callerAddr;
		uint32 destDomain;
		bytes32 refundAddr;
	}

	struct Fees {
		uint64 settleFee;
		uint8 mayanDefaultBps;
		uint8 referrerBps;
	}

	struct MctpStruct {
		uint8 payloadId;
		uint16 fromChainId;
		bytes32 refundAddr;
		bytes32 destToken;
		uint32 destDomain;
		bytes32 destAddr;
		uint64 amountOutMin;
		uint64 gasDrop;
		bytes32 referrerAddr;
		uint8 mayanBps;
		uint8 referrerBps;
		uint64 cctpNonce;
		uint64 settleFee;
		// uint64 deadline;
	}

	struct FulFillPaylod {
		uint8 payloadId;
		bytes32 driver;
		bytes32 destAddr;
		uint16 destChainId;
		bytes32 tokenIn;
		uint64 amountIn;
		bytes32 tokenOut;
		uint64 promisedAmountOut;
		uint64 gasDrop;
	}

	constructor(address _cctpTokenMessenger, bytes32 _auctionEmitter, address _wormhole, uint8 _consistencyLevel) {
		cctpTokenMessenger = ITokenMessenger(_cctpTokenMessenger);
		auctionEmitter = _auctionEmitter;
		wormhole = IWormhole(_wormhole);
		consistencyLevel = _consistencyLevel;
		guardian = msg.sender;
		mayanDefaultBps = 0;
	}

	function swap(Recipient memory recipient, Criteria memory criteria, Fees memory fees, address tokenIn, uint256 amountIn, bytes32 referrer) public payable returns (uint64 sequence) {
		require(paused == false, 'contract is paused');
		require(block.timestamp <= criteria.transferDeadline, 'deadline passed');

		require(fees.settleFee < amountIn, 'fees exceed amount');

		require(fees.referrerBps <= 50, 'referrer fee exceeds 50 bps');

		uint256 burnAmount = IERC20(tokenIn).balanceOf(address(this));
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		burnAmount = IERC20(tokenIn).balanceOf(address(this)) - burnAmount;

		uint64 ccptNonce = cctpTokenMessenger.depositForBurnWithCaller(burnAmount, recipient.destDomain, recipient.mayanAddr, tokenIn, recipient.callerAddr);

		MctpStruct memory mctpStruct = MctpStruct({
			payloadId : criteria.customPayload.length > 0 ? 2 : 1,
			cctpNonce : ccptNonce,
			fromChainId : wormhole.chainId(),
			refundAddr : recipient.refundAddr,
			destToken : criteria.tokenOutAddr,
			destDomain : recipient.destDomain,
			destAddr : recipient.mayanAddr,
			amountOutMin : criteria.amountOutMin,
			gasDrop : criteria.gasDrop,
			referrerAddr : referrer,
			mayanBps : fees.referrerBps > mayanDefaultBps ? fees.referrerBps : mayanDefaultBps,
			referrerBps : fees.referrerBps,
			settleFee : fees.settleFee
		});

		bytes memory encoded = encodeMctpMsg(mctpStruct);

		if (mctpStruct.payloadId == 2) {
			encoded = encoded.concat(abi.encodePacked(criteria.swapDeadline, criteria.customPayload));
		} else {
			encoded = encoded.concat(abi.encodePacked(criteria.swapDeadline));
		}

		sequence = wormhole.publishMessage{
			value : msg.value
		}(0, encoded, consistencyLevel);
	}

	function fulfill(bytes memory cctpMsg, bytes memory cctpSigs, bytes memory encodedVm) public {
		cctpTokenMessenger.localMessageTransmitter().receiveMessage(cctpMsg, cctpSigs);

		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);
		require(vm.emitterChainId == 1, 'invalid auction chain');
		require(vm.emitterAddress == auctionEmitter, 'invalid auction emitter');

		FulFillPaylod memory payload = parseFulfillPayload(vm.payload);

		require(payload.destChainId == wormhole.chainId(), 'wrong chain id');

		address driver = truncateAddress(payload.driver);
		require(driver == msg.sender, 'invalid driver');

		address tokenIn = truncateAddress(payload.tokenIn);
		uint256 amountIn = IERC20(tokenIn).balanceOf(address(this));
		require(cctpReceiver.receiveMessage(cctpMsg, cctpSigs), 'invalid cctp message');
		amountIn = IERC20(tokenIn).balanceOf(address(this)) - amountIn;

		IERC20(tokenIn).approve(driver, amountIn);

		address tokenOut = truncateAddress(payload.tokenOut);
		uint256 amountOut = IERC20(tokenOut).balanceOf(address(this));
		IMctpDriver(driver).mctpSwap(tokenIn, payload.amountIn, tokenOut, payload.promisedAmountOut, payload.gasDrop);
		amountOut = IERC20(tokenOut).balanceOf(address(this)) - amountOut;

		require(amountOut >= payload.promisedAmountOut, 'amount out too low');

		// pay mayan and referrer fees

		address destAddr = truncateAddress(payload.destAddr);
		IERC20(tokenOut).safeTransfer(destAddr, amountOut);

		emit Fulfilled(vm.sequence);
	}

	function parseFulfillPayload(bytes memory payload) internal pure returns (FulFillPaylod memory p) {
		p.payloadId = payload.toUint8(0);
		p.driver = payload.toBytes32(1);
		p.destAddr = payload.toBytes32(33);
		p.destChainId = payload.toUint16(65);
		p.tokenIn = payload.toBytes32(67);
		p.amountIn = payload.toUint64(99);
		p.tokenOut = payload.toBytes32(107);
		p.promisedAmountOut = payload.toUint64(139);
		p.gasDrop = payload.toUint64(147);
	}

	function encodeMctpMsg(MctpStruct memory s) public pure returns(bytes memory encoded) {
		encoded = abi.encodePacked(
			s.payloadId,
			s.fromChainId,
			s.refundAddr,
			s.destToken,
			s.destDomain,
			s.destAddr,
			s.amountOutMin,
			s.gasDrop,
			s.referrerAddr,
			s.mayanBps,
			s.referrerBps,
			s.cctpNonce,
			s.settleFee
			// s.deadline
		);
	}

	function truncateAddress(bytes32 b) internal pure returns (address) {
		require(bytes12(b) == 0, 'invalid EVM address');
		return address(uint160(uint256(b)));
	}
}