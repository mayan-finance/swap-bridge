// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IWormhole.sol";
import "./interfaces/IFeeManager.sol";
import "./libs/BytesLib.sol";
import "./libs/SignatureVerifier.sol";

contract SwiftDest is ReentrancyGuard {
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
	mapping(bytes32 => uint256) public netAmounts;


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
	error InsufficientAmount();
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
		uint8 payloadType;
		bytes32 trader;
		bytes32 destAddr;
		uint16 destChainId;
		bytes32 referrerAddr;		
		bytes32 tokenOut;
		uint64 minAmountOut;
		uint64 gasDrop;
		uint64 cancelFee;
		uint64 refundFee;
		uint64 deadline;
		uint16 penaltyPeriod;
		uint8 referrerBps;
		uint8 auctionMode;
		uint64 baseBond;
		uint64 perBpsBond;
		bytes32 random;
	}

	struct ExtraParams {
		uint16 srcChainId;
		bytes32 tokenIn;
		uint8 protocolBps;
		bytes32 customPayloadHash;
	}	

	struct PermitParams {
		uint256 value;
		uint256 deadline;
		uint8 v;
		bytes32 r;
		bytes32 s;
	}

	struct Key {
		uint8 payloadType;
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
		uint64 penaltyPeriod;
		bytes32 referrerAddr;
		uint8 referrerBps;
		uint8 protocolBps;
		uint8 auctionMode;
		uint64 baseBond;
		uint64 perBpsBond;
		bytes32 random;
		bytes32 customPayloadHash;
	}

	struct PaymentParams {
		uint8 payloadType;
		bytes32 orderHash;
		uint64 promisedAmount;
		uint64 minAmountOut;
		address destAddr;
		address tokenOut;
		uint64 gasDrop;
		address referrerAddr;
		uint8 referrerBps;
		uint8 protocolBps;
		bool batch;
	}

	enum Status {
		CREATED,
		FULFILLED,
		SETTLED,
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
		uint64 fulfillTime;
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
		bytes32 driver;
		uint64 promisedAmount;
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

	function fulfillOrder(
		uint256 fulfillAmount,
		bytes memory encodedVm,
		OrderParams memory params,
		ExtraParams memory extraParams,		
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

		params.destChainId = wormhole.chainId();
		bytes32 orderHash = keccak256(encodeKey(buildKey(
			params,
			extraParams.tokenIn,
			extraParams.srcChainId,
			extraParams.protocolBps,
			extraParams.customPayloadHash
		)));

		FulfillMsg memory fulfillMsg = parseFulfillPayload(vm.payload);
		if (orderHash != fulfillMsg.orderHash) {
			revert InvalidOrderHash();
		}

		address tokenOut = truncateAddress(params.tokenOut);
		if (tokenOut != address(0)) {
			fulfillAmount = pullTokensFrom(tokenOut, fulfillAmount, msg.sender);
		}

		if (truncateAddress(fulfillMsg.driver) != tx.origin && block.timestamp <= params.deadline - params.penaltyPeriod) {
			revert Unauthorized();
		}

		if (block.timestamp > params.deadline) {
			revert DeadlineViolation();
		}

		if (orders[fulfillMsg.orderHash].status != Status.CREATED) {
			revert InvalidOrderStatus();
		}
		if (params.payloadType == 2) {
			orders[orderHash].status = Status.FULFILLED;
		} else {
			orders[orderHash].status = Status.SETTLED;
		}

		PaymentParams memory paymentParams = PaymentParams({
			payloadType: params.payloadType,
			orderHash: orderHash,
			promisedAmount: fulfillMsg.promisedAmount,
			minAmountOut: params.minAmountOut,
			destAddr: truncateAddress(params.destAddr),
			tokenOut: truncateAddress(params.tokenOut),
			gasDrop: params.gasDrop,
			referrerAddr: truncateAddress(params.referrerAddr),
			referrerBps: params.referrerBps,
			protocolBps: extraParams.protocolBps,
			batch: batch
		});
		uint256 netAmount = makePayments(fulfillAmount, paymentParams);

		UnlockMsg memory unlockMsg = UnlockMsg({
			action: uint8(Action.UNLOCK),
			orderHash: fulfillMsg.orderHash,
			srcChainId: extraParams.srcChainId,
			tokenIn: extraParams.tokenIn,
			recipient: recepient,
			fulfillTime: uint64(block.timestamp)
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
		bytes32 customPayloadHash,
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
		Key memory key = buildKey(params, tokenIn, srcChainId, protocolBps, customPayloadHash);

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
		if (params.payloadType == 2) {
			orders[computedOrderHash].status = Status.FULFILLED;
		} else {
			orders[computedOrderHash].status = Status.SETTLED;
		}
		
		PaymentParams memory paymentParams = PaymentParams({
			payloadType: params.payloadType,
			orderHash: computedOrderHash,
			promisedAmount: key.minAmountOut,
			minAmountOut: key.minAmountOut,
			destAddr: truncateAddress(key.destAddr),
			tokenOut: tokenOut,
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
			recipient: recepient,
			fulfillTime: uint64(block.timestamp)
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

	function cancelOrder(
		bytes32 tokenIn,
		OrderParams memory params,
		bytes32 customPayloadHash,
		uint16 srcChainId,
		uint8 protocolBps,
		bytes32 canceler
	) public nonReentrant payable returns (uint64 sequence) {

		params.destChainId = wormhole.chainId();
		Key memory key = buildKey(params, tokenIn, srcChainId, protocolBps, customPayloadHash);

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

	function settleWithPayload(
		OrderParams memory params,
		ExtraParams memory extraParams
	) nonReentrant public returns (uint256 netAmount) {
		if (params.payloadType != 2) {
			revert InvalidAction();
		}
		if (truncateAddress(params.destAddr) != msg.sender) {
			revert Unauthorized();
		}

		params.destChainId = wormhole.chainId();
		bytes32 orderHash = keccak256(encodeKey(buildKey(
			params,
			extraParams.tokenIn,
			extraParams.srcChainId,
			extraParams.protocolBps,
			extraParams.customPayloadHash
		)));

		if (orders[orderHash].status != Status.FULFILLED) {
			revert InvalidOrderStatus();
		}
		orders[orderHash].status = Status.SETTLED;

		netAmount = netAmounts[orderHash];
		address tokenOut = truncateAddress(params.tokenOut);
		if (tokenOut == address(0)) {
			payEth(msg.sender, netAmount);
		} else {
			IERC20(tokenOut).safeTransfer(msg.sender, netAmount);
		}
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

		if (fulfillAmount < deNormalizeAmount(params.promisedAmount, decimals)) {
			revert InsufficientAmount();
		}
		
		uint256 referrerAmount = 0;
		if (params.referrerAddr != address(0) && params.referrerBps != 0) {
			referrerAmount = params.promisedAmount * params.referrerBps / 10000;
		}

		uint256 protocolAmount = 0;
		if (params.protocolBps != 0) {
			protocolAmount = params.promisedAmount * params.protocolBps / 10000;
		}

		netAmount = normalizeAmount(fulfillAmount, decimals) - referrerAmount - protocolAmount;
		if (netAmount < params.minAmountOut) {
			revert InvalidAmount();
		}
		netAmount = deNormalizeAmount(netAmount, decimals);
		referrerAmount = deNormalizeAmount(referrerAmount, decimals);
		protocolAmount = deNormalizeAmount(protocolAmount, decimals);

		if (params.tokenOut == address(0)) {
			if (
				(params.batch && msg.value != fulfillAmount) ||
				(!params.batch && msg.value != fulfillAmount + wormhole.messageFee())
			) {
				revert InvalidWormholeFee();
			}
			if (referrerAmount > 0) {
				payEth(params.referrerAddr, referrerAmount);
			}
			if (protocolAmount > 0) {
				payEth(feeManager.feeCollector(), protocolAmount);
			}
			if (params.payloadType == 2) {
				netAmounts[params.orderHash] = netAmount;
			} else {
				payEth(params.destAddr, netAmount);
			}
		} else {
			if (params.gasDrop > 0) {
				uint256 gasDrop = deNormalizeAmount(params.gasDrop, NATIVE_DECIMALS);
				if (
					(params.batch && msg.value != gasDrop) ||
					(!params.batch && msg.value != gasDrop + wormhole.messageFee())
				) {
					revert InvalidGasDrop();
				}
				payEth(params.destAddr, gasDrop);
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
			if (params.payloadType == 2) {
				netAmounts[params.orderHash] = netAmount;
			} else {
				IERC20(params.tokenOut).safeTransfer(params.destAddr, netAmount);
			}
		}
	}

	function buildKey(
		OrderParams memory params, 
		bytes32 tokenIn,
		uint16 srcChainId,
		uint8 protocolBps,
		bytes32 customPayloadHash
	) internal pure returns (Key memory) {
		return Key({
			payloadType: params.payloadType,
			trader: params.trader,
			srcChainId: srcChainId,
			tokenIn: tokenIn,
			destAddr: params.destAddr,
			destChainId: params.destChainId,		
			tokenOut: params.tokenOut,
			minAmountOut: params.minAmountOut,
			gasDrop: params.gasDrop,
			cancelFee: params.cancelFee,
			refundFee: params.refundFee,
			deadline: params.deadline,
			penaltyPeriod: params.penaltyPeriod,
			referrerAddr: params.referrerAddr,	
			referrerBps: params.referrerBps,
			protocolBps: protocolBps,
			auctionMode: params.auctionMode,
			baseBond: params.baseBond,
			perBpsBond: params.perBpsBond,
			random: params.random,
			customPayloadHash: customPayloadHash
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

		fulfillMsg.driver = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.promisedAmount = encoded.toUint64(index);
		index += 8;
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
			key.payloadType,
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
			key.penaltyPeriod
		);
		encoded = encoded.concat(abi.encodePacked(
			key.referrerAddr,
			key.referrerBps,
			key.protocolBps,
			key.auctionMode,
			key.baseBond,
			key.perBpsBond,
			key.random,
			key.customPayloadHash
		));
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

	function payEth(address to, uint256 amount) internal {
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