// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libs/BytesLib.sol";
import "./interfaces/CCTP/IReceiver.sol";
import "./interfaces/CCTP/ITokenMessenger.sol";
import "./interfaces/IWormhole.sol";
import "./interfaces/ITokenBridge.sol";
import "./interfaces/IFeeManager.sol";

contract MayanCircle is ReentrancyGuard {
	using SafeERC20 for IERC20;
	using BytesLib for bytes;

	IWormhole public immutable wormhole;
	ITokenMessenger public immutable cctpTokenMessenger;
	IFeeManager public feeManager;

	uint32 public immutable localDomain;
	uint16 public immutable auctionChainId;
	bytes32 public immutable auctionAddr;
	bytes32 public immutable solanaEmitter;
	uint8 public consistencyLevel;
	address public guardian;
	address nextGuardian;
	bool public paused;

	mapping(uint64 => FeeLock) public feeStorage;

	uint8 constant ETH_DECIMALS = 18;
	uint32 constant SOLANA_DOMAIN = 5;
	uint16 constant SOLANA_CHAIN_ID = 1;

	event OrderFulfilled(uint32 sourceDomain, uint64 sourceNonce, uint256 amount);
	event OrderRefunded(uint32 sourceDomain, uint64 sourceNonce, uint256 amount);

	error Paused();
	error Unauthorized();
	error InvalidDomain();
	error InvalidNonce();
	error InvalidOrder();
	error CctpReceiveFailed();
	error InvalidGasDrop();
	error InvalidAction();
	error InvalidEmitter();

	enum Action {
		NONE,
		SWAP,
		FULFILL,
		BRIDGE_WITH_FEE,
		UNLOCK_FEE,
		UNLOCK_FEE_REFINE
	}

	struct Order {
		bytes32 trader;
		uint16 sourceChain;
		bytes32 tokenIn;
		uint64 amountIn;
		bytes32 destAddr;
		uint16 destChain;
		bytes32 tokenOut;
		uint64 minAmountOut;
		uint64 gasDrop;
		uint64 redeemFee;
		uint64 deadline;
		bytes32 referrerAddr;
		uint8 referrerBps;
		uint8 protocolBps;
	}

	struct OrderParams {
		address tokenIn;
		uint256 amountIn;
		uint64 gasDrop;
		bytes32 destAddr;
		uint16 destChain;
		bytes32 tokenOut;
		uint64 minAmountOut;
		uint64 deadline;
		uint64 redeemFee;
		bytes32 referrerAddr;
		uint8 referrerBps;
	}

	struct ExtraParams {
		bytes32 trader;
		uint16 sourceChainId;
		uint8 protocolBps;
	}

	struct OrderMsg {
		uint8 action;
		uint8 payloadId;
		bytes32 orderHash;
	}

	struct FeeLock {
		bytes32 destAddr;
		uint64 gasDrop;
		address token;
		uint256 redeemFee;
	}

	struct CctpRecipient {
		uint32 destDomain;
		bytes32 mintRecipient;
		bytes32 callerAddr;
	}

	struct BridgeWithFeeMsg {
		uint8 action;
		uint8 payloadId;
		uint64 cctpNonce;
		uint32 cctpDomain;
		bytes32 destAddr;
		uint64 gasDrop;
		uint64 redeemFee;
	}

	struct UnlockFeeMsg {
		uint8 action;
		uint8 payloadId;
		uint64 cctpNonce;
		uint32 cctpDomain;
		bytes32 unlockerAddr;
		uint64 gasDrop;
	}

	struct UnlockRefinedFeeMsg {
		uint8 action;
		uint8 payloadId;
		uint64 cctpNonce;
		uint32 cctpDomain;
		bytes32 unlockerAddr;
		uint64 gasDrop;
		bytes32 destAddr;
	}

	struct FulfillMsg {
		uint8 action;
		uint8 payloadId;
		uint16 destChainId;
		bytes32 destAddr;
		bytes32 driver;
		bytes32 tokenOut;
		uint64 promisedAmount;
		uint64 gasDrop;
		bytes32 referrerAddr;
		uint8 referrerBps;
		uint8 protocolBps;
		uint64 deadline;
		uint64 redeemFee;
		uint32 cctpDomain;
		uint64 cctpNonce;
	}

	constructor(
		address _cctpTokenMessenger,
		address _wormhole,
		address _feeManager,
		uint16 _auctionChainId,
		bytes32 _auctionAddr,
		bytes32 _solanaEmitter,
		uint8 _consistencyLevel
	) {
		cctpTokenMessenger = ITokenMessenger(_cctpTokenMessenger);
		wormhole = IWormhole(_wormhole);
		feeManager = IFeeManager(_feeManager);
		auctionChainId = _auctionChainId;
		auctionAddr = _auctionAddr;
		solanaEmitter = _solanaEmitter;
		consistencyLevel = _consistencyLevel;
		localDomain = ITokenMessenger(_cctpTokenMessenger).localMessageTransmitter().localDomain();
		guardian = msg.sender;
	}

	function bridgeWithFee(
		address tokenIn,
		uint256 amountIn,
		uint64 redeemFee,
		uint64 gasDrop,
		bytes32 destAddr,
		CctpRecipient memory recipient
	) external payable nonReentrant returns (uint64 sequence) {
		if (paused) {
			revert Paused();
		}

		uint256 burnAmount = IERC20(tokenIn).balanceOf(address(this));
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		burnAmount = IERC20(tokenIn).balanceOf(address(this)) - burnAmount;

		maxApproveIfNeeded(tokenIn, address(cctpTokenMessenger), burnAmount);
		uint64 ccptNonce = cctpTokenMessenger.depositForBurnWithCaller(burnAmount, recipient.destDomain, recipient.mintRecipient, tokenIn, recipient.callerAddr);

		BridgeWithFeeMsg memory	bridgeMsg = BridgeWithFeeMsg({
			action: uint8(Action.BRIDGE_WITH_FEE),
			payloadId: 1,
			cctpNonce: ccptNonce,
			cctpDomain: localDomain,
			destAddr: destAddr,
			gasDrop: gasDrop,
			redeemFee: redeemFee
		});

		bytes memory encoded = encodeBridgeWithFee(bridgeMsg);

		sequence = wormhole.publishMessage{
			value : msg.value
		}(0, encoded, consistencyLevel);
	}

	function bridgeWithLockedFee(
		address tokenIn,
		uint256 amountIn,
		uint64 gasDrop,
		uint256 redeemFee,
		CctpRecipient memory recipient
	) external nonReentrant returns (uint64 cctpNonce) {
		if (paused) {
			revert Paused();
		}
		if (recipient.destDomain == SOLANA_DOMAIN) {
			revert InvalidDomain();
		}
		require(redeemFee > 0, 'zero redeem fee');

		uint256 burnAmount = IERC20(tokenIn).balanceOf(address(this));
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		burnAmount = IERC20(tokenIn).balanceOf(address(this)) - burnAmount;

		maxApproveIfNeeded(tokenIn, address(cctpTokenMessenger), burnAmount - redeemFee);
		cctpNonce = cctpTokenMessenger.depositForBurnWithCaller(burnAmount - redeemFee, recipient.destDomain, recipient.mintRecipient, tokenIn, recipient.callerAddr);

		feeStorage[cctpNonce] = FeeLock({
			destAddr: recipient.mintRecipient,
			gasDrop: gasDrop,
			token: tokenIn,
			redeemFee: redeemFee
		});
	}

	function createOrder(
		OrderParams memory params,
		CctpRecipient memory recipient
	) external payable nonReentrant {
		if (paused) {
			revert Paused();
		}

		if (params.tokenOut == bytes32(0) && params.gasDrop > 0) {
			revert InvalidGasDrop();
		}

		IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
		maxApproveIfNeeded(params.tokenIn, address(cctpTokenMessenger), params.amountIn);
		uint64 ccptNonce = cctpTokenMessenger.depositForBurnWithCaller(params.amountIn, recipient.destDomain, recipient.mintRecipient, params.tokenIn, recipient.callerAddr);

		require(params.referrerBps <= 50, 'invalid referrer bps');
		uint8 protocolBps = feeManager.calcProtocolBps(uint64(params.amountIn), params.tokenIn, params.tokenOut, params.destChain, params.referrerBps);
		require(protocolBps <= 50, 'invalid protocol bps');

		Order memory order = Order({
			trader: bytes32(uint256(uint160(msg.sender))),
			sourceChain: wormhole.chainId(),
			tokenIn: bytes32(uint256(uint160(params.tokenIn))),
			amountIn: uint64(params.amountIn),
			destAddr: params.destAddr,
			destChain: params.destChain,
			tokenOut: params.tokenOut,
			minAmountOut: params.minAmountOut,
			gasDrop: params.gasDrop,
			redeemFee: params.redeemFee,
			deadline: params.deadline,
			referrerAddr: params.referrerAddr,
			referrerBps: params.referrerBps,
			protocolBps: protocolBps
		});
		
		bytes memory encodedOrder = encodeOrder(order);
		encodedOrder = encodedOrder.concat(abi.encodePacked(ccptNonce, cctpTokenMessenger.localMessageTransmitter().localDomain()));

		bytes32 orderHash = keccak256(encodedOrder);
		OrderMsg memory orderMsg = OrderMsg({
			action: uint8(Action.SWAP),
			payloadId: 1,
			orderHash: orderHash
		});

		bytes memory encodedMsg = encodeOrderMsg(orderMsg);

		wormhole.publishMessage{
			value : msg.value
		}(0, encodedMsg, consistencyLevel);
	}

	function redeemWithFee(bytes memory cctpMsg, bytes memory cctpSigs, bytes memory encodedVm) external nonReentrant payable {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
		require(valid, reason);

		if (vm.emitterAddress != solanaEmitter && truncateAddress(vm.emitterAddress) != address(this)) {
			revert InvalidEmitter(); 
		}

		BridgeWithFeeMsg memory redeemMsg = parseBridgeWithFee(vm.payload);
		if (redeemMsg.action != uint8(Action.BRIDGE_WITH_FEE)) {
			revert InvalidAction();
		}

		uint256 denormalizedGasDrop = deNormalizeAmount(redeemMsg.gasDrop, ETH_DECIMALS);
		if (msg.value != denormalizedGasDrop) {
			revert InvalidGasDrop();
		}

		uint32 cctpSourceDomain = cctpMsg.toUint32(4);
		uint64 cctpNonce = cctpMsg.toUint64(12);
		bytes32 cctpSourceToken = cctpMsg.toBytes32(120);

		if (cctpSourceDomain != redeemMsg.cctpDomain) {
			revert InvalidDomain();
		}
		if (cctpNonce != redeemMsg.cctpNonce) {
			revert InvalidNonce();
		}

		address localToken = cctpTokenMessenger.localMinter().getLocalToken(cctpSourceDomain, cctpSourceToken);
		uint256 amount = IERC20(localToken).balanceOf(address(this));
		bool success = cctpTokenMessenger.localMessageTransmitter().receiveMessage(cctpMsg, cctpSigs);
		if (!success) {
			revert CctpReceiveFailed();
		}
		amount = IERC20(localToken).balanceOf(address(this)) - amount;

		IERC20(localToken).safeTransfer(msg.sender, uint256(redeemMsg.redeemFee));
		address recipient = truncateAddress(redeemMsg.destAddr);
		IERC20(localToken).safeTransfer(recipient, amount - uint256(redeemMsg.redeemFee));
		payable(recipient).transfer(denormalizedGasDrop);
	}

	function redeemWithLockedFee(bytes memory cctpMsg, bytes memory cctpSigs, bytes32 unlockerAddr) external nonReentrant payable returns (uint64 sequence) {
		uint32 cctpSourceDomain = cctpMsg.toUint32(4);
		uint64 cctpNonce = cctpMsg.toUint64(12);
		address caller = truncateAddress(cctpMsg.toBytes32(84));
		require(caller == address(this), 'invalid caller');
		address mintRecipient = truncateAddress(cctpMsg.toBytes32(152));
		require(mintRecipient != address(this), 'invalid mint recipient');

		bool success = cctpTokenMessenger.localMessageTransmitter().receiveMessage(cctpMsg, cctpSigs);
		if (!success) {
			revert CctpReceiveFailed();
		}

		uint256 wormholeFee = wormhole.messageFee();
		payable(mintRecipient).transfer(msg.value - wormholeFee);

		UnlockFeeMsg memory unlockMsg = UnlockFeeMsg({
			action: uint8(Action.UNLOCK_FEE),
			payloadId: 1,
			cctpDomain: cctpSourceDomain,
			cctpNonce: cctpNonce,
			unlockerAddr: unlockerAddr,
			gasDrop: uint64(normalizeAmount(msg.value - wormholeFee, ETH_DECIMALS))
		});

		bytes memory encodedMsg = encodeUnlockFeeMsg(unlockMsg);

		sequence = wormhole.publishMessage{
			value : wormholeFee
		}(0, encodedMsg, consistencyLevel);
	}

	function refineFee(uint32 cctpNonce, uint32 cctpDomain, bytes32 destAddr, bytes32 unlockerAddr) external nonReentrant payable returns (uint64 sequence) {
		uint256 wormholeFee = wormhole.messageFee();
		payable(truncateAddress(destAddr)).transfer(msg.value - wormholeFee);

		UnlockRefinedFeeMsg memory unlockMsg = UnlockRefinedFeeMsg({
			action: uint8(Action.UNLOCK_FEE_REFINE),
			payloadId: 1,
			cctpDomain: cctpDomain,
			cctpNonce: cctpNonce,
			unlockerAddr: unlockerAddr,
			gasDrop: uint64(normalizeAmount(msg.value - wormholeFee, ETH_DECIMALS)),
			destAddr: destAddr
		});

		bytes memory encodedMsg = encodeUnlockRefinedFeeMsg(unlockMsg);

		sequence = wormhole.publishMessage{
			value : wormholeFee
		}(0, encodedMsg, consistencyLevel);
	}

	function unlockFee(bytes memory encodedVm) public nonReentrant {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
		require(valid, reason);

		if (vm.emitterChainId == SOLANA_CHAIN_ID) {
			require(vm.emitterAddress == solanaEmitter, 'invalid solana emitter');
		} else {
			require(truncateAddress(vm.emitterAddress) == address(this), 'invalid evm emitter');
		}

		UnlockFeeMsg memory unlockMsg = parseUnlockFeeMsg(vm.payload);
		if (unlockMsg.action != uint8(Action.UNLOCK_FEE)) {
			revert InvalidAction();
		}
		if (unlockMsg.cctpDomain != localDomain) {
			revert InvalidDomain();
		}

		FeeLock memory feeLock = feeStorage[unlockMsg.cctpNonce];
		require(feeLock.redeemFee > 0, 'fee not locked');

		if (unlockMsg.gasDrop < feeLock.gasDrop) {
			revert InvalidGasDrop();
		}
		IERC20(feeLock.token).safeTransfer(truncateAddress(unlockMsg.unlockerAddr), feeLock.redeemFee);
		delete feeStorage[unlockMsg.cctpNonce];
	}

	function unlockFeeRefined(bytes memory encodedVm1, bytes memory encodedVm2) public nonReentrant {
		(IWormhole.VM memory vm1, bool valid1, string memory reason1) = wormhole.parseAndVerifyVM(encodedVm1);
		require(valid1, reason1);

		if (vm1.emitterAddress != solanaEmitter && truncateAddress(vm1.emitterAddress) != address(this)) {
			revert InvalidEmitter();
		}

		UnlockFeeMsg memory unlockMsg = parseUnlockFeeMsg(vm1.payload);
		if (unlockMsg.action != uint8(Action.UNLOCK_FEE_REFINE)) {
			revert InvalidAction();
		}
		if (unlockMsg.cctpDomain != localDomain) {
			revert InvalidDomain();
		}

		FeeLock memory feeLock = feeStorage[unlockMsg.cctpNonce];
		require(feeLock.redeemFee > 0, 'fee not locked');
		require(unlockMsg.gasDrop < feeLock.gasDrop, 'gas was sufficient');

		(IWormhole.VM memory vm2, bool valid2, string memory reason2) = wormhole.parseAndVerifyVM(encodedVm2);
		require(valid2, reason2);

		if (vm2.emitterAddress != solanaEmitter && truncateAddress(vm2.emitterAddress) != address(this)) {
			revert InvalidEmitter();
		}

		UnlockRefinedFeeMsg memory refinedMsg = parseUnlockRefinedFee(vm1.payload);

		require(refinedMsg.destAddr == feeLock.destAddr, 'invalid dest addr');
		if (refinedMsg.cctpNonce != unlockMsg.cctpNonce) {
			revert InvalidNonce();
		}
		if (refinedMsg.cctpDomain != unlockMsg.cctpDomain) {
			revert InvalidDomain();
		}
		if (refinedMsg.gasDrop + unlockMsg.gasDrop < feeLock.gasDrop) {
			revert InvalidGasDrop();
		}

		IERC20(feeLock.token).safeTransfer(truncateAddress(refinedMsg.unlockerAddr), feeLock.redeemFee);
		delete feeStorage[unlockMsg.cctpNonce];
	}

	function fulfillOrder(
		bytes memory cctpMsg,
		bytes memory cctpSigs,
		bytes memory encodedVm,
		address swapProtocol,
		bytes memory swapData
	) public nonReentrant payable {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
		require(valid, reason);

		require(vm.emitterChainId == SOLANA_CHAIN_ID, 'invalid emitter chain');
		require(vm.emitterAddress == auctionAddr, 'invalid solana emitter');

		FulfillMsg memory fulfillMsg = parseFulfillMsg(vm.payload);
		require(fulfillMsg.deadline >= block.timestamp, 'deadline passed');
		require(msg.sender == truncateAddress(fulfillMsg.driver), 'invalid driver');

		uint32 cctpSourceDomain = cctpMsg.toUint32(4);
		uint64 cctpSourceNonce = cctpMsg.toUint64(12);
		bytes32 cctpSourceToken = cctpMsg.toBytes32(120);

		require(cctpSourceDomain == fulfillMsg.cctpDomain, 'invalid cctp domain');
		require(cctpSourceNonce == fulfillMsg.cctpNonce, 'invalid cctp nonce');

		(address localToken, uint256 cctpAmount) = receiveCctp(cctpMsg, cctpSigs, cctpSourceDomain, cctpSourceToken);

		if (fulfillMsg.redeemFee > 0) {
			IERC20(localToken).transfer(msg.sender, fulfillMsg.redeemFee);
		}

		address tokenOut = truncateAddress(fulfillMsg.tokenOut);
		maxApproveIfNeeded(localToken, swapProtocol, cctpAmount - uint256(fulfillMsg.redeemFee));

		uint256 amountOut;
		if (tokenOut == address(0)) {
			amountOut = address(this).balance;
		} else {
			amountOut = IERC20(tokenOut).balanceOf(address(this));
		}

		(bool swapSuccess, bytes memory swapReturn) = swapProtocol.call{value: 0}(swapData);
		require(swapSuccess, string(swapReturn));

		if (tokenOut == address(0)) {
			amountOut = address(this).balance - amountOut;
		} else {
			amountOut = IERC20(tokenOut).balanceOf(address(this)) - amountOut;
		}

		uint8 decimals;
		if (tokenOut == address(0)) {
			decimals = ETH_DECIMALS;
		} else {
			decimals = decimalsOf(tokenOut);
		}

		uint256 promisedAmount = deNormalizeAmount(fulfillMsg.promisedAmount, decimals);
		require(amountOut >= promisedAmount, 'insufficient amount out');

		makePayments(
			fulfillMsg,
			tokenOut,
			amountOut
		);

		emit OrderFulfilled(cctpSourceDomain, cctpSourceNonce, amountOut);
	}

	function refund(
		bytes memory encodedVm,
		bytes memory cctpMsg,
		bytes memory cctpSigs,
		OrderParams memory orderParams,
		ExtraParams memory extraParams
	) public nonReentrant payable {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
		require(valid, reason);

		if (vm.emitterAddress != solanaEmitter && truncateAddress(vm.emitterAddress) != address(this)) {
			revert InvalidEmitter();
		}

		uint32 cctpSourceDomain = cctpMsg.toUint32(4);
		uint64 cctpSourceNonce = cctpMsg.toUint64(12);
		bytes32 cctpSourceToken = cctpMsg.toBytes32(120);

		(address localToken, uint256 amount) = receiveCctp(cctpMsg, cctpSigs, cctpSourceDomain, cctpSourceToken);

		Order memory order = recreateOrder(cctpSourceToken, uint64(amount), orderParams, extraParams);
		
		bytes memory encodedOrder = encodeOrder(order);
		encodedOrder = encodedOrder.concat(abi.encodePacked(cctpSourceNonce, cctpSourceDomain));
		bytes32 calculatedHash = keccak256(encodedOrder);

		OrderMsg memory orderMsg = parseOrderMsg(vm.payload);
		if (orderMsg.action != uint8(Action.SWAP)) {
			revert InvalidAction();
		}
		if (calculatedHash != orderMsg.orderHash) {
			revert InvalidOrder();
		}

		require(order.deadline < block.timestamp, 'deadline not passed');

		uint256 gasDrop = deNormalizeAmount(order.gasDrop, ETH_DECIMALS);
		if (msg.value != gasDrop) {
			revert InvalidGasDrop();
		}

		address destAddr = truncateAddress(order.destAddr);
		if (gasDrop > 0) {
			payable(destAddr).transfer(gasDrop);
		}

		IERC20(localToken).safeTransfer(msg.sender, order.redeemFee);
		IERC20(localToken).safeTransfer(destAddr, amount - order.redeemFee);

		emit OrderRefunded(cctpSourceDomain, cctpSourceNonce, amount);
	}

	function receiveCctp(bytes memory cctpMsg, bytes memory cctpSigs, uint32 cctpSourceDomain, bytes32 cctpSourceToken) internal returns (address, uint256) {
		address localToken = cctpTokenMessenger.localMinter().getLocalToken(cctpSourceDomain, cctpSourceToken);

		uint256 amount = IERC20(localToken).balanceOf(address(this));
		bool success = cctpTokenMessenger.localMessageTransmitter().receiveMessage(cctpMsg, cctpSigs);
		if (!success) {
			revert CctpReceiveFailed();
		}
		amount = IERC20(localToken).balanceOf(address(this)) - amount;
		return (localToken, amount);
	}

	function makePayments(
		FulfillMsg memory fulfillMsg,
		address tokenOut,
		uint256 amount
		) internal {
		address referrerAddr = truncateAddress(fulfillMsg.referrerAddr);
		uint256 referrerAmount = 0;
		if (referrerAddr != address(0) && fulfillMsg.referrerBps != 0) {
			referrerAmount = amount * fulfillMsg.referrerBps / 10000;
		}

		uint256 protocolAmount = 0;
		if (fulfillMsg.protocolBps != 0) {
			protocolAmount = amount * fulfillMsg.protocolBps / 10000;
		}

		address destAddr = truncateAddress(fulfillMsg.destAddr);
		if (tokenOut == address(0)) {
			if (referrerAmount > 0) {
				payable(referrerAddr).transfer(referrerAmount);
			}
			if (protocolAmount > 0) {
				payable(feeManager.feeCollector()).transfer(protocolAmount);
			}
			payable(destAddr).transfer(amount - referrerAmount - protocolAmount);
		} else {
			if (fulfillMsg.gasDrop > 0) {
				uint256 gasDrop = deNormalizeAmount(fulfillMsg.gasDrop, ETH_DECIMALS);
				if (msg.value != gasDrop) {
					revert InvalidGasDrop();
				}
				payable(destAddr).transfer(gasDrop);
			}
			if (referrerAmount > 0) {
				IERC20(tokenOut).safeTransfer(referrerAddr, referrerAmount);
			}
			if (protocolAmount > 0) {
				IERC20(tokenOut).safeTransfer(feeManager.feeCollector(), protocolAmount);
			}
			IERC20(tokenOut).safeTransfer(destAddr, amount - referrerAmount - protocolAmount);
		}
	}

	function recreateOrder(
		bytes32 cctpSourceToken,
		uint64 amountIn,
		OrderParams memory params,
		ExtraParams memory extraParams
	) internal pure returns (Order memory) {
		return Order({
			trader: extraParams.trader,
			sourceChain: extraParams.sourceChainId,
			tokenIn: cctpSourceToken,
			amountIn: amountIn,
			destAddr: params.destAddr,
			destChain: params.destChain,
			tokenOut: params.tokenOut,
			minAmountOut: params.minAmountOut,
			gasDrop: params.gasDrop,
			redeemFee: params.redeemFee,
			deadline: params.deadline,
			referrerAddr: params.referrerAddr,
			referrerBps: params.referrerBps,
			protocolBps: extraParams.protocolBps
		});
	}

	function encodeBridgeWithFee(BridgeWithFeeMsg memory bridgeMsg) internal pure returns (bytes memory) {
		return abi.encodePacked(
			bridgeMsg.action,
			bridgeMsg.payloadId,
			bridgeMsg.cctpNonce,
			bridgeMsg.cctpDomain,
			bridgeMsg.destAddr,
			bridgeMsg.gasDrop,
			bridgeMsg.redeemFee
		);
	}

	function parseBridgeWithFee(bytes memory payload) internal pure returns (BridgeWithFeeMsg memory) {
		return BridgeWithFeeMsg({
			action: payload.toUint8(0),
			payloadId: payload.toUint8(1),
			cctpNonce: payload.toUint64(2),
			cctpDomain: payload.toUint32(10),
			destAddr: payload.toBytes32(14),
			gasDrop: payload.toUint64(46),
			redeemFee: payload.toUint64(54)
		});
	}

	function encodeUnlockFeeMsg(UnlockFeeMsg memory unlockMsg) internal pure returns (bytes memory) {
		return abi.encodePacked(
			unlockMsg.action,
			unlockMsg.payloadId,
			unlockMsg.cctpNonce,
			unlockMsg.cctpDomain,
			unlockMsg.unlockerAddr,
			unlockMsg.gasDrop
		);
	}

	function encodeUnlockRefinedFeeMsg(UnlockRefinedFeeMsg memory unlockMsg) internal pure returns (bytes memory) {
		return abi.encodePacked(
			unlockMsg.action,
			unlockMsg.payloadId,
			unlockMsg.cctpNonce,
			unlockMsg.cctpDomain,
			unlockMsg.unlockerAddr,
			unlockMsg.gasDrop,
			unlockMsg.destAddr
		);
	}

	function parseFulfillMsg(bytes memory encoded) public pure returns (FulfillMsg memory fulfillMsg) {
		uint index = 0;

		fulfillMsg.action = encoded.toUint8(index);
		index += 1;

		if (fulfillMsg.action != uint8(Action.FULFILL)) {
			revert InvalidAction();
		}

		fulfillMsg.payloadId = encoded.toUint8(index);
		index += 1;

		fulfillMsg.destChainId = encoded.toUint16(index);
		index += 2;

		fulfillMsg.destAddr = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.driver = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.tokenOut = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.promisedAmount = encoded.toUint64(index);
		index += 8;

		fulfillMsg.gasDrop = encoded.toUint64(index);
		index += 8;

		fulfillMsg.referrerAddr = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.referrerBps = encoded.toUint8(index);
		index += 1;

		fulfillMsg.protocolBps = encoded.toUint8(index);
		index += 1;

		fulfillMsg.deadline = encoded.toUint64(index);
		index += 8;

		fulfillMsg.redeemFee = encoded.toUint64(index);
		index += 8;

		fulfillMsg.cctpDomain = encoded.toUint32(index);
		index += 4;

		fulfillMsg.cctpNonce = encoded.toUint64(index);
		index += 8;
	}

	function parseOrderMsg(bytes memory payload) internal pure returns (OrderMsg memory) {
		return OrderMsg({
			action: payload.toUint8(0),
			payloadId: payload.toUint8(1),
			orderHash: payload.toBytes32(2)
		});
	}

	function parseUnlockFeeMsg(bytes memory payload) internal pure returns (UnlockFeeMsg memory) {
		return UnlockFeeMsg({
			action: payload.toUint8(0),
			payloadId: payload.toUint8(1),
			cctpNonce: payload.toUint64(2),
			cctpDomain: payload.toUint32(10),
			unlockerAddr: payload.toBytes32(14),
			gasDrop: payload.toUint64(46)
		});
	}

	function parseUnlockRefinedFee(bytes memory payload) internal pure returns (UnlockRefinedFeeMsg memory) {
		return UnlockRefinedFeeMsg({
			action: payload.toUint8(0),
			payloadId: payload.toUint8(1),
			cctpNonce: payload.toUint64(2),
			cctpDomain: payload.toUint32(10),
			unlockerAddr: payload.toBytes32(14),
			gasDrop: payload.toUint64(46),
			destAddr: payload.toBytes32(54)
		});
	}

	function encodeOrder(Order memory order) internal pure returns (bytes memory) {
		return abi.encodePacked(
			order.trader,
			order.sourceChain,
			order.tokenIn,
			order.amountIn,
			order.destAddr,
			order.destChain,
			order.tokenOut,
			order.minAmountOut,
			order.gasDrop,
			order.redeemFee,
			order.deadline,
			order.referrerAddr,
			order.referrerBps,
			order.protocolBps
		);
	}

	function encodeOrderMsg(OrderMsg memory orderMsg) internal pure returns (bytes memory) {
		return abi.encodePacked(
			orderMsg.action,
			orderMsg.payloadId,
			orderMsg.orderHash
		);
	}

	function maxApproveIfNeeded(address tokenAddr, address spender, uint256 amount) internal {
		IERC20 token = IERC20(tokenAddr);
		uint256 currentAllowance = token.allowance(address(this), spender);

		if (currentAllowance < amount) {
			token.safeApprove(spender, 0);
			token.safeApprove(spender, type(uint256).max);
		}
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

	function truncateAddress(bytes32 b) internal pure returns (address) {
		require(bytes12(b) == 0, 'invalid EVM address');
		return address(uint160(uint256(b)));
	}

	function setFeeManager(address _feeManager) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		feeManager = IFeeManager(_feeManager);
	}	

	function setConsistencyLevel(uint8 _consistencyLevel) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		consistencyLevel = _consistencyLevel;
	}

	function setPause(bool _pause) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		paused = _pause;
	}

	function isPaused() public view returns(bool) {
		return paused;
	}

	function rescueToken(address token, uint256 amount, address to) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		IERC20(token).safeTransfer(to, amount);
	}

	function rescueEth(uint256 amount, address payable to) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		require(to != address(0), 'transfer to the zero address');
		to.transfer(amount);
	}

	function changeGuardian(address newGuardian) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		nextGuardian = newGuardian;
	}

	function claimGuardian() public {
		if (msg.sender != nextGuardian) {
			revert Unauthorized();
		}
		guardian = nextGuardian;
	}

	receive() external payable {}
}