// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IWormhole.sol";
import "../interfaces/IFeeManager.sol";
import "../libs/BytesLib.sol";
import "../libs/SignatureVerifier.sol";
import "./SwiftStructs.sol";
import "./SwiftErrors.sol";

contract SwiftSource is ReentrancyGuard {
	event OrderCreated(bytes32 key);
	event OrderFulfilled(bytes32 key, uint64 sequence, uint256 netAmount);
	event OrderUnlocked(bytes32 key);
	event OrderCanceled(bytes32 key, uint64 sequence);
	event OrderRefunded(bytes32 key, uint256 netAmount);

	using SafeERC20 for IERC20;
	using BytesLib for bytes;
	using SignatureVerifier for bytes;

	uint8 constant BPS_FEE_LIMIT = 100;
	uint8 constant NATIVE_DECIMALS = 18;

	IWormhole public immutable wormhole;
	IFeeManager public feeManager;
	address public guardian;
	address public nextGuardian;
	bool public paused;

	bytes32 private domainSeparator;

	mapping(bytes32 => Order) public orders;
	mapping(uint16 => bytes32) public emitters;

	constructor(address _wormhole, address _feeManager) {
		guardian = msg.sender;
		wormhole = IWormhole(_wormhole);
		feeManager = IFeeManager(_feeManager);

		domainSeparator = keccak256(abi.encode(
			keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
			keccak256("Mayan Swift"),
			uint256(block.chainid),
			address(this)
		));
	}

	function createOrderWithEth(OrderParams memory params, bytes memory customPayload) nonReentrant external payable returns (bytes32 orderHash) {
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

		bytes32 customPayloadHash;
		if (params.payloadType == 2) {
			customPayloadHash = keccak256(customPayload);
		}

		Key memory key = buildKey(params, bytes32(0), wormhole.chainId(), protocolBps, customPayloadHash);

		orderHash = keccak256(encodeKey(key));

		if (emitters[params.destChainId] == 0 || params.destChainId == wormhole.chainId()) {
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
		OrderParams memory params,
		bytes memory customPayload
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

		bytes32 customPayloadHash;
		if (params.payloadType == 2) {
			customPayloadHash = keccak256(customPayload);
		}

		Key memory key = buildKey(params, bytes32(uint256(uint160(tokenIn))), wormhole.chainId(), protocolBps, customPayloadHash);

		orderHash = keccak256(encodeKey(key));

		if (emitters[params.destChainId] == 0 || params.destChainId == wormhole.chainId()) {
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
		bytes memory customPayload,
		uint256 submissionFee,
		bytes calldata signedOrderHash,
		PermitParams calldata permitParams
	) nonReentrant external returns (bytes32 orderHash) {
		if (paused) {
			revert Paused();
		}

		address trader = truncateAddress(params.trader);
		if (IERC20(tokenIn).allowance(trader, address(this)) < amountIn + submissionFee) {
			execPermit(tokenIn, trader, permitParams);
		}
		amountIn = pullTokensFrom(tokenIn, amountIn, trader);
		if (submissionFee > 0) {
			IERC20(tokenIn).safeTransferFrom(trader, address(feeManager), submissionFee);
			feeManager.depositFee(msg.sender, tokenIn, submissionFee);
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

		orderHash = keccak256(encodeKey(buildKey(
			params,
			bytes32(uint256(uint160(tokenIn))),
			wormhole.chainId(),
			protocolBps,
			params.payloadType == 2 ? keccak256(customPayload) : bytes32(0)
		)));

		signedOrderHash.verify(hashTypedData(orderHash, amountIn, submissionFee), trader);

		if (emitters[params.destChainId] == 0 || params.destChainId == wormhole.chainId()) {
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

	function unlockOrder(UnlockMsg memory unlockMsg, Order memory order) internal {
		if (unlockMsg.srcChainId != wormhole.chainId()) {
			revert InvalidSrcChain();
		}
		if (order.status != Status.CREATED) {
			revert InvalidOrderStatus();
		}
		orders[unlockMsg.orderHash].status = Status.UNLOCKED;
		
		address receiver = truncateAddress(unlockMsg.unlockReceiver);
		address tokenIn = truncateAddress(unlockMsg.tokenIn);
		uint8 decimals;
		if (tokenIn == address(0)) {
			decimals = NATIVE_DECIMALS;
		} else {
			decimals = decimalsOf(tokenIn);
		}

		uint64 normalizedReferrerFee = order.amountIn * unlockMsg.referrerBps / 10000;
		address referrerAddress = address(uint160(uint256(unlockMsg.referrerAddr)));

		uint64 normalizedProtocolFee = order.amountIn * unlockMsg.protocolBps / 10000;
		address feeCollector = feeManager.feeCollector();

		uint64 netAmount = order.amountIn - normalizedReferrerFee - normalizedProtocolFee;

		if (tokenIn == address(0)) {
			if (normalizedReferrerFee > 0 && referrerAddress != address(0)) {
				payEth(referrerAddress, deNormalizeAmount(normalizedReferrerFee, decimals), false);
			}
			if (normalizedProtocolFee > 0 && feeCollector != address(0)) {
				payEth(feeCollector, deNormalizeAmount(normalizedProtocolFee, decimals), false);
			}
			if (netAmount > 0) {
				payEth(receiver, deNormalizeAmount(netAmount, decimals), true);
			}
		} else {
			if (normalizedReferrerFee > 0 && referrerAddress != address(0)) {
				IERC20(tokenIn).safeTransfer(referrerAddress, deNormalizeAmount(normalizedReferrerFee, decimals));
			}
			if (normalizedProtocolFee > 0 && feeCollector != address(0)) {
				IERC20(tokenIn).safeTransfer(feeCollector, deNormalizeAmount(normalizedProtocolFee, decimals));
			}
			if (netAmount > 0) {
				IERC20(tokenIn).safeTransfer(receiver, deNormalizeAmount(netAmount, decimals));
			}
		}
		
		emit OrderUnlocked(unlockMsg.orderHash);
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
			revert OrderNotExists(refundMsg.orderHash);
		}
		if (order.status != Status.CREATED) {
			revert InvalidOrderStatus();
		}
		orders[refundMsg.orderHash].status = Status.REFUNDED;

		if (vm.emitterChainId != order.destChainId) {
			revert InvalidEmitterChain();
		}
		if (vm.emitterAddress != emitters[order.destChainId]) {
			revert InvalidEmitterAddress();
		}

		address trader = truncateAddress(refundMsg.trader);
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
			payEth(canceler, cancelFee, false);
			payEth(address(feeManager), refundFee, false);
			feeManager.depositFee(msg.sender, address(0), refundFee);
			payEth(trader, netAmount, true);
		} else {
			IERC20(tokenIn).safeTransfer(canceler, cancelFee);
			IERC20(tokenIn).safeTransfer(address(feeManager), refundFee);
			feeManager.depositFee(msg.sender, tokenIn, refundFee);
			IERC20(tokenIn).safeTransfer(trader, netAmount);
		}

		emit OrderRefunded(refundMsg.orderHash, netAmount);
	}

	function unlockSingle(bytes memory encodedVm) nonReentrant public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);

		UnlockMsg memory unlockMsg = parseUnlockPayload(vm.payload);
		Order memory order = orders[unlockMsg.orderHash];

		if (order.destChainId == 0) {
			revert OrderNotExists(unlockMsg.orderHash);
		}
		if (vm.emitterChainId != order.destChainId) {
			revert InvalidEmitterChain();
		}
		if (vm.emitterAddress != emitters[order.destChainId]) {
			revert InvalidEmitterAddress();
		}

		unlockOrder(unlockMsg, order);
	}

	function unlockBatch(bytes memory encodedVm, uint16[] memory indexes) nonReentrant public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);

		uint8 action = vm.payload.toUint8(0);
		if (action != uint8(Action.BATCH_UNLOCK)) {
			revert InvalidAction();
		}

		// skip action (1 byte)
		processUnlocks(vm.payload, 1, vm.emitterChainId, vm.emitterAddress, indexes);
	}
	
	function unlockCompressedBatch(bytes memory encodedVm, bytes memory encodedPayload, uint16[] memory indexes) nonReentrant public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);

		uint8 action = vm.payload.toUint8(0);
		if (action != uint8(Action.BATCH_UNLOCK)) {
			revert InvalidAction();
		}
		bytes32 computedHash = keccak256(encodedPayload);
		bytes32 msgHash = vm.payload.toBytes32(1);

		if (computedHash != msgHash) {
			revert InvalidPayload();
		}

		// skip action and hash (33 bytes)
		processUnlocks(encodedPayload, 33, vm.emitterChainId, vm.emitterAddress, indexes);
	}

	function processUnlocks(bytes memory payload, uint offset, uint16 emitterChainId, bytes32 emitterAddress, uint16[] memory indexes) internal {
		uint16 count = payload.toUint16(offset);
		offset += 2;

		// If indexes array is empty, create a default array to iterate over all indices
		if (indexes.length == 0) {
			indexes = new uint16[](count);
			for (uint16 i = 0; i < count; i++) {
				indexes[i] = i;
			}
		}

		for (uint i = 0; i < indexes.length; i++) {
			uint16 index = indexes[i];
			if (index >= count) {
				revert InvalidBatchIndex();
			}

			uint currentOffset = offset + index * UNLOCK_MSG_SIZE;

			UnlockMsg memory unlockMsg = UnlockMsg({
				action: uint8(Action.UNLOCK),
				orderHash: payload.toBytes32(currentOffset),
				srcChainId: payload.toUint16(currentOffset + 32),
				tokenIn: payload.toBytes32(currentOffset + 34),
				referrerAddr: payload.toBytes32(currentOffset + 66),
				referrerBps: payload.toUint8(currentOffset + 98),
				protocolBps: payload.toUint8(currentOffset + 99),
				unlockReceiver: payload.toBytes32(currentOffset + 100),
				driver: payload.toBytes32(currentOffset + 132),
				fulfillTime: payload.toUint64(currentOffset + 164)
			});

			Order memory order = orders[unlockMsg.orderHash];
			if (order.status != Status.CREATED) {
				continue;
			}
			if (emitterChainId != order.destChainId) {
				revert InvalidEmitterChain();
			}
			if (emitterAddress != emitters[order.destChainId]) {
				revert InvalidEmitterAddress();
			}

			unlockOrder(unlockMsg, order);
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

		unlockMsg.referrerAddr = encoded.toBytes32(index);
		index += 32;

		unlockMsg.referrerBps = encoded.toUint8(index);
		index += 1;

		unlockMsg.protocolBps = encoded.toUint8(index);
		index += 1;

		unlockMsg.unlockReceiver = encoded.toBytes32(index);
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

		refundMsg.trader = encoded.toBytes32(index);
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

	function payEth(address to, uint256 amount, bool revertOnFailure) internal {
		(bool success, ) = payable(to).call{value: amount}('');
		if (revertOnFailure) {
			require(success, 'payment failed');
		}
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

	function setEmitters(uint16[] memory chainIds, bytes32[] memory addresses) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		require(chainIds.length == addresses.length, 'invalid array length');
		for (uint i=0; i<chainIds.length; i++) {
			if (emitters[chainIds[i]] != bytes32(0)) {
				revert EmitterAddressExists();
			}
			emitters[chainIds[i]] = addresses[i];
		}
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