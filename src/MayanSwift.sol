// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IWormhole.sol";
import "./interfaces/IFeeManager.sol";
import "./libs/BytesLib.sol";
import "./libs/SignatureVerification.sol";

contract MayanSwift is ReentrancyGuard {
	event OrderCreated(bytes32 key);
	event OrderFulfilled(bytes32 key, uint64 sequence, uint256 netAmount);
	event OrderUnlocked(bytes32 key);
	event OrderCanceled(bytes32 key, uint64 sequence);
	event OrderRefunded(bytes32 key, uint256 netAmount);

	using SafeERC20 for IERC20;
	using BytesLib for bytes;
	using SignatureVerification for bytes;

	uint16 constant SOLANA_CHAIN_ID = 1;
	uint8 constant BPS_FEE_LIMIT = 50;

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

	mapping(bytes32 => Order) private orders;
	mapping(bytes32 => UnlockMsg) public unlockMsgs;


	error Paused();
	error Unauthorized();
	error InvalidAction();
	error InvalidEmitter();
	error InvalidReferrerBps();
	error InvalidProtocolBps();
	error InvalidOrderStatus();
	error InvalidOrderHash();
	error InvalidAuctionChain();
	error InvalidAuctionAddress();
	error InvalidEmitterChain();
	error InvalidEmitterAddress();
	error InvalidSrcChain();
	error OrderNotExists();
	error SmallAmountIn();
	error FeesTooHigh();
	error InvalidGasDrop();
	error InvalidDestChain();
	error DuplicateOrder();

	struct Order {
		uint16 destChainId;
		Status status;
	}

	struct OrderParams {
		address trader;
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
		uint64 amountIn;
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
		uint8 protocolBps;
		uint8 auctionMode;
		bytes32 random;
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
		uint64 amountIn;
		bytes32 recipient;
	}

	struct RefundMsg {
		uint8 action;
		bytes32 orderHash;
		uint16 srcChainId;
		bytes32 tokenIn;
		uint64 amountIn;
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
		uint64 amountPromised;
		uint64 gasDrop;
		bytes32 referrerAddr;
		uint8 referrerBps;
		uint8 protocolBps;
		uint16 srcChainId;
		bytes32 tokenIn;
		uint64 amountIn;
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
			keccak256("Mayan Swift v1.0"),
			uint256(IWormhole(_wormhole).chainId()),
			address(this)
		));
	}

	function createOrderWithEth(OrderParams memory params) nonReentrant public payable returns (bytes32 orderHash) {
		if (paused) {
			revert Paused();
		}

		uint64 normlizedAmountIn = uint64(normalizeAmount(msg.value, 18));
		if (normlizedAmountIn == 0) {
			revert SmallAmountIn();
		}
		if (params.cancelFee + params.refundFee > normlizedAmountIn) {
			revert FeesTooHigh();
		}

		if (params.tokenOut == bytes32(0) && params.gasDrop != 0) {
			revert InvalidGasDrop();
		}

		if (params.referrerBps > BPS_FEE_LIMIT) {
			revert InvalidReferrerBps();
		}
		uint8 protocolBps = feeManager.calcProtocolBps(normlizedAmountIn, address(0), params.tokenOut, params.destChainId, params.referrerBps);
		if (protocolBps > BPS_FEE_LIMIT) {
			revert InvalidProtocolBps();
		}

		Key memory key = Key({
			trader: bytes32(uint256(uint160(params.trader))),
			srcChainId: wormhole.chainId(),
			tokenIn: bytes32(0),
			amountIn: normlizedAmountIn,
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

		orderHash = keccak256(encodeKey(key));

		if (params.destChainId == 0) {
			revert InvalidDestChain();
		}
		if (orders[orderHash].destChainId != 0) {
			revert DuplicateOrder();
		}

		orders[orderHash] = Order({
			status: Status.CREATED,
			destChainId: params.destChainId
		});
		
		emit OrderCreated(orderHash);
	}

	function createOrderWithToken(
		address tokenIn,
		uint256 amountIn,
		OrderParams memory params
	) nonReentrant public returns (bytes32 orderHash) {
		if (paused) {
			revert Paused();
		}

		uint256 balance = IERC20(tokenIn).balanceOf(address(this));
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		amountIn = IERC20(tokenIn).balanceOf(address(this)) - balance;

		uint64 normlizedAmountIn = uint64(normalizeAmount(amountIn, decimalsOf(tokenIn)));
		if (normlizedAmountIn == 0) {
			revert SmallAmountIn();
		}
		if (params.cancelFee + params.refundFee > normlizedAmountIn) {
			revert FeesTooHigh();
		}
		if (params.tokenOut == bytes32(0) && params.gasDrop != 0) {
			revert InvalidGasDrop();
		}

		if (params.referrerBps > BPS_FEE_LIMIT) {
			revert InvalidReferrerBps();
		}
		uint8 protocolBps = feeManager.calcProtocolBps(normlizedAmountIn, tokenIn, params.tokenOut, params.destChainId, params.referrerBps);
		if (protocolBps > BPS_FEE_LIMIT) {
			revert InvalidProtocolBps();
		}

		Key memory key = Key({
			trader: bytes32(uint256(uint160(params.trader))),
			srcChainId: wormhole.chainId(),
			tokenIn: bytes32(uint256(uint160(tokenIn))),
			amountIn: normlizedAmountIn,
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

		orderHash = keccak256(encodeKey(key));

		if (params.destChainId == 0) {
			revert InvalidDestChain();
		}
		if (orders[orderHash].destChainId != 0) {
			revert DuplicateOrder();
		}

		orders[orderHash] = Order({
			status: Status.CREATED,
			destChainId: params.destChainId
		});

		emit OrderCreated(orderHash);
	}

	function createOrderWithSig(
		address tokenIn,
		uint256 amountIn,
		OrderParams memory params,
		bytes calldata signedOrderHash
	) nonReentrant public returns (bytes32 orderHash) {
		if (paused) {
			revert Paused();
		}

		uint256 amount = IERC20(tokenIn).balanceOf(address(this));
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		amount = IERC20(tokenIn).balanceOf(address(this)) - amount;
		require(amountIn == amount, 'invalid amount');

		uint64 normlizedAmountIn = uint64(normalizeAmount(amountIn, decimalsOf(tokenIn)));
		if (normlizedAmountIn == 0) {
			revert SmallAmountIn();
		}
		if (params.cancelFee + params.refundFee > normlizedAmountIn) {
			revert FeesTooHigh();
		}
		if (params.tokenOut == bytes32(0) && params.gasDrop != 0) {
			revert InvalidGasDrop();
		}

		if (params.referrerBps > BPS_FEE_LIMIT) {
			revert InvalidReferrerBps();
		}
		uint8 protocolBps = feeManager.calcProtocolBps(normlizedAmountIn, tokenIn, params.tokenOut, params.destChainId, params.referrerBps);
		if (protocolBps > BPS_FEE_LIMIT) {
			revert InvalidProtocolBps();
		}

		Key memory key = Key({
			trader: bytes32(uint256(uint160(params.trader))),
			srcChainId: wormhole.chainId(),
			tokenIn: bytes32(uint256(uint160(tokenIn))),
			amountIn: normlizedAmountIn,
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

		orderHash = keccak256(encodeKey(key));

		signedOrderHash.verify(hashTypedData(orderHash), params.trader);

		if (params.destChainId == 0) {
			revert InvalidDestChain();
		}
		if (orders[orderHash].destChainId != 0) {
			revert DuplicateOrder();
		}

		orders[orderHash] = Order({
			status: Status.CREATED,
			destChainId: params.destChainId
		});

		emit OrderCreated(orderHash);
	}

	function fulfillOrder(
		bytes memory encodedVm,
		bytes32 recepient,
		bool batch
	) nonReentrant public payable returns (uint64 sequence) {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);
		if (vm.emitterChainId != auctionChainId) {
			revert InvalidAuctionChain();
		}
		if (vm.emitterAddress != auctionAddr) {
			revert InvalidAuctionAddress();
		}

		FulfillMsg memory fulfillMsg = parseFulfillPayload(vm.payload);

		require(fulfillMsg.destChainId == wormhole.chainId(), 'wrong chain');
		require(truncateAddress(fulfillMsg.driver) == msg.sender, 'invalid driver');

		if (orders[fulfillMsg.orderHash].status != Status.CREATED) {
			revert InvalidOrderStatus();
		}
		orders[fulfillMsg.orderHash].status = Status.FULFILLED;

		address tokenOut = truncateAddress(fulfillMsg.tokenOut);
		if (tokenOut != address(0)) {
			IERC20(tokenOut).safeTransferFrom(msg.sender, address(this), fulfillMsg.amountPromised);
		}

		uint256 netAmount = makePayments(
			fulfillMsg.destAddr,
			fulfillMsg.tokenOut,
			fulfillMsg.amountPromised,
			fulfillMsg.gasDrop,
			fulfillMsg.referrerAddr,
			fulfillMsg.referrerBps,
			fulfillMsg.protocolBps
		);

		UnlockMsg memory unlockMsg = UnlockMsg({
			action: uint8(Action.UNLOCK),
			orderHash: fulfillMsg.orderHash,
			srcChainId: fulfillMsg.srcChainId,
			tokenIn: fulfillMsg.tokenIn,
			amountIn: fulfillMsg.amountIn,
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
		bytes32 orderHash,
		bytes32 trader,
		uint16 srcChainId,
		bytes32 tokenIn,
		uint64 amountIn,
		uint8 protocolBps,
		OrderParams memory params,
		bytes32 recepient,
		bool batch
	) public nonReentrant payable returns (uint64 sequence) {
		require(params.auctionMode == uint8(AuctionMode.BYPASS), 'invalid auction mode');

		address tokenOut = truncateAddress(params.tokenOut);
		if (tokenOut != address(0)) {
			IERC20(tokenOut).safeTransferFrom(msg.sender, address(this), params.minAmountOut);
		}

		Key memory key = Key({
			trader: trader,
			srcChainId: srcChainId,
			tokenIn: tokenIn,
			amountIn: amountIn,
			tokenOut: params.tokenOut,
			minAmountOut: params.minAmountOut,
			gasDrop: params.gasDrop,
			cancelFee: params.cancelFee,
			refundFee: params.refundFee,
			deadline: params.deadline,
			destAddr: params.destAddr,
			destChainId: wormhole.chainId(),
			referrerAddr: params.referrerAddr,
			referrerBps: params.referrerBps,
			protocolBps: protocolBps,
			auctionMode: params.auctionMode,
			random: params.random
		});

		bytes32 computedOrderHash = keccak256(encodeKey(key));

		if (computedOrderHash != orderHash) {
			revert InvalidOrderHash();
		}

		if (orders[computedOrderHash].status != Status.CREATED) {
			revert InvalidOrderStatus();
		}
		orders[computedOrderHash].status = Status.FULFILLED;

		uint256 netAmount = makePayments(
			params.destAddr,
			params.tokenOut,
			params.minAmountOut,
			params.gasDrop,
			params.referrerAddr,
			params.referrerBps,
			protocolBps
		);

		UnlockMsg memory unlockMsg = UnlockMsg({
			action: uint8(Action.UNLOCK),
			orderHash: computedOrderHash,
			srcChainId: key.srcChainId,
			tokenIn: key.tokenIn,
			amountIn: key.amountIn,
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
		order.status = Status.UNLOCKED;
		
		address recipient = truncateAddress(unlockMsg.recipient);
		address tokenIn = truncateAddress(unlockMsg.tokenIn);
		uint8 decimals;
		if (tokenIn == address(0)) {
			decimals = 18;
		} else {
			decimals = decimalsOf(tokenIn);
		}

		uint256 amountIn = deNormalizeAmount(unlockMsg.amountIn, decimals);
		if (tokenIn == address(0)) {
			payable(recipient).transfer(amountIn);
		} else {
			IERC20(tokenIn).safeTransfer(recipient, amountIn);
		}
		
		emit OrderUnlocked(unlockMsg.orderHash);
	}

	function cancelOrder(
		bytes32 tokenIn,
		uint64 amountIn,
		OrderParams memory params,
		bytes32 trader,
		uint16 srcChainId,
		uint8 protocolBps,
		bytes32 canceler
	) public nonReentrant payable returns (uint64 sequence) {
		Key memory key = Key({
			trader: trader,
			srcChainId: srcChainId,
			tokenIn: tokenIn,
			amountIn: amountIn,
			tokenOut: params.tokenOut,
			minAmountOut: params.minAmountOut,
			gasDrop: params.gasDrop,
			cancelFee: params.cancelFee,
			refundFee: params.refundFee,
			deadline: params.deadline,
			destAddr: trader,
			destChainId: wormhole.chainId(),
			referrerAddr: params.referrerAddr,
			referrerBps: params.referrerBps,
			protocolBps: protocolBps,
			auctionMode: params.auctionMode,
			random: params.random
		});

		bytes32 orderHash = keccak256(encodeKey(key));
		Order memory order = orders[orderHash];

		require(key.deadline < block.timestamp, 'not expired');

		if (order.status != Status.CREATED) {
			revert InvalidOrderStatus();
		}
		orders[orderHash].status = Status.CANCELED;

		RefundMsg memory refundMsg = RefundMsg({
			action: uint8(Action.REFUND),
			orderHash: orderHash,
			srcChainId: key.srcChainId,
			tokenIn: key.tokenIn,
			amountIn: key.amountIn,
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
		Order memory order = getOrder(refundMsg.orderHash);

		if (refundMsg.srcChainId != wormhole.chainId()) {
			revert InvalidSrcChain();
		}
		if (order.destChainId == 0) {
			revert OrderNotExists();
		}
		if (order.status != Status.CREATED) {
			revert InvalidOrderStatus();
		}
		order.status = Status.REFUNDED;

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
			decimals = 18;
		} else {
			decimals = decimalsOf(tokenIn);
		}

		uint256 cancelFee = deNormalizeAmount(refundMsg.cancelFee, decimals);
		uint256 refundFee = deNormalizeAmount(refundMsg.refundFee, decimals);
		uint256 amountIn = deNormalizeAmount(refundMsg.amountIn, decimals);

		uint256 netAmount = amountIn - cancelFee - refundFee;
		if (tokenIn == address(0)) {
			payable(canceler).transfer(cancelFee);
			payable(msg.sender).transfer(refundFee);
			payable(recipient).transfer(netAmount);
		} else {
			IERC20(tokenIn).transfer(canceler, cancelFee);
			IERC20(tokenIn).transfer(msg.sender, refundFee);
			IERC20(tokenIn).transfer(recipient, netAmount);
		}

		emit OrderRefunded(refundMsg.orderHash, netAmount);
	}

	function unlockSingle(bytes memory encodedVm) nonReentrant public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);

		UnlockMsg memory unlockMsg = parseUnlockPayload(vm.payload);
		Order memory order = getOrder(unlockMsg.orderHash);

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

		uint index = 0;
		uint8 action = vm.payload.toUint8(0);
		index += 1;
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
				amountIn: vm.payload.toUint64(index + 66),
				recipient: vm.payload.toBytes32(index + 74)
			});
			index += 106;
			Order memory order = getOrder(unlockMsg.orderHash);
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
		require(index == vm.payload.length, 'invalid payload length');
	}

	function postBatch(bytes32[] memory orderHashes) public payable returns (uint64 sequence) {
		bytes memory encoded = abi.encodePacked(uint8(Action.BATCH_UNLOCK), uint8(orderHashes.length));
		for(uint i=0; i<orderHashes.length; i++) {
			UnlockMsg memory unlockMsg = unlockMsgs[orderHashes[i]];
			if (unlockMsg.action != uint8(Action.UNLOCK)) {
				revert InvalidAction();
			}
			encoded = abi.encodePacked(encoded, encodeUnlockMsg(unlockMsg));
		}
		
		sequence = wormhole.publishMessage{
			value : msg.value
		}(0, encoded, consistencyLevel);
	}

	function makePayments(
		bytes32 _destAddr,
		bytes32 _tokenOut,
		uint64 _amountPromised,
		uint64 _gasDrop,
		bytes32 _referrerAddr,
		uint8 _referrerBps,
		uint8 _protocolBps
	) internal returns (uint256 netAmount) {
		address tokenOut = truncateAddress(_tokenOut);
		uint8 decimals;
		if (tokenOut == address(0)) {
			decimals = 18;
		} else {
			decimals = decimalsOf(tokenOut);
		}

		uint256 amountPromised = deNormalizeAmount(_amountPromised, decimals);
		address referrerAddr = truncateAddress(_referrerAddr);
		
		uint256 amountReferrer = 0;
		if (referrerAddr != address(0) && _referrerBps != 0) {
			amountReferrer = amountPromised * _referrerBps / 10000;
		}

		uint256 amountProtocol = 0;
		if (_protocolBps != 0) {
			amountProtocol = amountPromised * _protocolBps / 10000;
		}

		address destAddr = truncateAddress(_destAddr);
		uint256 wormholeFee = wormhole.messageFee();
		netAmount = amountPromised - amountReferrer - amountProtocol;
		if (tokenOut == address(0)) {
			require(msg.value == amountPromised + wormholeFee, 'invalid amount value');
			if (amountReferrer > 0) {
				payable(referrerAddr).transfer(amountReferrer);
			}
			if (amountProtocol > 0) {
				payable(feeManager.feeCollector()).transfer(amountProtocol);
			}
			payable(destAddr).transfer(netAmount);
		} else {
			if (_gasDrop > 0) {
				uint256 gasDrop = deNormalizeAmount(_gasDrop, 18);
				if (msg.value != gasDrop + wormholeFee) {
					revert InvalidGasDrop();
				}
				payable(destAddr).transfer(gasDrop);
			} else {
				require(msg.value == wormholeFee, 'invalid bridge fee');
			}
			
			if (amountReferrer > 0) {
				IERC20(tokenOut).safeTransferFrom(msg.sender, referrerAddr, amountReferrer);
			}
			if (amountProtocol > 0) {
				IERC20(tokenOut).safeTransferFrom(msg.sender, feeManager.feeCollector(), amountProtocol);
			}
			IERC20(tokenOut).safeTransferFrom(msg.sender, destAddr, netAmount);
		}
	}

	function execPermit(
		address token,
		address owner,
		address spender,
		PermitParams calldata permitParams
	) internal {
		IERC20Permit(token).permit(
			owner,
			spender,
			permitParams.value,
			permitParams.deadline,
			permitParams.v,
			permitParams.r,
			permitParams.s
		);
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

		fulfillMsg.amountIn = encoded.toUint64(index);
		index += 8;

		fulfillMsg.destAddr = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.destChainId = encoded.toUint16(index);
		index += 2;

		fulfillMsg.tokenOut = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.amountPromised = encoded.toUint64(index);
		index += 8;

		fulfillMsg.gasDrop = encoded.toUint64(index);
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

		unlockMsg.amountIn = encoded.toUint64(index);
		index += 8;

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

		refundMsg.amountIn = encoded.toUint64(index);
		index += 8;

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
			key.amountIn,
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
			unlockMsg.amountIn,
			unlockMsg.recipient
		);
	}

	function encodeRefundMsg(RefundMsg memory refundMsg) internal pure returns (bytes memory encoded) {
		encoded = abi.encodePacked(
			refundMsg.action,
			refundMsg.orderHash,
			refundMsg.srcChainId,
			refundMsg.tokenIn,
			refundMsg.amountIn,
			refundMsg.recipient,
			refundMsg.canceler,
			refundMsg.cancelFee,
			refundMsg.refundFee
		);
	}

	function truncateAddress(bytes32 b) internal pure returns (address) {
		require(bytes12(b) == 0, 'invalid EVM addr');
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

	function hashTypedData(bytes32 orderHash) internal view returns (bytes32) {
		bytes32 dataHash = keccak256(abi.encode(keccak256("CreateOrder(bytes32 orderHash)"), orderHash));
		return toTypedDataHash(domainSeparator, dataHash);
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

	function getOrder(bytes32 orderHash) public view returns (Order memory) {
		return orders[orderHash];
	}

	function getOrders(bytes32[] memory orderHashes) public view returns (Order[] memory) {
		Order[] memory _orders = new Order[](orderHashes.length);
		for (uint i=0; i<orderHashes.length; i++) {
			_orders[i] = getOrder(orderHashes[i]);
		}
		return _orders;
	}

	receive() external payable {}
}