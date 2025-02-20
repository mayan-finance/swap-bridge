// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IWormhole.sol";
import "../libs/BytesLib.sol";
import "../libs/SignatureVerifier.sol";
import "./SwiftStructs.sol";
import "./SwiftErrors.sol";

contract SwiftDest is ReentrancyGuard {
	event OrderCreated(bytes32 key);
	event OrderFulfilled(bytes32 key, uint64 sequence, uint256 fulfilledAmount);
	event OrderUnlocked(bytes32 key);
	event OrderCanceled(bytes32 key, uint64 sequence);
	event OrderRefunded(bytes32 key, uint256 refundedAmount);

	using SafeERC20 for IERC20;
	using BytesLib for bytes;
	using SignatureVerifier for bytes;

	uint8 constant NATIVE_DECIMALS = 18;

	IWormhole public immutable wormhole;
	address public auctionVerifier;
	uint16 public auctionChainId;
	bytes32 public auctionAddr;
	uint8 public consistencyLevel;
	address public guardian;
	address public nextGuardian;
	bool public paused;

	mapping(bytes32 => Order) public orders;
	mapping(bytes32 => bytes) public unlockMsgs;
	mapping(bytes32 => uint256) public pendingAmounts;

	constructor(
		address _wormhole,
		address _auctionVerifier,
		uint16 _auctionChainId,
		bytes32 _auctionAddr,
		uint8 _consistencyLevel
	) {
		guardian = msg.sender;
		wormhole = IWormhole(_wormhole);
		auctionVerifier = _auctionVerifier;
		auctionChainId = _auctionChainId;
		auctionAddr = _auctionAddr;
		consistencyLevel = _consistencyLevel;
	}

	function fulfillOrder(
		uint256 fulfillAmount,
		bytes memory encodedVm,
		OrderParams memory params,
		ExtraParams memory extraParams,
		bytes32 recipient,
		bool batch,
		PermitParams calldata permit
	) nonReentrant public payable returns (uint64 sequence) {
		(IWormhole.VM memory vm, bool valid, string memory reason) = IWormhole(auctionVerifier).parseAndVerifyVM(encodedVm);

		require(valid, reason);
		if (vm.emitterChainId != auctionChainId) {
			revert InvalidEmitterChain();
		}
		if (vm.emitterAddress != auctionAddr) {
			revert InvalidEmitterAddress();
		}

		FulfillMsg memory fulfillMsg = parseFulfillPayload(vm.payload);

		params.destChainId = wormhole.chainId();
		if (keccak256(encodeKey(buildKey(params, extraParams))) != fulfillMsg.orderHash) {
			revert InvalidOrderHash();
		}

		address tokenOut = truncateAddress(params.tokenOut);
		if (tokenOut != address(0)) {
			fulfillAmount = pullTokenIn(tokenOut, fulfillAmount, permit);
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
			orders[fulfillMsg.orderHash].status = Status.FULFILLED;
		} else {
			orders[fulfillMsg.orderHash].status = Status.SETTLED;
		}

		makePayments(fulfillAmount, PaymentParams({
			payloadType: params.payloadType,
			orderHash: fulfillMsg.orderHash,
			promisedAmount: fulfillMsg.promisedAmount,
			minAmountOut: params.minAmountOut,
			destAddr: truncateAddress(params.destAddr),
			tokenOut: tokenOut,
			gasDrop: params.gasDrop,
			batch: batch
		}));

		sequence = batchOrSendUnlockMsg(buildUnlockMsg(fulfillMsg.orderHash, params, extraParams, recipient), batch);
		emit OrderFulfilled(fulfillMsg.orderHash, sequence, fulfillAmount);
	}

	function fulfillSimple(
		uint256 fulfillAmount,
		bytes32 orderHash,
		OrderParams memory params,
		ExtraParams memory extraParams,
		bytes32 recipient,
		bool batch,
		PermitParams calldata permit
	) public nonReentrant payable returns (uint64 sequence) {
		if (params.auctionMode != uint8(AuctionMode.BYPASS)) {
			revert InvalidAuctionMode();
		}

		address tokenOut = truncateAddress(params.tokenOut);
		if (tokenOut != address(0)) {
			fulfillAmount = pullTokenIn(tokenOut, fulfillAmount, permit);
		}	

		params.destChainId = wormhole.chainId();
		if (keccak256(encodeKey(buildKey(params, extraParams))) != orderHash) {
			revert InvalidOrderHash();
		}

		if (block.timestamp > params.deadline) {
			revert DeadlineViolation();
		}

		if (orders[orderHash].status != Status.CREATED) {
			revert InvalidOrderStatus();
		}
		if (params.payloadType == 2) {
			orders[orderHash].status = Status.FULFILLED;
		} else {
			orders[orderHash].status = Status.SETTLED;
		}
		
		makePayments(fulfillAmount, PaymentParams({
			payloadType: params.payloadType,
			orderHash: orderHash,
			promisedAmount: params.minAmountOut,
			minAmountOut: params.minAmountOut,
			destAddr: truncateAddress(params.destAddr),
			tokenOut: tokenOut,
			gasDrop: params.gasDrop,
			batch: batch
		}));

		sequence = batchOrSendUnlockMsg(buildUnlockMsg(orderHash, params, extraParams, recipient), batch);
		emit OrderFulfilled(orderHash, sequence, fulfillAmount);
	}

	function cancelOrder(
		bytes32 orderHash,
		OrderParams memory params,
		ExtraParams memory extraParams,
		bytes32 canceler
	) public nonReentrant payable returns (uint64 sequence) {
		params.destChainId = wormhole.chainId();
		bytes32 computedOrderHash = keccak256(encodeKey(buildKey(params, extraParams)));

		if (computedOrderHash != orderHash) {
			revert InvalidOrderHash();
		}

		Order memory order = orders[orderHash];

		if (block.timestamp <= params.deadline) {
			revert DeadlineViolation();
		}

		if (order.status != Status.CREATED) {
			revert InvalidOrderStatus();
		}
		orders[orderHash].status = Status.CANCELED;

		RefundMsg memory refundMsg = RefundMsg({
			action: uint8(Action.REFUND),
			orderHash: orderHash,
			srcChainId: extraParams.srcChainId,
			tokenIn: extraParams.tokenIn,
			trader: params.trader,
			canceler: canceler,
			cancelFee: params.cancelFee,
			refundFee: params.refundFee
		});

		bytes memory encoded = encodeRefundMsg(refundMsg);

		sequence = wormhole.publishMessage{
			value : msg.value
		}(0, encoded, consistencyLevel);

		emit OrderCanceled(orderHash, sequence);
	}

	function postBatch(bytes32[] memory orderHashes, bool compressed) public payable returns (uint64 sequence) {
		bytes memory encoded;
		for(uint i=0; i<orderHashes.length; i++) {
			bytes memory unlockMsg = unlockMsgs[orderHashes[i]];
			if (unlockMsg.length != UNLOCK_MSG_SIZE) {
				revert OrderNotExists(orderHashes[i]);
			}
			encoded = abi.encodePacked(encoded, unlockMsg);
			delete unlockMsgs[orderHashes[i]];
		}

		bytes memory payload;
		if (compressed) {
			payload = abi.encodePacked(uint8(Action.COMPRESSED_UNLOCK), uint16(orderHashes.length), keccak256(encoded));
		} else {
			payload = abi.encodePacked(uint8(Action.BATCH_UNLOCK), uint16(orderHashes.length), encoded);
		}
		
		sequence = wormhole.publishMessage{
			value : msg.value
		}(0, payload, consistencyLevel);
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
		bytes32 orderHash = keccak256(encodeKey(buildKey(params, extraParams)));

		if (orders[orderHash].status != Status.FULFILLED) {
			revert InvalidOrderStatus();
		}
		orders[orderHash].status = Status.SETTLED;

		netAmount = pendingAmounts[orderHash];
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
	) internal {
		uint8 decimals;
		if (params.tokenOut == address(0)) {
			decimals = NATIVE_DECIMALS;
		} else {
			decimals = decimalsOf(params.tokenOut);
		}

		if (fulfillAmount < deNormalizeAmount(params.promisedAmount, decimals)) {
			revert InsufficientAmount();
		}

		if (normalizeAmount(fulfillAmount, decimals) < params.minAmountOut) {
			revert InvalidAmount();
		}

		if (params.tokenOut == address(0)) {
			if (
				(params.batch && msg.value != fulfillAmount) ||
				(!params.batch && msg.value != fulfillAmount + wormhole.messageFee())
			) {
				revert InvalidWormholeFee();
			}
			if (params.payloadType == 2) {
				pendingAmounts[params.orderHash] = fulfillAmount;
			} else {
				payEth(params.destAddr, fulfillAmount);
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
			if (params.payloadType == 2) {
				pendingAmounts[params.orderHash] = fulfillAmount;
			} else {
				IERC20(params.tokenOut).safeTransfer(params.destAddr, fulfillAmount);
			}
		}
	}

	function buildUnlockMsg(
		bytes32 orderHash,
		OrderParams memory params,
		ExtraParams memory extraParams,
		bytes32 recipient
	) internal view returns (UnlockMsg memory) {
		return UnlockMsg({
			action: uint8(Action.UNLOCK),
			orderHash: orderHash,
			srcChainId: extraParams.srcChainId,
			tokenIn: extraParams.tokenIn,
			referrerAddr: params.referrerAddr,
			referrerBps: params.referrerBps,
			protocolBps: extraParams.protocolBps,
			unlockReceiver: recipient,
			driver: bytes32(uint256(uint160(tx.origin))),
			fulfillTime: uint64(block.timestamp)
		});
	}

	function batchOrSendUnlockMsg(UnlockMsg memory unlockMsg, bool batch) internal returns (uint64 sequence) {
		bytes memory encodedUnlockMsg = encodeUnlockMsg(unlockMsg);

		if (batch) {
			unlockMsgs[unlockMsg.orderHash] = encodedUnlockMsg;
		} else {
			return wormhole.publishMessage{
				value : wormhole.messageFee()
			}(0, abi.encodePacked(Action.UNLOCK, encodedUnlockMsg), consistencyLevel);
		}
	}

	function buildKey(
		OrderParams memory params, 
		ExtraParams memory extraParams
	) internal pure returns (Key memory) {
		return Key({
			payloadType: params.payloadType,
			trader: params.trader,
			srcChainId: extraParams.srcChainId,
			tokenIn: extraParams.tokenIn,
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
			protocolBps: extraParams.protocolBps,
			auctionMode: params.auctionMode,
			baseBond: params.baseBond,
			perBpsBond: params.perBpsBond,
			random: params.random,
			customPayloadHash: extraParams.customPayloadHash
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

		fulfillMsg.promisedAmount = encoded.toUint64(index);
		index += 8;

		fulfillMsg.driver = encoded.toBytes32(index);
		index += 32;
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
			//unlockMsg.action,
			unlockMsg.orderHash,
			unlockMsg.srcChainId,
			unlockMsg.tokenIn,
			unlockMsg.referrerAddr,
			unlockMsg.referrerBps,
			unlockMsg.protocolBps,
			unlockMsg.unlockReceiver,
			unlockMsg.driver,
			unlockMsg.fulfillTime
		);
	}

	function encodeRefundMsg(RefundMsg memory refundMsg) internal pure returns (bytes memory encoded) {
		encoded = abi.encodePacked(
			refundMsg.action,
			refundMsg.orderHash,
			refundMsg.srcChainId,
			refundMsg.tokenIn,
			refundMsg.trader,
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

	function pullTokenIn(
		address tokenIn,
		uint256 amountIn,
		PermitParams calldata permitParams
	) internal returns (uint256) {
		uint256 allowance = IERC20(tokenIn).allowance(msg.sender, address(this));
		if (allowance < amountIn) {
			execPermit(tokenIn, msg.sender, permitParams);
		}
		uint256 balance = IERC20(tokenIn).balanceOf(address(this));
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
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

	function setAuctionConfig(address _auctionVerifier, uint16 _auctionChainId, bytes32 _auctionAddr) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		if (_auctionChainId == 0 || _auctionAddr == bytes32(0)) {
			revert InvalidAuctionConfig();
		}
		auctionVerifier = _auctionVerifier;
		auctionChainId = _auctionChainId;
		auctionAddr = _auctionAddr;
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