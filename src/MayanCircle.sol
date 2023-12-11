// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libs/BytesLib.sol";
import "./interfaces/IReceiver.sol";
import "./interfaces/ITokenMessenger.sol";
import "./interfaces/IWormhole.sol";
import "./interfaces/IMctpDriver.sol";

contract MayanCircle is ReentrancyGuard {
	using SafeERC20 for IERC20;
	using BytesLib for bytes;

	event Fulfilled(uint64 sequence);

	address public usdcAddr;
	ITokenMessenger public cctpTokenMessenger;
	IWormhole public wormhole;
	uint8 public consistencyLevel;
	address public guardian;
	address public nextGuardian;
	bool public paused;
	uint8 public mayanDefaultBps;
	bytes32 public auctionEmitter;
	address public mayanFeeCollector;
	mapping (uint32 => uint16) public domainToChainId;

	struct Criteria {
		uint256 transferDeadline;
		uint64 swapDeadline;
		bytes32 tokenOutAddr;
		uint64 amountOutMin;
		uint64 gasDrop;
		bytes customPayload;
	}

	struct Recipient {
		bytes32 destAddr;
		uint32 destDomain;
		bytes32 mayanAddr;
		bytes32 callerAddr;
		bytes32 refundAddr;
	}

	struct Fees {
		uint64 settleFee;
		uint8 referrerBps;
	}

	struct MctpStruct {
		uint8 payloadId;
		uint16 sourceChainId;
		bytes32 refundAddr;
		bytes32 destToken;
		uint16 destChainId;
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

	struct FulFillPayload {
		uint8 payloadId;
		uint16 sourceChainId;
		bytes32 refundAddr;
		bytes32 destToken;
		uint16 destChainId;
		bytes32 destAddr;
		uint64 amountOutMin;
		uint64 gasDrop;
		bytes32 referrerAddr;
		uint8 mayanBps;
		uint8 referrerBps;
		uint64 cctpNonce;
		uint64 settleFee;
		uint64 deadline;
		bytes32 driver;
		uint64 promisedAmountOut;
		bytes customPayload;
	}

	constructor(address _cctpTokenMessenger, address _wormhole, bytes32 _auctionEmitter, uint8 _consistencyLevel) {
		cctpTokenMessenger = ITokenMessenger(_cctpTokenMessenger);
		wormhole = IWormhole(_wormhole);
		auctionEmitter = _auctionEmitter;
		consistencyLevel = _consistencyLevel;
		guardian = msg.sender;
		mayanFeeCollector = msg.sender;
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

		SafeERC20.safeApprove(IERC20(tokenIn), address(cctpTokenMessenger), burnAmount);
		uint64 ccptNonce = cctpTokenMessenger.depositForBurnWithCaller(burnAmount, recipient.destDomain, recipient.mayanAddr, tokenIn, recipient.callerAddr);

		MctpStruct memory mctpStruct = MctpStruct({
			payloadId : criteria.customPayload.length > 0 ? 2 : 1,
			cctpNonce : ccptNonce,
			sourceChainId : wormhole.chainId(),
			refundAddr : recipient.refundAddr,
			destToken : criteria.tokenOutAddr,
			destChainId : getChainIdFromDomain(recipient.destDomain),
			destAddr : recipient.destAddr,
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

	function fulfill(bytes memory cctpMsg, bytes memory cctpSigs, bytes memory encodedVm) public nonReentrant {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);
		require(vm.emitterChainId == 1, 'invalid auction chain');
		require(vm.emitterAddress == auctionEmitter, 'invalid auction emitter');

		FulFillPayload memory payload = parseFulfillPayload(vm.payload);

		require(payload.destChainId == wormhole.chainId(), 'wrong chain id');

		address driver = truncateAddress(payload.driver);
		require(driver == msg.sender, 'invalid driver');

		address tokenIn = verifyCctpMsg(cctpMsg, payload);

		uint256 amountIn = IERC20(tokenIn).balanceOf(address(this));
		bool success = cctpTokenMessenger.localMessageTransmitter().receiveMessage(cctpMsg, cctpSigs);
		require(success, 'invalid cctp message');
		amountIn = IERC20(tokenIn).balanceOf(address(this)) - amountIn;

		if (payload.mayanBps > 0) {
			uint256 mayanFee = amountIn * payload.mayanBps / 10000;
			amountIn -= mayanFee;
			// fees remain in the contract
		}

		if (payload.referrerBps > 0) {
			uint256 referrerFee = amountIn * payload.referrerBps / 10000;
			amountIn -= referrerFee;
			IERC20(tokenIn).safeTransfer(truncateAddress(payload.referrerAddr), referrerFee);
		}

		address destAddr = truncateAddress(payload.destAddr);
		address tokenOut = truncateAddress(payload.destToken);
		if (tokenOut == tokenIn) {
			IERC20(tokenIn).safeTransfer(destAddr, amountIn);
			return;
		}

		IERC20(tokenIn).approve(driver, amountIn);
		uint256 amountOut = IERC20(tokenOut).balanceOf(destAddr);
		uint256 gasDrop = destAddr.balance;
		IMctpDriver(driver).mctpSwap(tokenIn, amountIn, tokenOut, payload.promisedAmountOut, payload.gasDrop);

		gasDrop = destAddr.balance - gasDrop;
		require(gasDrop == payload.gasDrop, 'gas drop mismatch');

		amountOut = IERC20(tokenOut).balanceOf(destAddr) - amountOut;
		require(amountOut == payload.promisedAmountOut, 'amount out mismatch');

		emit Fulfilled(vm.sequence);
	}

	function redeem(bytes memory cctpMsg, bytes memory cctpSigs, bytes32 recipient) public payable {
		bool success = cctpTokenMessenger.localMessageTransmitter().receiveMessage(cctpMsg, cctpSigs);
		require(success, 'invalid cctp msg');

		uint32 cctpSourceDomain = cctpMsg.toUint32(4);
		uint32 cctpDestDomain = cctpMsg.toUint32(8);
		uint64 cctpNonce = cctpMsg.toUint64(12);

		/*
		struct transferReceipt {
			uint8 payloadId;
			uint32 sourceDomain;
			uint32 destDomain;
			uint64 nonce;
			bytes32 recipient;
		}
		*/
		bytes memory encoded = abi.encodePacked(uint8(1), cctpSourceDomain, cctpDestDomain, cctpNonce, recipient);

		wormhole.publishMessage{
			value : msg.value
		}(0, encoded, consistencyLevel);
	}

	function verifyCctpMsg(bytes memory cctpMsg, FulFillPayload memory payload) public view returns (address localToken) {
		uint32 cctpSourceDomain = cctpMsg.toUint32(4);
		uint32 cctpDestDomain = cctpMsg.toUint32(8);
		uint64 cctpNonce = cctpMsg.toUint64(12);
		bytes32 cctpSourceToken = cctpMsg.toBytes32(24);

		require(getChainIdFromDomain(cctpSourceDomain) == payload.sourceChainId, 'invalid source chain');
		require(getChainIdFromDomain(cctpDestDomain) == payload.destChainId, 'invalid dest chain');
		require(cctpNonce == payload.cctpNonce, 'invalid cctp nonce');

		localToken = cctpTokenMessenger.localMinter().getLocalToken(cctpSourceDomain, cctpSourceToken);
	}

	function parseFulfillPayload(bytes memory payload) internal pure returns (FulFillPayload memory p) {
		p.payloadId = payload.toUint8(0);
		p.sourceChainId = payload.toUint16(1);
		p.refundAddr = payload.toBytes32(3);
		p.destToken = payload.toBytes32(35);
		p.destChainId = payload.toUint16(67);
		p.destAddr = payload.toBytes32(69);
		p.amountOutMin = payload.toUint64(101);
		p.gasDrop = payload.toUint64(109);
		p.referrerAddr = payload.toBytes32(117);
		p.mayanBps = payload.toUint8(149);
		p.referrerBps = payload.toUint8(150);
		p.cctpNonce = payload.toUint64(151);
		p.settleFee = payload.toUint64(159);
		p.deadline = payload.toUint64(167);
		p.driver = payload.toBytes32(175);
		p.promisedAmountOut = payload.toUint64(207);
	}

	function encodeMctpMsg(MctpStruct memory s) public pure returns(bytes memory encoded) {
		encoded = abi.encodePacked(
			s.payloadId,
			s.sourceChainId,
			s.refundAddr,
			s.destToken,
			s.destChainId,
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

	function setDomainToChainId(uint32 domain, uint16 _chainId) public {
		require(msg.sender == guardian, 'not guardian');
		uint16 chainId = domainToChainId[domain];
		require(chainId == 0, 'domain already set');
		domainToChainId[domain] = _chainId;
	}

	function getChainIdFromDomain(uint32 domain) public view returns (uint16 chainId) {
		chainId = domainToChainId[domain];
		require(chainId != 0, 'invalid domain');
	}

	function truncateAddress(bytes32 b) internal pure returns (address) {
		require(bytes12(b) == 0, 'invalid EVM address');
		return address(uint160(uint256(b)));
	}

	function setPause(bool _pause) public {
		require(msg.sender == guardian, 'only guardian');
		paused = _pause;
	}

	function isPaused() public view returns(bool) {
		return paused;
	}

	function setMayanDefaultBps(uint8 _bps) public {
		require(msg.sender == guardian, 'only guardian');
		require(_bps <= 50, 'bps exceeds 50');
		mayanDefaultBps = _bps;
	}

	function changeGuardian(address newGuardian) public {
		require(msg.sender == guardian, 'only guardian');
		nextGuardian = newGuardian;
	}

	function claimGuardian() public {
		require(msg.sender == nextGuardian, 'only next guardian');
		guardian = nextGuardian;
	}

	function collectFees(address token) public {
		IERC20(token).safeTransfer(mayanFeeCollector, IERC20(token).balanceOf(address(this)));
	}
}