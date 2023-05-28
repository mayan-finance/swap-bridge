// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IWormhole.sol";
import "./interfaces/IWETH.sol";
import "./libs/BytesLib.sol";

contract MayanSwift {
	event OrderCreatedWithEth(bytes32 key);
	event OrderCreatedWithToken(bytes32 key);
	event OrderCompleted(bytes32 key);
	event OrderCanceled(bytes32 key);

	using SafeERC20 for IERC20;
	using BytesLib for bytes;

	IWormhole wormhole;
	uint16 emitterChainId;
	bytes32 emitterAddr;
	address guardian;
	address nextGuardian;
	bool paused;

	struct Order {
		address tokenIn;
		uint256 amountIn;
		bytes32 tokenOut;
		uint64 amountOut;
		bytes32 destAddr;
		Status status;
	}

	enum Status {
		CREATED,
		COMPLETED,
		CANCELED
	}

	struct Swift {
		uint8 action;
		bytes32 key;
		uint16 sourceChain;
		bytes32 tokenOut;
		uint64 amountOut;
		bytes32 destAddr;
		bytes32 recipient;
	}

	constructor(address _wormhole, uint16 _emitterChainId, bytes32 _emitterAddr) {
		guardian = msg.sender;
		wormhole = IWormhole(_wormhole);
		emitterChainId = _emitterChainId;
		emitterAddr = _emitterAddr;
	}

	mapping(bytes32 => Order) orders;

	function createOrderWithEth(bytes32 key, bytes32 tokenOut, uint64 amountOut, bytes32 destAddr) public payable {
		require(paused == false, 'contract is paused');
		require(msg.value > 0, 'value is zero');
		require(orders[key].amountIn == 0, 'duplicate key');

		orders[key] = Order({
			tokenIn: address(0),
			amountIn: msg.value,
			tokenOut: tokenOut,
			amountOut: amountOut,
			destAddr: destAddr,
			status: Status.CREATED
		});

		emit OrderCreatedWithEth(key);
	}

	function createOrderWithToken(bytes32 key, bytes32 tokenOut, uint64 amountOut, bytes32 destAddr, address tokenIn, uint256 amountIn) public {
		require(paused == false, 'contract is paused');

		uint256 balance = IERC20(tokenIn).balanceOf(address(this));
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		amountIn = IERC20(tokenIn).balanceOf(address(this)) - balance;

		require(amountIn > 0, 'zero amount in');
		require(orders[key].amountIn == 0, 'duplicate key');

		orders[key] = Order({
			tokenIn: tokenIn,
			amountIn: amountIn,
			tokenOut: tokenOut,
			amountOut: amountOut,
			destAddr: destAddr,
			status: Status.CREATED
		});

		emit OrderCreatedWithToken(key);
	}

	function completeOrder(bytes memory encodedVm) public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);
		require(vm.emitterChainId == emitterChainId, 'invalid emitter chain');
		require(vm.emitterAddress == emitterAddr, 'invalid emitter address');

		Swift memory swift = parseSwiftPayload(vm.payload);
		Order memory order = orders[swift.key];

		require(order.status == Status.CREATED, 'order status not created');
		require(swift.amountOut == order.amountOut, 'invalid amount out');
		require(swift.sourceChain == wormhole.chainId(), 'invalid source chain');
		require(swift.tokenOut == order.tokenOut, 'invalid token out');
		require(swift.destAddr == order.destAddr, 'invalid destination address');
		require(swift.action == 1, 'wrong action');
		
		orders[swift.key].status = Status.COMPLETED;
		
		address recipient = truncateAddress(swift.recipient);
		if (order.tokenIn == address(0)) {
			payable(recipient).transfer(order.amountIn);
		} else {
			IERC20(order.tokenIn).safeTransfer(recipient, order.amountIn);
		}
		
		emit OrderCompleted(swift.key);
	}

	function cancelOrder(bytes memory encodedVm) public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);
		require(vm.emitterChainId == emitterChainId, 'invalid emitter chain');
		require(vm.emitterAddress == emitterAddr, 'invalid emitter address');

		Swift memory swift = parseSwiftPayload(vm.payload);
		Order memory order = orders[swift.key];

		require(order.status == Status.CREATED, 'order status is not created');
		require(swift.amountOut == order.amountOut, 'invalid amount out');
		require(swift.sourceChain == wormhole.chainId(), 'invalid source chain');
		require(swift.tokenOut == order.tokenOut, 'invalid token out');
		require(swift.destAddr == order.destAddr, 'invalid destination address');
		require(swift.action == 2, 'wrong action');
		
		orders[swift.key].status = Status.CANCELED;
		
		address recipient = truncateAddress(swift.recipient);
		if (order.tokenIn == address(0)) {
			payable(recipient).transfer(order.amountIn);
		} else {
			IERC20(order.tokenIn).safeTransfer(recipient, order.amountIn);
		}

		emit OrderCanceled(swift.key);
	}

	function parseSwiftPayload(bytes memory encoded) public pure returns (Swift memory swift) {
        uint index = 0;

		swift.action = encoded.toUint8(index);
		index += 1;

		require(swift.action == 1 || swift.action == 2, 'invalid action');

        swift.key = encoded.toBytes32(index);
        index += 32;

        swift.sourceChain = encoded.toUint16(index);
        index += 2;

        swift.tokenOut = encoded.toBytes32(index);
        index += 32;

		swift.amountOut = encoded.toUint64(index);
		index += 8;

        swift.destAddr = encoded.toBytes32(index);
        index += 32;

		swift.recipient = encoded.toBytes32(index);
		index += 32;

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

	function getEmitterChainId() public view returns (uint16) {
		return emitterChainId;
	}

	function getEmitterAddr() public view returns (bytes32) {
		return emitterAddr;
	}
}