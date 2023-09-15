// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IWormhole.sol";
import "./interfaces/IWETH.sol";
import "./libs/BytesLib.sol";

contract MayanSwift {
	event OrderCreated(bytes32 key);
	event OrderFulfilled(bytes32 key);
	event OrderUnlocked(bytes32 key);
	event CancelInitiated(bytes32 key);
	event CancelCompleted(bytes32 key);

	using SafeERC20 for IERC20;
	using BytesLib for bytes;

	IWormhole wormhole;
	address feeCollector;
	uint16 hqChainId;
	bytes32 hqAddr;
	uint8 consistencyLevel;
	address guardian;
	address nextGuardian;
	bool paused;

	struct Order {
		bytes32 destAuthority;
		uint16 destChainId;
		Status status;
	}

	struct Key {
		bytes32 trader;
		uint16 srcChainId;
		bytes32 tokenIn;
		uint64 amountIn;
		bytes32 tokenOut;
		uint64 minAmountOut;
		uint64 gasDrop;
		bytes32 destAddr;
		uint16 destChainId;
		bytes32 referrerAddr;
		bytes32 random;
	}

	enum Status {
		CREATED,
		FULFILLED,
		UNLOCKED,
		CANCEL_INITIATED,
		CANCEL_COMPLETED
	}

	struct SwiftMsg {
		uint8 action;
		bytes32 keyHash;
		uint16 srcChain;
		bytes32 tokenIn;
		uint64 amountIn;
		bytes32 recipient;
	}

	struct FulfillMsg {
		uint8 action;
		bytes32 keyHash;
		uint16 destChainId;
		bytes32 destAddr;
		bytes32 driver;
		bytes32 tokenOut;
		uint64 amountPromised;
		bytes32 referrerAddr;
		uint8 referrerBps;
		uint8 mayanBps;
		uint16 srcChain;
		bytes32 tokenIn;
		uint64 amountIn;
	}

	constructor(address _wormhole, address _feeCollector, uint16 _hqChainId, bytes32 _hqAddr, uint8 _consistencyLevel) {
		guardian = msg.sender;
		wormhole = IWormhole(_wormhole);
		feeCollector = _feeCollector;
		hqChainId = _hqChainId;
		hqAddr = _hqAddr;
		consistencyLevel = _consistencyLevel;
	}

	mapping(bytes32 => Order) orders;

	function createOrderWithEth(bytes32 tokenOut, uint64 minAmountOut, uint64 gasDrop, bytes32 destAddr, uint8 destChainId, bytes32 referrerAddr, bytes32 random, bytes32 destAuthority) public payable returns (bytes32 keyHash) {
		require(paused == false, 'contract is paused');

		uint64 normlizedAmountIn = uint64(normalizeAmount(msg.value, 18));
		require(normlizedAmountIn > 0, 'small amount in');

		Key memory key = Key({
			trader: bytes32(uint256(uint160(msg.sender))),
			srcChainId: wormhole.chainId(),
			tokenIn: bytes32(0),
			amountIn: normlizedAmountIn,
			tokenOut: tokenOut,
			minAmountOut: minAmountOut,
			gasDrop: gasDrop,
			destAddr: destAddr,
			destChainId: destChainId,
			referrerAddr: referrerAddr,
			random: random
		});
		keyHash = keccak256(encodeKey(key));

		require(destChainId > 0, 'invalid dest chain id');
		require(orders[keyHash].destChainId == 0, 'duplicate key');

		orders[keyHash].destChainId = destChainId;
		orders[keyHash].status = Status.CREATED;
		if (destAuthority != bytes32(0)) {
			orders[keyHash].destAuthority = destAuthority;
		}

		emit OrderCreated(keyHash);
	}

	function createOrderWithToken(bytes32 tokenOut, uint64 minAmountOut, uint64 gasDrop, bytes32 destAddr, uint16 destChainId, address tokenIn, uint256 amountIn, bytes32 referrerAddr, bytes32 random, bytes32 destAuthority) public returns (bytes32 keyHash) {
		require(paused == false, 'contract is paused');

		uint256 balance = IERC20(tokenIn).balanceOf(address(this));
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		amountIn = IERC20(tokenIn).balanceOf(address(this)) - balance;

		uint64 normlizedAmountIn = uint64(normalizeAmount(amountIn, decimalsOf(tokenIn)));
		require(normlizedAmountIn > 0, 'small amount in');

		Key memory key = Key({
			trader: bytes32(uint256(uint160(msg.sender))),
			srcChainId: wormhole.chainId(),
			tokenIn: bytes32(uint256(uint160(tokenIn))),
			amountIn: normlizedAmountIn,
			tokenOut: tokenOut,
			minAmountOut: minAmountOut,
			gasDrop: gasDrop,
			destAddr: destAddr,
			destChainId: destChainId,
			referrerAddr: referrerAddr,
			random: random
		});
		keyHash = keccak256(encodeKey(key));

		require(destChainId > 0, 'invalid dest chain id');
		require(orders[keyHash].destChainId == 0, 'duplicate key');

		orders[keyHash] = Order({
			destAuthority: destAuthority,
			destChainId: destChainId,
			status: Status.CREATED
		});

		if (destAuthority != bytes32(0)) {
			orders[keyHash].destAuthority = destAuthority;
		}

		emit OrderCreated(keyHash);
	}

	function fulfillOrder(bytes memory encodedVm, bytes32 recepient) public payable returns (uint64 sequence) {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);
		require(vm.emitterChainId == hqChainId, 'invalid HQ chain');
		require(vm.emitterAddress == hqAddr, 'invalid HQ address');

		FulfillMsg memory fulfillMsg = parseFulfillPayload(vm.payload);

		require(fulfillMsg.destChainId == wormhole.chainId(), 'wrong chain id');
		require(truncateAddress(fulfillMsg.driver) == msg.sender, 'invalid driver');

		Order memory order = orders[fulfillMsg.keyHash];
		require(order.status == Status.CREATED, 'invalid order status');
		
		order.status = Status.FULFILLED;

		makePayments(fulfillMsg);

		SwiftMsg memory unlockMsg = SwiftMsg({
			action: 2,
			keyHash: fulfillMsg.keyHash,
			srcChain: fulfillMsg.srcChain,
			tokenIn: fulfillMsg.tokenIn,
			amountIn: fulfillMsg.amountIn,
			recipient: recepient
		});

		bytes memory encoded = encodeSwiftMsg(unlockMsg);

		sequence = wormhole.publishMessage{
			value : msg.value
		}(0, encoded, consistencyLevel);

		emit OrderFulfilled(fulfillMsg.keyHash);
	}

	function unlockOrder(bytes memory encodedVm) public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);

		SwiftMsg memory swift = parseSwiftPayload(vm.payload);
		Order memory order = orders[swift.keyHash];

		require(vm.emitterChainId == order.destChainId, 'invalid emitter chain');

		if (order.destChainId == hqChainId) {
			require(vm.emitterAddress == hqAddr, 'invalid emitter address');
		} else if (order.destAuthority != bytes32(0)) {
			require(vm.emitterAddress == order.destAuthority, 'invalid emitter address');
		} else {
			require(truncateAddress(vm.emitterAddress) == address(this), 'invalid emitter address');
		}

		require(order.status == Status.CREATED, 'order status not created');
		require(swift.srcChain == wormhole.chainId(), 'invalid source chain');
		require(swift.action == 2, 'wrong action');
		
		orders[swift.keyHash].status = Status.UNLOCKED;
		
		address recipient = truncateAddress(swift.recipient);
		address tokenIn = truncateAddress(swift.tokenIn);
		uint8 decimals;
		if (tokenIn == address(0)) {
			decimals = 18;
		} else {
			decimals = decimalsOf(tokenIn);
		}

		uint256 amountIn = deNormalizeAmount(swift.amountIn, decimals);
		if (tokenIn == address(0)) {
			payable(recipient).transfer(amountIn);
		} else {
			IERC20(tokenIn).safeTransfer(recipient, amountIn);
		}
		
		emit OrderUnlocked(swift.keyHash);
	}

	function CompleteCancelOrder(bytes memory encodedVm) public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);

		SwiftMsg memory swift = parseSwiftPayload(vm.payload);
		Order memory order = orders[swift.keyHash];

		require(vm.emitterChainId == order.destChainId, 'invalid emitter chain');

		if (order.destChainId == hqChainId) {
			require(vm.emitterAddress == hqAddr, 'invalid emitter address');
		} else if (order.destAuthority != bytes32(0)) {
			require(vm.emitterAddress == order.destAuthority, 'invalid emitter address');
		} else {
			require(truncateAddress(vm.emitterAddress) == address(this), 'invalid emitter address');
		}

		require(order.status == Status.CREATED, 'order status is not created');
		require(swift.srcChain == wormhole.chainId(), 'invalid source chain');
		require(swift.action == 3, 'wrong action');
		
		orders[swift.keyHash].status = Status.CANCEL_COMPLETED;
		
		address trader = truncateAddress(swift.recipient);
		require(trader == msg.sender, 'invalid canceller');

		address tokenIn = truncateAddress(swift.tokenIn);
		uint8 decimals;
		if (tokenIn == address(0)) {
			decimals = 18;
		} else {
			decimals = decimalsOf(tokenIn);
		}

		uint256 amountIn = deNormalizeAmount(swift.amountIn, decimals);
		if (tokenIn == address(0)) {
			payable(trader).transfer(amountIn);
		} else {
			IERC20(tokenIn).safeTransfer(trader, amountIn);
		}

		emit CancelCompleted(swift.keyHash);
	}

	function InitiateCancelOrder(uint16 srcChainId, bytes32 tokenIn, uint64 amountIn, bytes32 tokenOut, uint64 minAmountOut, uint64 gasDrop, bytes32 destAddr, uint16 destChainId, bytes32 referrerAddr, bytes32 random) public payable returns (uint64 sequence) {
		Key memory key = Key({
			trader: bytes32(uint256(uint160(msg.sender))),
			srcChainId: srcChainId,
			tokenIn: tokenIn,
			amountIn: amountIn,
			tokenOut: tokenOut,
			minAmountOut: minAmountOut,
			gasDrop: gasDrop,
			destAddr: destAddr,
			destChainId: destChainId,
			referrerAddr: referrerAddr,
			random: random
		});
		bytes32 keyHash = keccak256(encodeKey(key));
		Order memory order = orders[keyHash];

		require(order.status == Status.CREATED, 'invalid order status');

		orders[keyHash].status = Status.CANCEL_INITIATED;

		SwiftMsg memory cancelMsg = SwiftMsg({
			action: 3,
			keyHash: keyHash,
			srcChain: key.srcChainId,
			tokenIn: key.tokenIn,
			amountIn: key.amountIn,
			recipient: key.trader
		});

		bytes memory encoded = encodeSwiftMsg(cancelMsg);

		sequence = wormhole.publishMessage{
			value : msg.value
		}(0, encoded, consistencyLevel);

		emit CancelInitiated(keyHash);
	}

	function makePayments(FulfillMsg memory fulfillMsg) internal {
		address tokenOut = truncateAddress(fulfillMsg.tokenOut);
		uint8 decimals;
		if (tokenOut == address(0)) {
			decimals = 18;
		} else {
			decimals = decimalsOf(tokenOut);
		}

		uint256 amountPromised = deNormalizeAmount(fulfillMsg.amountIn, decimals);
		address referrerAddr = truncateAddress(fulfillMsg.referrerAddr);
		
		uint256 amountReferrer = 0;
		if (referrerAddr != address(0) && fulfillMsg.referrerBps != 0) {
			amountReferrer = amountPromised * fulfillMsg.referrerBps / 10000;
		}

		uint256 amountMayan = 0;
		if (fulfillMsg.mayanBps != 0) {
			amountMayan = amountPromised * fulfillMsg.mayanBps / 10000;
		}

		address destAddr = truncateAddress(fulfillMsg.destAddr);
		if (tokenOut == address(0)) {
			if (amountReferrer > 0) {
				payable(referrerAddr).transfer(amountReferrer);
			}
			if (amountMayan > 0) {
				payable(feeCollector).transfer(amountMayan);
			}
			payable(destAddr).transfer(amountPromised - amountReferrer - amountMayan);
		} else {
			if (amountReferrer > 0) {
				IERC20(tokenOut).safeTransferFrom(msg.sender, referrerAddr, amountReferrer);
			}
			if (amountMayan > 0) {
				IERC20(tokenOut).safeTransferFrom(msg.sender, feeCollector, amountMayan);
			}
			IERC20(tokenOut).safeTransferFrom(msg.sender, destAddr, amountPromised - amountReferrer - amountMayan);
		}
	}

	function parseFulfillPayload(bytes memory encoded) public pure returns (FulfillMsg memory fulfillMsg) {
		uint index = 0;

		fulfillMsg.action = encoded.toUint8(index);
		index += 1;

		// actions: 1 = fulfill, 2 = unlock 3 = init cancel
		require(fulfillMsg.action == 1, 'invalid action');

		fulfillMsg.keyHash = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.destChainId = encoded.toUint16(index);
		index += 2;

		fulfillMsg.destAddr = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.driver = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.tokenOut = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.amountPromised = encoded.toUint64(index);
		index += 8;

		fulfillMsg.referrerAddr = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.referrerBps = encoded.toUint8(index);
		index += 1;

		fulfillMsg.mayanBps = encoded.toUint8(index);
		index += 1;

		fulfillMsg.srcChain = encoded.toUint16(index);
		index += 2;

		fulfillMsg.tokenIn = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.amountIn = encoded.toUint64(index);
		index += 32;

		require(encoded.length == index, 'invalid msg lenght');
	}

	function parseSwiftPayload(bytes memory encoded) public pure returns (SwiftMsg memory swiftMsg) {
		uint index = 0;

		swiftMsg.action = encoded.toUint8(index);
		index += 1;

		// actions: 1 = fulfill, 2 = unlock 3 = init cancel
		require(swiftMsg.action == 2 || swiftMsg.action == 3, 'invalid action');

		swiftMsg.keyHash = encoded.toBytes32(index);
		index += 32;

		swiftMsg.srcChain = encoded.toUint16(index);
		index += 2;

		swiftMsg.tokenIn = encoded.toBytes32(index);
		index += 32;

		swiftMsg.recipient = encoded.toBytes32(index);
		index += 32;

		require(encoded.length == index, 'invalid msg lenght');
	}

	function encodeKey(Key memory key) internal pure returns (bytes memory encoded) {
		encoded = abi.encodePacked(
			key.trader,
			key.srcChainId,
			key.tokenIn,
			key.amountIn,
			key.tokenOut,
			key.minAmountOut,
			key.gasDrop,
			key.destAddr,
			key.destChainId,
			key.referrerAddr,
			key.random
		);
	}

	function encodeSwiftMsg(SwiftMsg memory swiftMsg) internal pure returns (bytes memory encoded) {
		encoded = abi.encodePacked(
			swiftMsg.action,
			swiftMsg.keyHash,
			swiftMsg.srcChain,
			swiftMsg.tokenIn,
			swiftMsg.recipient
		);
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

	function getOrder(bytes32 key) public view returns (Order memory) {
		return orders[key];
	}

	function getHqChainId() public view returns (uint16) {
		return hqChainId;
	}

	function getEmitterAddr() public view returns (bytes32) {
		return hqAddr;
	}

	receive() external payable {}
}