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
	uint16 hqChainId;
	bytes32 hqAddr;
	uint8 consistencyLevel;
	address guardian;
	address nextGuardian;
	bool paused;

	struct Order {
		bytes32 dstAuthority;
		uint8 dstChainId;
		Status status;
	}

	struct Key {
		address trader;
		uint16 srcChainId;
		address tokenIn;
		uint256 amountIn;
		bytes32 tokenOut;
		uint256 minAmountOut;
		uint64 gasDrop;
		bytes32 destAddr;
		uint8 destChainId;
		bytes32 referrerAddr;
		bytes32 nonce;
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
		bytes32 key;
		uint16 srcChain;
		address trader;
		address tokenIn;
		uint256 amountIn;
		bytes32 recipient;
	}

	constructor(address _wormhole, uint16 _hqChainId, bytes32 _hqAddr, uint8 _consistencyLevel) {
		guardian = msg.sender;
		wormhole = IWormhole(_wormhole);
		hqChainId = _hqChainId;
		hqAddr = _hqAddr;
		consistencyLevel = _consistencyLevel;
	}

	mapping(bytes32 => Order) orders;

	function createOrderWithEth(bytes32 tokenOut, uint64 minAmountOut, uint64 gasDrop, bytes32 dstAddr, uint8 dstChainId, bytes32 referrerAddr, bytes32 nonce, bytes32 dstAuthority) public payable {
		require(paused == false, 'contract is paused');
		require(msg.value > 0, 'value is zero');

		bytes32 key = keccak256(abi.encodePacked(msg.sender, wormhole.chainId(), address(0), msg.value, tokenOut, minAmountOut, gasDrop, dstAddr, dstChainId, referrerAddr, nonce));

		require(dstChainId > 0, 'invalid dest chain id');
		require(orders[key].dstChainId == 0, 'duplicate key');

		orders[key] = Order({
			dstAuthority: dstAuthority,
			dstChainId: dstChainId,
			status: Status.CREATED
		});

		emit OrderCreated(key);
	}

	function createOrderWithToken(bytes32 tokenOut, uint64 minAmountOut, uint64 gasDrop, bytes32 dstAddr, uint8 dstChainId, address tokenIn, uint256 amountIn, bytes32 referrerAddr, bytes32 nonce, bytes32 dstAuthority) public {
		require(paused == false, 'contract is paused');

		uint256 balance = IERC20(tokenIn).balanceOf(address(this));
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		amountIn = IERC20(tokenIn).balanceOf(address(this)) - balance;
		require(amountIn > 0, 'zero amount in');

		Key memory key = Key({
			trader: msg.sender,
			srcChainId: wormhole.chainId(),
			tokenIn: tokenIn,
			amountIn: amountIn,
			tokenOut: tokenOut,
			minAmountOut: minAmountOut,
			gasDrop: gasDrop,
			dstAddr: dstAddr,
			dstChainId: dstChainId,
			referrerAddr: referrerAddr,
			nonce: nonce
		});
		bytes32 keyHash = keccak256(abi.encodePacked(key.trader, key.srcChainId, key.tokenIn, key.amountIn, key.tokenOut, key.minAmountOut, key.gasDrop, key.destAddr, key.destChainId, key.referrerAddr, key.nonce));

		require(dstChainId > 0, 'invalid dest chain id');
		require(orders[keyHash].dstChainId == 0, 'duplicate key');

		orders[keyHash] = Order({
			dstAuthority: dstAuthority,
			dstChainId: dstChainId,
			status: Status.CREATED
		});

		if (dstAuthority != bytes32(0)) {
			orders[keyHash].dstAuthority = dstAuthority;
		}

		emit OrderCreated(keyHash);
	}

	function fulfillOrder(bytes memory encodedVm) public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);
		require(vm.emitterChainId == hqChainId, 'invalid HQ chain');
		require(vm.emitterAddress == hqAddr, 'invalid HQ address');

		SwiftMsg memory swift = parseSwiftPayload(vm.payload);
	}

	function unlockOrder(bytes memory encodedVm) public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);

		SwiftMsg memory swift = parseSwiftPayload(vm.payload);
		Order memory order = orders[swift.key];

		require(vm.emitterChainId == order.dstChainId, 'invalid emitter chain');

		if (order.dstChainId == hqChainId) {
			require(vm.emitterAddress == hqAddr, 'invalid emitter address');
		} else if (order.dstAuthority != bytes32(0)) {
			require(vm.emitterAddress == order.dstAuthority, 'invalid emitter address');
		} else {
			require(truncateAddress(vm.emitterAddress) == address(this), 'invalid emitter address');
		}

		require(order.status == Status.CREATED, 'order status not created');
		require(swift.srcChain == wormhole.chainId(), 'invalid source chain');
		require(swift.action == 1, 'wrong action');
		
		orders[swift.key].status = Status.UNLOCKED;
		
		address recipient = truncateAddress(swift.recipient);
		if (order.tokenIn == address(0)) {
			payable(recipient).transfer(order.amountIn);
		} else {
			IERC20(order.tokenIn).safeTransfer(recipient, order.amountIn);
		}
		
		emit OrderUnlocked(swift.key);
	}

	function CompleteCancelOrder(bytes memory encodedVm) public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);

		SwiftMsg memory swift = parseSwiftPayload(vm.payload);
		Order memory order = orders[swift.key];

		require(vm.emitterChainId == order.dstChainId, 'invalid emitter chain');

		if (order.dstChainId == hqChainId) {
			require(vm.emitterAddress == hqAddr, 'invalid emitter address');
		} else if (order.dstAuthority != bytes32(0)) {
			require(vm.emitterAddress == order.dstAuthority, 'invalid emitter address');
		} else {
			require(truncateAddress(vm.emitterAddress) == address(this), 'invalid emitter address');
		}

		require(order.status == Status.CREATED, 'order status is not created');
		require(swift.sourceChain == wormhole.chainId(), 'invalid source chain');
		require(swift.action == 3, 'wrong action');
		
		orders[swift.key].status = Status.CANCELED;
		
		address recipient = truncateAddress(swift.recipient);
		require(recipient == order.trader, 'invalid canceller');

		if (swift.tokenIn == address(0)) {
			payable(recipient).transfer(swift.amountIn);
		} else {
			IERC20(swift.tokenIn).safeTransfer(recipient, swift.amountIn);
		}

		emit CancelCompleted(swift.key);
	}

	function InitiateCancelOrder(uint16 srcChainId, address tokenIn, uint256 amountIn, bytes32 tokenOut, uint256 minAmountOut, uint64 gasDrop, bytes32 destAddr, uint8 destChainId, bytes32 referrerAddr, bytes32 nonce) public payable returns (uint64 sequence) {
		Key memory key = Key({
			trader: msg.sender,
			srcChainId: srcChainId,
			tokenIn: tokenIn,
			amountIn: amountIn,
			tokenOut: tokenOut,
			minAmountOut: minAmountOut,
			gasDrop: gasDrop,
			destAddr: destAddr,
			destChainId: destChainId,
			referrerAddr: referrerAddr,
			nonce: nonce
		});
		bytes32 keyHash = keccak256(abi.encodePacked(key));

		Order memory order = orders[keyHash];

		require(order.status == Status.CREATED, 'invalid order status');

		orders[keyHash].status = Status.CANCEL_INITIATED;

		uint8 action = 3;
		bytes memory encoded = abi.encodePacked(
			action,
			keyHash,
			key.trader,
			key.srcChainId,
			key.tokenIn,
			key.amountIn
		);

		sequence = wormhole.publishMessage{
			value : msg.value
		}(0, encoded, consistencyLevel);

		emit CancelInitiated(key);
	}

	function parseSwiftPayload(bytes memory encoded) public pure returns (SwiftMsg memory swiftMsg) {
        uint index = 0;

		swiftMsg.action = encoded.toUint8(index);
		index += 1;

		// actions: 1 = fulfill, 2 = unlock 3 = cancel
		require(swiftMsg.action > 0 && swiftMsg.action < 4, 'invalid action');

        swiftMsg.keyHash = encoded.toBytes32(index);
        index += 32;

		swiftMsg.trader = encoded.toBytes32(index);
		index += 32;

        swiftMsg.srcChain = encoded.toUint16(index);
        index += 2;

		if (swiftMsg.action == 2) {
			swiftMsg.recipient = encoded.toBytes32(index);
			index += 32;
		}

        require(encoded.length == index, 'invalid swift msg');
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