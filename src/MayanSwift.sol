// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IWormhole.sol";
import "./interfaces/IFeeManager.sol";
import "./libs/BytesLib.sol";
import "./libs/SignatureVerifier.sol";

contract MayanSwift is ReentrancyGuard {
	event OrderCreated(bytes32 key);
	event OrderFulfilled(bytes32 key, uint64 sequence, uint256 netAmount);
	event OrderUnlocked(bytes32 key);
	event OrderCanceled(bytes32 key, uint64 sequence);
	event OrderRefunded(bytes32 key, uint256 netAmount);

	using SafeERC20 for IERC20;
	using BytesLib for bytes;
	using SignatureVerifier for bytes;

	uint16 constant SOLANA_CHAIN_ID = 1;
	uint8 constant BPS_FEE_LIMIT = 50;
	uint8 constant NATIVE_DECIMALS = 18;

	IWormhole public immutable wormhole;
	uint16 public immutable auctionChainId;
	bytes32 public immutable auctionAddr;
	bytes32 public immutable solanaEmitter;
	IFeeManager public feeManager;
	uint8 public consistencyLevel;
	address public guardian;
	address public nextGuardian;
	bool public paused;

	bytes32 private domainSeparator;

	mapping(bytes32 => Order) public orders;
	mapping(bytes32 => UnlockMsg) public unlockMsgs;


	error Paused();
	error Unauthorized();
	error InvalidAction();
	error InvalidBpsFee();
	error InvalidOrderStatus();
	error InvalidOrderHash();
	error InvalidEmitterChain();
	error InvalidEmitterAddress();
	error InvalidSrcChain();
	error OrderNotExists();
	error SmallAmountIn();
	error FeesTooHigh();
	error InvalidGasDrop();
	error InvalidDestChain();
	error DuplicateOrder();
	error InvalidAmount();
	error DeadlineViolation();
	error InvalidWormholeFee();
	error InvalidAuctionMode();
	error InvalidEvmAddr();

	struct Order {
		Status status;
		uint64 amountIn;
		uint16 destChainId;
	}

	struct OrderParams {
		bytes32 trader;
		bytes32 tokenOut;
		uint64 minAmountOut;
		uint64 gasDrop;
		uint64 cancelFee;
		uint64 refundFee;
		uint64 deadline;
		bytes32 destAddr;
		uint16 destChainId;
		bytes32 referrerAddr;
		uint8 referrerBps;
		uint8 auctionMode;
		bytes32 random;
	}

	struct PermitParams {
		uint256 value;
		uint256 deadline;
		uint8 v;
		bytes32 r;
		bytes32 s;
	}

	struct Key {
		bytes32 trader;
		uint16 srcChainId;
		bytes32 tokenIn;
		bytes32 destAddr;
		uint16 destChainId;
		bytes32 tokenOut;
		uint64 minAmountOut;
		uint64 gasDrop;
		uint64 cancelFee;
		uint64 refundFee;
		uint64 deadline;
		bytes32 referrerAddr;
		uint8 referrerBps;
		uint8 protocolBps;
		uint8 auctionMode;
		bytes32 random;
	}

	struct PaymentParams {
		address destAddr;
		address tokenOut;
		uint64 promisedAmount;
		uint64 gasDrop;
		address referrerAddr;
		uint8 referrerBps;
		uint8 protocolBps;
		bool batch;
	}

	enum Status {
		CREATED,
		FULFILLED,
		UNLOCKED,
		CANCELED,
		REFUNDED
	}

	enum Action {
		NONE,
		FULFILL,
		UNLOCK,
		REFUND,
		BATCH_UNLOCK
	}

	enum AuctionMode {
		NONE,
		BYPASS,
		ENGLISH
	}

	struct UnlockMsg {
		uint8 action;
		bytes32 orderHash;
		uint16 srcChainId;
		bytes32 tokenIn;
		bytes32 recipient;
	}

	struct RefundMsg {
		uint8 action;
		bytes32 orderHash;
		uint16 srcChainId;
		bytes32 tokenIn;
		bytes32 recipient;
		bytes32 canceler;
		uint64 cancelFee;
		uint64 refundFee;	
	}

	struct FulfillMsg {
		uint8 action;
		bytes32 orderHash;
		uint16 destChainId;
		bytes32 destAddr;
		bytes32 driver;
		bytes32 tokenOut;
		uint64 promisedAmount;
		uint64 gasDrop;
		uint64 deadline;
		bytes32 referrerAddr;
		uint8 referrerBps;
		uint8 protocolBps;
		uint16 srcChainId;
		bytes32 tokenIn;
	}

	struct TransferParams {
		address from;
		uint256 validAfter;
		uint256 validBefore;
	}

	constructor(
		address _wormhole,
		address _feeManager,
		uint16 _auctionChainId,
		bytes32 _auctionAddr,
		bytes32 _solanaEmitter,
		uint8 _consistencyLevel
	) {
		guardian = msg.sender;
		wormhole = IWormhole(_wormhole);
		feeManager = IFeeManager(_feeManager);
		auctionChainId = _auctionChainId;
		auctionAddr = _auctionAddr;
		solanaEmitter = _solanaEmitter;
		consistencyLevel = _consistencyLevel;

		domainSeparator = keccak256(abi.encode(
			keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
			keccak256("Mayan Swift"),
			uint256(block.chainid),
			address(this)
		));
	}

	function createOrderWithEth(OrderParams memory params) nonReentrant external payable returns (bytes32 orderHash) {
		if (paused) {
			revert Paused();
		}

		uint64 normlizedAmountIn = uint64(normalizeAmount(msg.value, NATIVE_DECIMALS));
		if (normlizedAmountIn == 0) {
			revert SmallAmountIn();
		}
		if (params.cancelFee + params.refundFee >= normlizedAmountIn) {
			revert FeesTooHigh();
		}

		if (params.tokenOut == bytes32(0) && params.gasDrop != 0) {
			revert InvalidGasDrop();
		}

		uint8 protocolBps = feeManager.calcProtocolBps(normlizedAmountIn, address(0), params.tokenOut, params.destChainId, params.referrerBps);
		if (params.referrerBps > BPS_FEE_LIMIT || protocolBps > BPS_FEE_LIMIT) {
			revert InvalidBpsFee();
		}

		Key memory key = buildKey(params, bytes32(0), wormhole.chainId(), protocolBps);

		orderHash = keccak256(encodeKey(key));

		if (params.destChainId == 0 || params.destChainId == wormhole.chainId()) {
			revert InvalidDestChain();
		}
		if (orders[orderHash].destChainId != 0) {
			revert DuplicateOrder();
		}

		orders[orderHash] = Order({
			status: Status.CREATED,
			amountIn: normlizedAmountIn,
			destChainId: params.destChainId
		});
		
		emit OrderCreated(orderHash);
	}

	function createOrderWithToken(
		address tokenIn,
		uint256 amountIn,
		OrderParams memory params
	) nonReentrant external returns (bytes32 orderHash) {
		if (paused) {
			revert Paused();
		}

		amountIn = pullTokensFrom(tokenIn, amountIn, msg.sender);
		uint64 normlizedAmountIn = uint64(normalizeAmount(amountIn, decimalsOf(tokenIn)));
		if (normlizedAmountIn == 0) {
			revert SmallAmountIn();
		}
		if (params.cancelFee + params.refundFee >= normlizedAmountIn) {
			revert FeesTooHigh();
		}
		if (params.tokenOut == bytes32(0) && params.gasDrop != 0) {
			revert InvalidGasDrop();
		}

		uint8 protocolBps = feeManager.calcProtocolBps(normlizedAmountIn, tokenIn, params.tokenOut, params.destChainId, params.referrerBps);
		if (params.referrerBps > BPS_FEE_LIMIT || protocolBps > BPS_FEE_LIMIT) {
			revert InvalidBpsFee();
		}

		Key memory key = buildKey(params, bytes32(uint256(uint160(tokenIn))), wormhole.chainId(), protocolBps);

		orderHash = keccak256(encodeKey(key));

		if (params.destChainId == 0 || params.destChainId == wormhole.chainId()) {
			revert InvalidDestChain();
		}
		if (orders[orderHash].destChainId != 0) {
			revert DuplicateOrder();
		}

		orders[orderHash] = Order({
			status: Status.CREATED,
			amountIn: normlizedAmountIn,
			destChainId: params.destChainId
		});

		emit OrderCreated(orderHash);
	}

	function createOrderWithSig(
		address tokenIn,
		uint256 amountIn,
		OrderParams memory params,
		uint256 submissionFee,
		bytes calldata signedOrderHash,
		PermitParams calldata permitParams
	) nonReentrant external returns (bytes32 orderHash) {
		if (paused) {
			revert Paused();
		}

		address trader = truncateAddress(params.trader);
		uint256 allowance = IERC20(tokenIn).allowance(trader, address(this));
		if (allowance < amountIn + submissionFee) {
			execPermit(tokenIn, trader, permitParams);
		}
		amountIn = pullTokensFrom(tokenIn, amountIn, trader);
		if (submissionFee > 0) {
			IERC20(tokenIn).safeTransferFrom(trader, msg.sender, submissionFee);
		}

		uint64 normlizedAmountIn = uint64(normalizeAmount(amountIn, decimalsOf(tokenIn)));
		if (normlizedAmountIn == 0) {
			revert SmallAmountIn();
		}

		if (params.cancelFee + params.refundFee >= normlizedAmountIn) {
			revert FeesTooHigh();
		}
		if (params.tokenOut == bytes32(0) && params.gasDrop != 0) {
			revert InvalidGasDrop();
		}

		uint8 protocolBps = feeManager.calcProtocolBps(normlizedAmountIn, tokenIn, params.tokenOut, params.destChainId, params.referrerBps);
		if (params.referrerBps > BPS_FEE_LIMIT || protocolBps > BPS_FEE_LIMIT) {
			revert InvalidBpsFee();
		}

		orderHash = keccak256(encodeKey(buildKey(params, bytes32(uint256(uint160(tokenIn))), wormhole.chainId(), protocolBps)));

		signedOrderHash.verify(hashTypedData(orderHash, amountIn, submissionFee), trader);

		if (params.destChainId == 0 || params.destChainId == wormhole.chainId()) {
			revert InvalidDestChain();
		}
		if (orders[orderHash].destChainId != 0) {
			revert DuplicateOrder();
		}

		orders[orderHash] = Order({
			status: Status.CREATED,
			amountIn: normlizedAmountIn,
			destChainId: params.destChainId
		});

		emit OrderCreated(orderHash);
	}

	function fulfillOrder(
		uint256 fulfillAmount,
		bytes memory encodedVm,
		bytes32 recepient,
		bool batch
	) nonReentrant public payable returns (uint64 sequence) {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);
		if (vm.emitterChainId != auctionChainId) {
			revert InvalidEmitterChain();
		}
		if (vm.emitterAddress != auctionAddr) {
			revert InvalidEmitterAddress();
		}

		FulfillMsg memory fulfillMsg = parseFulfillPayload(vm.payload);

		address tokenOut = truncateAddress(fulfillMsg.tokenOut);
		if (tokenOut != address(0)) {
			fulfillAmount = pullTokensFrom(tokenOut, fulfillAmount, msg.sender);
		}

		if (fulfillMsg.destChainId != wormhole.chainId()) {
			revert InvalidDestChain();
		}
		if (truncateAddress(fulfillMsg.driver) != tx.origin) {
			revert Unauthorized();
		}

		if (block.timestamp > fulfillMsg.deadline) {
			revert DeadlineViolation();
		}

		if (orders[fulfillMsg.orderHash].status != Status.CREATED) {
			revert InvalidOrderStatus();
		}
		orders[fulfillMsg.orderHash].status = Status.FULFILLED;

		PaymentParams memory paymentParams = PaymentParams({
			destAddr: truncateAddress(fulfillMsg.destAddr),
			tokenOut: tokenOut,
			promisedAmount: fulfillMsg.promisedAmount,
			gasDrop: fulfillMsg.gasDrop,
			referrerAddr: truncateAddress(fulfillMsg.referrerAddr),
			referrerBps: fulfillMsg.referrerBps,
			protocolBps: fulfillMsg.protocolBps,
			batch: batch
		});
		uint256 netAmount = makePayments(fulfillAmount, paymentParams);

		UnlockMsg memory unlockMsg = UnlockMsg({
			action: uint8(Action.UNLOCK),
			orderHash: fulfillMsg.orderHash,
			srcChainId: fulfillMsg.srcChainId,
			tokenIn: fulfillMsg.tokenIn,
			recipient: recepient
		});

		if (batch) {
			unlockMsgs[fulfillMsg.orderHash] = unlockMsg;
		} else {
			bytes memory encoded = encodeUnlockMsg(unlockMsg);
			sequence = wormhole.publishMessage{
				value : wormhole.messageFee()
			}(0, encoded, consistencyLevel);
		}

		emit OrderFulfilled(fulfillMsg.orderHash, sequence, netAmount);
	}

	function fulfillSimple(
		uint256 fulfillAmount,
		bytes32 orderHash,
		uint16 srcChainId,
		bytes32 tokenIn,
		uint8 protocolBps,
		OrderParams memory params,
		bytes32 recepient,
		bool batch
	) public nonReentrant payable returns (uint64 sequence) {
		if (params.auctionMode != uint8(AuctionMode.BYPASS)) {
			revert InvalidAuctionMode();
		}

		address tokenOut = truncateAddress(params.tokenOut);
		if (tokenOut != address(0)) {
			fulfillAmount = pullTokensFrom(tokenOut, fulfillAmount, msg.sender);
		}	

		params.destChainId = wormhole.chainId();
		Key memory key = buildKey(params, tokenIn, srcChainId, protocolBps);

		bytes32 computedOrderHash = keccak256(encodeKey(key));

		if (computedOrderHash != orderHash) {
			revert InvalidOrderHash();
		}

		if (block.timestamp > key.deadline) {
			revert DeadlineViolation();
		}

		if (orders[computedOrderHash].status != Status.CREATED) {
			revert InvalidOrderStatus();
		}
		orders[computedOrderHash].status = Status.FULFILLED;

		PaymentParams memory paymentParams = PaymentParams({
			destAddr: truncateAddress(key.destAddr),
			tokenOut: tokenOut,
			promisedAmount: key.minAmountOut,
			gasDrop: key.gasDrop,
			referrerAddr: truncateAddress(key.referrerAddr),
			referrerBps: key.referrerBps,
			protocolBps: protocolBps,
			batch: batch
		});
		uint256 netAmount = makePayments(fulfillAmount, paymentParams);

		UnlockMsg memory unlockMsg = UnlockMsg({
			action: uint8(Action.UNLOCK),
			orderHash: computedOrderHash,
			srcChainId: key.srcChainId,
			tokenIn: key.tokenIn,
			recipient: recepient
		});

		if (batch) {
			unlockMsgs[computedOrderHash] = unlockMsg;
		} else {
			bytes memory encoded = encodeUnlockMsg(unlockMsg);
			sequence = wormhole.publishMessage{
				value : wormhole.messageFee()
			}(0, encoded, consistencyLevel);
		}

		emit OrderFulfilled(computedOrderHash, sequence, netAmount);
	}

	function unlockOrder(UnlockMsg memory unlockMsg, Order memory order) internal {
		if (unlockMsg.srcChainId != wormhole.chainId()) {
			revert InvalidSrcChain();
		}
		if (order.destChainId == 0) {
			revert OrderNotExists();
		}
		if (order.status != Status.CREATED) {
			revert InvalidOrderStatus();
		}
		orders[unlockMsg.orderHash].status = Status.UNLOCKED;
		
		address recipient = truncateAddress(unlockMsg.recipient);
		address tokenIn = truncateAddress(unlockMsg.tokenIn);
		uint8 decimals;
		if (tokenIn == address(0)) {
			decimals = NATIVE_DECIMALS;
		} else {
			decimals = decimalsOf(tokenIn);
		}

		uint256 amountIn = deNormalizeAmount(order.amountIn, decimals);
		if (tokenIn == address(0)) {
			payViaCall(recipient, amountIn);
		} else {
			IERC20(tokenIn).safeTransfer(recipient, amountIn);
		}
		
		emit OrderUnlocked(unlockMsg.orderHash);
	}

	function cancelOrder(
		bytes32 tokenIn,
		OrderParams memory params,
		uint16 srcChainId,
		uint8 protocolBps,
		bytes32 canceler
	) public nonReentrant payable returns (uint64 sequence) {

		params.destChainId = wormhole.chainId();
		Key memory key = buildKey(params, tokenIn, srcChainId, protocolBps);

		bytes32 orderHash = keccak256(encodeKey(key));
		Order memory order = orders[orderHash];

		if (block.timestamp <= key.deadline) {
			revert DeadlineViolation();
		}

		if (order.status != Status.CREATED) {
			revert InvalidOrderStatus();
		}
		orders[orderHash].status = Status.CANCELED;

		RefundMsg memory refundMsg = RefundMsg({
			action: uint8(Action.REFUND),
			orderHash: orderHash,
			srcChainId: key.srcChainId,
			tokenIn: key.tokenIn,
			recipient: key.trader,
			canceler: canceler,
			cancelFee: key.cancelFee,
			refundFee: key.refundFee
		});

		bytes memory encoded = encodeRefundMsg(refundMsg);

		sequence = wormhole.publishMessage{
			value : msg.value
		}(0, encoded, consistencyLevel);

		emit OrderCanceled(orderHash, sequence);
	}

	function refundOrder(bytes memory encodedVm) nonReentrant() public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);

		RefundMsg memory refundMsg = parseRefundPayload(vm.payload);
		Order memory order = orders[refundMsg.orderHash];

		if (refundMsg.srcChainId != wormhole.chainId()) {
			revert InvalidSrcChain();
		}
		if (order.destChainId == 0) {
			revert OrderNotExists();
		}
		if (order.status != Status.CREATED) {
			revert InvalidOrderStatus();
		}
		orders[refundMsg.orderHash].status = Status.REFUNDED;

		if (vm.emitterChainId != order.destChainId) {
			revert InvalidEmitterChain();
		}
		if (vm.emitterAddress != solanaEmitter && truncateAddress(vm.emitterAddress) != address(this)) {
			revert InvalidEmitterAddress();
		}

		address recipient = truncateAddress(refundMsg.recipient);
		// no error if canceler is invalid
		address canceler = address(uint160(uint256(refundMsg.canceler)));
		address tokenIn = truncateAddress(refundMsg.tokenIn);
		
		uint8 decimals;
		if (tokenIn == address(0)) {
			decimals = NATIVE_DECIMALS;
		} else {
			decimals = decimalsOf(tokenIn);
		}

		uint256 cancelFee = deNormalizeAmount(refundMsg.cancelFee, decimals);
		uint256 refundFee = deNormalizeAmount(refundMsg.refundFee, decimals);
		uint256 amountIn = deNormalizeAmount(order.amountIn, decimals);

		uint256 netAmount = amountIn - cancelFee - refundFee;
		if (tokenIn == address(0)) {
			payViaCall(canceler, cancelFee);
			payViaCall(msg.sender, refundFee);
			payViaCall(recipient, netAmount);
		} else {
			IERC20(tokenIn).safeTransfer(canceler, cancelFee);
			IERC20(tokenIn).safeTransfer(msg.sender, refundFee);
			IERC20(tokenIn).safeTransfer(recipient, netAmount);
		}

		emit OrderRefunded(refundMsg.orderHash, netAmount);
	}

	function unlockSingle(bytes memory encodedVm) nonReentrant public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);

		UnlockMsg memory unlockMsg = parseUnlockPayload(vm.payload);
		Order memory order = orders[unlockMsg.orderHash];

		if (vm.emitterChainId != order.destChainId) {
			revert InvalidEmitterChain();
		}
		if (vm.emitterAddress != solanaEmitter && truncateAddress(vm.emitterAddress) != address(this)) {
			revert InvalidEmitterAddress();
		}

		unlockOrder(unlockMsg, order);
	}

	function unlockBatch(bytes memory encodedVm) nonReentrant public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);

		uint8 action = vm.payload.toUint8(0);
		uint index = 1;
		if (action != uint8(Action.BATCH_UNLOCK)) {
			revert InvalidAction();
		}

		uint16 count = vm.payload.toUint16(index);
		index += 2;
		for (uint i=0; i<count; i++) {
			UnlockMsg memory unlockMsg = UnlockMsg({
				action: uint8(Action.UNLOCK),
				orderHash: vm.payload.toBytes32(index),
				srcChainId: vm.payload.toUint16(index + 32),
				tokenIn: vm.payload.toBytes32(index + 34),
				recipient: vm.payload.toBytes32(index + 66)
			});
			index += 98;
			Order memory order = orders[unlockMsg.orderHash];
			if (order.status != Status.CREATED) {
				continue;
			}
			if (vm.emitterChainId != order.destChainId) {
				revert InvalidEmitterChain();
			}
			if (vm.emitterAddress != solanaEmitter && truncateAddress(vm.emitterAddress) != address(this)) {
				revert InvalidEmitterAddress();
			}

			unlockOrder(unlockMsg, order);
		}
	}

	function postBatch(bytes32[] memory orderHashes) public payable returns (uint64 sequence) {
		bytes memory encoded = abi.encodePacked(uint8(Action.BATCH_UNLOCK), uint16(orderHashes.length));
		for(uint i=0; i<orderHashes.length; i++) {
			UnlockMsg memory unlockMsg = unlockMsgs[orderHashes[i]];
			if (unlockMsg.action != uint8(Action.UNLOCK)) {
				revert InvalidAction();
			}
			bytes memory encodedUnlock = abi.encodePacked(
				unlockMsg.orderHash,
				unlockMsg.srcChainId,
				unlockMsg.tokenIn,
				unlockMsg.recipient
			);
			encoded = abi.encodePacked(encoded, encodedUnlock);
		}
		
		sequence = wormhole.publishMessage{
			value : msg.value
		}(0, encoded, consistencyLevel);
	}

	function makePayments(
		uint256 fulfillAmount,
		PaymentParams memory params
	) internal returns (uint256 netAmount) {
		uint8 decimals;
		if (params.tokenOut == address(0)) {
			decimals = NATIVE_DECIMALS;
		} else {
			decimals = decimalsOf(params.tokenOut);
		}
		
		uint256 referrerAmount = 0;
		if (params.referrerAddr != address(0) && params.referrerBps != 0) {
			referrerAmount = fulfillAmount * params.referrerBps / 10000;
		}

		uint256 protocolAmount = 0;
		if (params.protocolBps != 0) {
			protocolAmount = fulfillAmount * params.protocolBps / 10000;
		}

		netAmount = fulfillAmount - referrerAmount - protocolAmount;
		uint256 promisedAmount = deNormalizeAmount(params.promisedAmount, decimals);
		if (netAmount < promisedAmount) {
			revert InvalidAmount();
		}

		if (params.tokenOut == address(0)) {
			if (
				(params.batch && msg.value != fulfillAmount) ||
				(!params.batch && msg.value != fulfillAmount + wormhole.messageFee())
			) {
				revert InvalidWormholeFee();
			}
			if (referrerAmount > 0) {
				payViaCall(params.referrerAddr, referrerAmount);
			}
			if (protocolAmount > 0) {
				payViaCall(feeManager.feeCollector(), protocolAmount);
			}
			payViaCall(params.destAddr, netAmount);
		} else {
			if (params.gasDrop > 0) {
				uint256 gasDrop = deNormalizeAmount(params.gasDrop, NATIVE_DECIMALS);
				if (
					(params.batch && msg.value != gasDrop) ||
					(!params.batch && msg.value != gasDrop + wormhole.messageFee())
				) {
					revert InvalidGasDrop();
				}
				payViaCall(params.destAddr, gasDrop);
			} else if (
				(params.batch && msg.value != 0) ||
				(!params.batch && msg.value != wormhole.messageFee())
			) {
				revert InvalidWormholeFee();
			}
			
			if (referrerAmount > 0) {
				IERC20(params.tokenOut).safeTransfer(params.referrerAddr, referrerAmount);
			}
			if (protocolAmount > 0) {
				IERC20(params.tokenOut).safeTransfer(feeManager.feeCollector(), protocolAmount);
			}
			IERC20(params.tokenOut).safeTransfer(params.destAddr, netAmount);
		}
	}

	function buildKey(OrderParams memory params, bytes32 tokenIn, uint16 srcChainId, uint8 protocolBps) internal pure returns (Key memory) {
		return Key({
			trader: params.trader,
			srcChainId: srcChainId,
			tokenIn: tokenIn,
			tokenOut: params.tokenOut,
			minAmountOut: params.minAmountOut,
			gasDrop: params.gasDrop,
			cancelFee: params.cancelFee,
			refundFee: params.refundFee,
			deadline: params.deadline,
			destAddr: params.destAddr,
			destChainId: params.destChainId,
			referrerAddr: params.referrerAddr,
			referrerBps: params.referrerBps,
			protocolBps: protocolBps,
			auctionMode: params.auctionMode,
			random: params.random
		});
	}

	function parseFulfillPayload(bytes memory encoded) public pure returns (FulfillMsg memory fulfillMsg) {
		uint index = 0;

		fulfillMsg.action = encoded.toUint8(index);
		index += 1;

		if (fulfillMsg.action != uint8(Action.FULFILL)) {
			revert InvalidAction();
		}

		fulfillMsg.orderHash = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.srcChainId = encoded.toUint16(index);
		index += 2;

		fulfillMsg.tokenIn = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.destAddr = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.destChainId = encoded.toUint16(index);
		index += 2;

		fulfillMsg.tokenOut = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.promisedAmount = encoded.toUint64(index);
		index += 8;

		fulfillMsg.gasDrop = encoded.toUint64(index);
		index += 8;

		fulfillMsg.deadline = encoded.toUint64(index);
		index += 8;

		fulfillMsg.referrerAddr = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.referrerBps = encoded.toUint8(index);
		index += 1;

		fulfillMsg.protocolBps = encoded.toUint8(index);
		index += 1;

		fulfillMsg.driver = encoded.toBytes32(index);
		index += 32;
	}

	function parseUnlockPayload(bytes memory encoded) public pure returns (UnlockMsg memory unlockMsg) {
		uint index = 0;

		unlockMsg.action = encoded.toUint8(index);
		index += 1;

		if (unlockMsg.action != uint8(Action.UNLOCK)) {
			revert InvalidAction();
		}

		unlockMsg.orderHash = encoded.toBytes32(index);
		index += 32;

		unlockMsg.srcChainId = encoded.toUint16(index);
		index += 2;

		unlockMsg.tokenIn = encoded.toBytes32(index);
		index += 32;

		unlockMsg.recipient = encoded.toBytes32(index);
		index += 32;
	}

	function parseRefundPayload(bytes memory encoded) public pure returns (RefundMsg memory refundMsg) {
		uint index = 0;

		refundMsg.action = encoded.toUint8(index);
		index += 1;

		if (refundMsg.action != uint8(Action.REFUND)) {
			revert InvalidAction();
		}

		refundMsg.orderHash = encoded.toBytes32(index);
		index += 32;

		refundMsg.srcChainId = encoded.toUint16(index);
		index += 2;

		refundMsg.tokenIn = encoded.toBytes32(index);
		index += 32;

		refundMsg.recipient = encoded.toBytes32(index);
		index += 32;

		refundMsg.canceler = encoded.toBytes32(index);
		index += 32;

		refundMsg.cancelFee = encoded.toUint64(index);
		index += 8;

		refundMsg.refundFee = encoded.toUint64(index);
		index += 8;
	}

	function encodeKey(Key memory key) internal pure returns (bytes memory encoded) {
		encoded = abi.encodePacked(
			key.trader,
			key.srcChainId,
			key.tokenIn,
			key.destAddr,
			key.destChainId,
			key.tokenOut,
			key.minAmountOut,
			key.gasDrop,
			key.cancelFee,
			key.refundFee,
			key.deadline,
			key.referrerAddr,
			key.referrerBps
		);
		encoded = encoded.concat(abi.encodePacked(key.protocolBps, key.auctionMode, key.random));
	}

	function encodeUnlockMsg(UnlockMsg memory unlockMsg) internal pure returns (bytes memory encoded) {
		encoded = abi.encodePacked(
			unlockMsg.action,
			unlockMsg.orderHash,
			unlockMsg.srcChainId,
			unlockMsg.tokenIn,
			unlockMsg.recipient
		);
	}

	function encodeRefundMsg(RefundMsg memory refundMsg) internal pure returns (bytes memory encoded) {
		encoded = abi.encodePacked(
			refundMsg.action,
			refundMsg.orderHash,
			refundMsg.srcChainId,
			refundMsg.tokenIn,
			refundMsg.recipient,
			refundMsg.canceler,
			refundMsg.cancelFee,
			refundMsg.refundFee
		);
	}

	function payViaCall(address to, uint256 amount) internal {
		(bool success, ) = payable(to).call{value: amount}('');
		require(success, 'payment failed');
	}

	function truncateAddress(bytes32 b) internal pure returns (address) {
		if (bytes12(b) != 0) {
			revert InvalidEvmAddr();
		}
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

	function hashTypedData(bytes32 orderHash, uint256 amountIn, uint256 submissionFee) internal view returns (bytes32) {
		bytes memory encoded = abi.encode(keccak256("CreateOrder(bytes32 OrderId,uint256 InputAmount,uint256 SubmissionFee)"), orderHash, amountIn, submissionFee);
		return toTypedDataHash(domainSeparator, keccak256(encoded));
	}

	function toTypedDataHash(bytes32 _domainSeparator, bytes32 _structHash) internal pure returns (bytes32 digest) {
		assembly {
			let ptr := mload(0x40)
			mstore(ptr, "\x19\x01")
			mstore(add(ptr, 0x02), _domainSeparator)
			mstore(add(ptr, 0x22), _structHash)
			digest := keccak256(ptr, 0x42)
		}
	}

	function pullTokensFrom(address tokenIn, uint256 amount, address from) internal returns (uint256) {
		uint256 balance = IERC20(tokenIn).balanceOf(address(this));
		IERC20(tokenIn).safeTransferFrom(from, address(this), amount);
		return IERC20(tokenIn).balanceOf(address(this)) - balance;
	}

	function execPermit(
		address token,
		address owner,
		PermitParams calldata permitParams
	) internal {
		IERC20Permit(token).permit(
			owner,
			address(this),
			permitParams.value,
			permitParams.deadline,
			permitParams.v,
			permitParams.r,
			permitParams.s
		);
	}

	function setPause(bool _pause) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		paused = _pause;
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

	function getOrders(bytes32[] memory orderHashes) public view returns (Order[] memory) {
		Order[] memory result = new Order[](orderHashes.length);
		for (uint i=0; i<orderHashes.length; i++) {
			result[i] = orders[orderHashes[i]];
		}
		return result;
	}

	receive() external payable {}
}