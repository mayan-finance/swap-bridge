// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IWormhole.sol";
import "./interfaces/IWETH.sol";
import "./libs/BytesLib.sol";

contract MayanSwift {
	event OrderCreated(bytes32 key);
	event OrderCompleted(bytes32 key);
	event OrderCanceled(bytes32 key);
	event CancelRequested(bytes32 key);
	event LocalCanceled(bytes32 key);

	using SafeERC20 for IERC20;
	using BytesLib for bytes;

	IWormhole wormhole;
	IWETH WETH;
	address guardian;
	address nextGuardian;
	bool paused;

	struct Order {
		address sourceAddr;
		address tokenIn;
		uint256 amountIn;
		bytes32 tokenOut;
		uint64 amountOut;
		uint16 destChain;
		bytes32 destAddr;
		Status status;
	}

	enum Status {
		CREATED,
		CANCELED,
		COMPLETED,
		LOCAL_CANCELED
	}

	struct Swift {
		uint8 action;
		bytes32 key;
		uint16 sourceChain;
		bytes32 tokenOut;
		uint64 amountOut;
		bytes32 destAddr;
		bytes32 recepient;
	}


	constructor(address _wormhole, address _weth) {
		guardian = msg.sender;
		wormhole = IWormhole(_wormhole);
		WETH = IWETH(_weth);
	}

	mapping(uint16 => bytes32) contracts;
	mapping(bytes32 => Order) orders;
	mapping(bytes32 => uint256) cancelRequests;
	uint64 orderIndex = 0;

	function createEthOrder(bytes32 key, bytes32 tokenOut, uint64 amountOut, uint16 destChain, bytes32 destAddr) public payable {
		require(paused == false, 'contract is paused');
		require(msg.value > 0, 'value is zero');
		require(orders[key].amountIn == 0, 'duplicate key');

        WETH.deposit{
            value : msg.value
        }();

		orders[key] = Order({
			sourceAddr: msg.sender,
			tokenIn: address(WETH),
			amountIn: msg.value,
			tokenOut: tokenOut,
			amountOut: amountOut,
			destChain: destChain,
			destAddr: destAddr,
			status: Status.CREATED
		});

		emit OrderCreated(key);
	}

	function createErcOrder(bytes32 key, bytes32 tokenOut, uint64 amountOut, uint16 destChain, bytes32 destAddr, address tokenIn, uint256 amountIn) public {
		require(paused == false, 'contract is paused');

		uint256 balance = IERC20(tokenIn).balanceOf(address(this));
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		amountIn = IERC20(tokenIn).balanceOf(address(this)) - balance;

		require(amountIn > 0, 'zero amount in');
		require(orders[key].amountIn == 0, 'duplicate key');

		orders[key] = Order({
			sourceAddr: msg.sender,
			tokenIn: address(WETH),
			amountIn: amountIn,
			tokenOut: tokenOut,
			amountOut: amountOut,
			destChain: destChain,
			destAddr: destAddr,
			status: Status.CREATED
		});

		emit OrderCreated(key);
	}

	function completeOrder(bytes memory encodedVm) public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);
		require(vm.emitterAddress == contracts[vm.emitterChainId], 'invalid emitter address');

		Swift memory swift = parseSwiftPayload(vm.payload);
		Order memory order = orders[swift.key];

		require(order.status == Status.CREATED, 'order status is not created');
		require(swift.amountOut == order.amountOut, 'invalid amount out');
		require(swift.sourceChain == block.chainid, 'invalid source chain');	// TODO: check
		require(swift.tokenOut == order.tokenOut, 'invalid token out');
		require(swift.destAddr == order.destAddr, 'invalid destination address');
		require(swift.action == 1, 'wrong action');
		
		order.status = Status.COMPLETED;
		
		address recepient = truncateAddress(swift.recepient);
		if (order.tokenIn == address(WETH)) {
			WETH.withdraw(order.amountIn);
			payable(recepient).transfer(order.amountIn);
		} else {
			IERC20(order.tokenIn).safeTransfer(recepient, order.amountIn);
		}
		
		emit OrderCompleted(swift.key);
	}

	function cancelOrder(bytes memory encodedVm) public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);
		require(vm.emitterAddress == contracts[vm.emitterChainId], 'invalid emitter address');

		Swift memory swift = parseSwiftPayload(vm.payload);
		Order memory order = orders[swift.key];

		require(order.status == Status.CREATED, 'order status is not created');
		require(swift.amountOut == order.amountOut, 'invalid amount out');
		require(swift.sourceChain == block.chainid, 'invalid source chain');	// TODO: check
		require(swift.tokenOut == order.tokenOut, 'invalid token out');
		require(swift.destAddr == order.destAddr, 'invalid destination address');
		require(swift.action == 2, 'wrong action');
		
		order.status = Status.CANCELED;
		
		if (order.tokenIn == address(WETH)) {
			WETH.withdraw(order.amountIn);
			payable(order.sourceAddr).transfer(order.amountIn);
		} else {
			IERC20(order.tokenIn).safeTransfer(order.sourceAddr, order.amountIn);
		}

		emit OrderCanceled(swift.key);
	}

	function requestCancel(bytes32 key) public {
		Order memory order = orders[key];
		require(msg.sender == order.sourceAddr, 'invalid sender');
		require(order.status == Status.CREATED, 'order status is not created');
		require(cancelRequests[key] == 0, 'cancel request exists');

		cancelRequests[key] = block.timestamp;

		emit CancelRequested(key);
	}

	function doCancel(bytes32 key) public {
		Order memory order = orders[key];
		require(order.status == Status.CREATED, 'order status is not created');
		require(cancelRequests[key] > 0, 'cancel request not exists');
		require(block.timestamp - cancelRequests[key] > 604800, 'too early to cancel');

		order.status = Status.LOCAL_CANCELED;

		if (order.tokenIn == address(WETH)) {
			WETH.withdraw(order.amountIn);
			payable(order.sourceAddr).transfer(order.amountIn);
		} else {
			IERC20(order.tokenIn).safeTransfer(order.sourceAddr, order.amountIn);
		}

		emit LocalCanceled(key);
	}

	function getOrder(bytes32 key) public view returns (Order memory) {
		return orders[key];
	}

	function parseSwiftPayload(bytes memory encoded) public pure returns (Swift memory swift) {
        uint index = 0;

		swift.action = encoded.toUint8(index);

		require(swift.action == 1 || swift.action == 2, 'invalid action');

        swift.key = encoded.toBytes32(index);
        index += 32;

        swift.sourceChain = encoded.toUint16(index);
        index += 2;

        swift.tokenOut = encoded.toBytes32(index);
        index += 32;

		swift.amountOut = encoded.toUint64(index);
		index + 8;

        swift.destAddr = encoded.toBytes32(index);
        index += 32;

		swift.recepient = encoded.toBytes32(index);
		index += 32;

		swift.action = encoded.toUint8(index);
		index += 1;

        require(encoded.length == index, 'invalid swift msg');
	}

	function truncateAddress(bytes32 b) internal pure returns (address) {
		require(bytes12(b) == 0, 'invalid EVM address');
		return address(uint160(uint256(b)));
	}
}