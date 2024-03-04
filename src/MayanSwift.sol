// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IWormhole.sol";
import "./interfaces/IWETH.sol";
import "./libs/BytesLib.sol";
import "./libs/SignatureVerification.sol";

contract MayanSwift is ReentrancyGuard {
	event OrderCreated(bytes32 key);
	event OrderFulfilled(bytes32 key);
	event OrderUnlocked(bytes32 key);
	event OrderCanceled(bytes32 key);
	event OrderRefunded(bytes32 key);

	using SafeERC20 for IERC20;
	using BytesLib for bytes;
	using SignatureVerification for bytes;

	IWormhole wormhole;
	uint8 public defaultProtocolBps;
	address public feeCollector;
	uint16 public auctionChainId;
	bytes32 public auctionAddr;
	bytes32 public solanaEmitter;
	uint8 public consistencyLevel;
	address public guardian;
	address public nextGuardian;
	bool public paused;

	bytes4 private constant _RECEIVE_WITH_AUTHORIZATION_SELECTOR = 0xef55bec6;

	mapping(bytes32 => Order) private orders;

	struct Order {
		bytes32 destEmitter;
		uint16 destChainId;
		Status status;
	}

	struct OrderParams {
		bytes32 tokenOut;
		uint64 minAmountOut;
		uint64 gasDrop;
		bytes32 destAddr;
		uint16 destChainId;
		bytes32 referrerAddr;
		uint8 referrerBps;
		uint8 auctionMode;
		bytes32 random;
		bytes32 destEmitter;
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

	struct UnlockMsg {
		uint8 action;
		bytes32 orderHash;
		uint16 srcChainId;
		bytes32 tokenIn;
		uint64 amountIn;
		bytes32 recipient;
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

	struct EIP712Domain {
		string name;
		string version;
		uint256 chainId;
		address verifyingContract;
		bytes32 salt;
	}

	constructor(
		address _wormhole,
		address _feeCollector,
		uint16 _auctionChainId,
		bytes32 _auctionAddr,
		bytes32 _solanaEmitter,
		uint8 _consistencyLevel
	) {
		guardian = msg.sender;
		wormhole = IWormhole(_wormhole);
		feeCollector = _feeCollector;
		auctionChainId = _auctionChainId;
		auctionAddr = _auctionAddr;
		solanaEmitter = _solanaEmitter;
		consistencyLevel = _consistencyLevel;
	}

	function createOrderWithEth(OrderParams memory params) nonReentrant public payable returns (bytes32 orderHash) {
		require(paused == false, 'contract is paused');

		uint64 normlizedAmountIn = uint64(normalizeAmount(msg.value, 18));
		require(normlizedAmountIn > 0, 'small amount in');

		if (params.tokenOut == bytes32(0)) {
			require(params.gasDrop == 0, 'gas drop not supported');
		}

		Key memory key = Key({
			trader: bytes32(uint256(uint160(msg.sender))),
			srcChainId: wormhole.chainId(),
			tokenIn: bytes32(0),
			amountIn: normlizedAmountIn,
			tokenOut: params.tokenOut,
			minAmountOut: params.minAmountOut,
			gasDrop: params.gasDrop,
			destAddr: params.destAddr,
			destChainId: params.destChainId,
			referrerAddr: params.referrerAddr,
			referrerBps: params.referrerBps,
			protocolBps: defaultProtocolBps,
			auctionMode: params.auctionMode,
			random: params.random
		});
		orderHash = keccak256(encodeKey(key));

		require(params.destChainId != wormhole.chainId(), 'same src and dest chains');
		require(params.destChainId > 0, 'invalid dest chain id');
		require(orders[orderHash].destChainId == 0, 'duplicate order hash');

		orders[orderHash].destChainId = params.destChainId;
		orders[orderHash].status = Status.CREATED;
		if (params.destEmitter != bytes32(0)) {
			orders[orderHash].destEmitter = params.destEmitter;
		}

		emit OrderCreated(orderHash);
	}

	function createOrderWithToken(address tokenIn, uint256 amountIn, OrderParams memory params) nonReentrant public returns (bytes32 orderHash) {
		require(paused == false, 'contract is paused');

		uint256 balance = IERC20(tokenIn).balanceOf(address(this));
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		amountIn = IERC20(tokenIn).balanceOf(address(this)) - balance;

		uint64 normlizedAmountIn = uint64(normalizeAmount(amountIn, decimalsOf(tokenIn)));
		require(normlizedAmountIn > 0, 'small amount in');
		if (params.tokenOut == bytes32(0)) {
			require(params.gasDrop == 0, 'gas drop not supported');
		}

		Key memory key = Key({
			trader: bytes32(uint256(uint160(msg.sender))),
			srcChainId: wormhole.chainId(),
			tokenIn: bytes32(uint256(uint160(tokenIn))),
			amountIn: normlizedAmountIn,
			tokenOut: params.tokenOut,
			minAmountOut: params.minAmountOut,
			gasDrop: params.gasDrop,
			destAddr: params.destAddr,
			destChainId: params.destChainId,
			referrerAddr: params.referrerAddr,
			referrerBps: params.referrerBps,
			protocolBps: defaultProtocolBps,
			auctionMode: params.auctionMode,
			random: params.random
		});
		orderHash = keccak256(encodeKey(key));

		require(params.destChainId != wormhole.chainId(), 'same src and dest chain');
		require(params.destChainId > 0, 'invalid dest chain id');
		require(orders[orderHash].destChainId == 0, 'duplicate key');

		orders[orderHash] = Order({
			destEmitter: params.destEmitter,
			destChainId: params.destChainId,
			status: Status.CREATED
		});

		if (params.destEmitter != bytes32(0)) {
			orders[orderHash].destEmitter = params.destEmitter;
		}

		emit OrderCreated(orderHash);
	}

	function createOrderWithSig(
		address tokenIn,
		uint256 amountIn,
		OrderParams memory params,
		bytes calldata signedOrderHash,
		bytes calldata receiveAuthorization
	) nonReentrant public returns (bytes32 orderHash) {
		require(paused == false, 'contract is paused');

		(address owner, address to, uint256 amount) = abi.decode(
			receiveAuthorization[0:96],
			(address, address, uint256)
		);
		require(to == address(this), 'recipient is not this contract');
		require(amount == amountIn, 'invalid amount in');

		amountIn = IERC20(tokenIn).balanceOf(address(this));

		(bool success, ) = tokenIn.call(
			abi.encodePacked(
				_RECEIVE_WITH_AUTHORIZATION_SELECTOR,
				receiveAuthorization
			)
		);
		require(success, 'failed to transfer tokens');

		amountIn = IERC20(tokenIn).balanceOf(address(this)) - amountIn;
		require(amountIn == amount, 'invalid amount transferred');

		uint64 normlizedAmountIn = uint64(normalizeAmount(amountIn, decimalsOf(tokenIn)));
		require(normlizedAmountIn > 0, 'small amount in');
		if (params.tokenOut == bytes32(0)) {
			require(params.gasDrop == 0, 'gas drop not supported');
		}

		Key memory key = Key({
			trader: bytes32(uint256(uint160(owner))),
			srcChainId: wormhole.chainId(),
			tokenIn: bytes32(uint256(uint160(tokenIn))),
			amountIn: normlizedAmountIn,
			tokenOut: params.tokenOut,
			minAmountOut: params.minAmountOut,
			gasDrop: params.gasDrop,
			destAddr: params.destAddr,
			destChainId: params.destChainId,
			referrerAddr: params.referrerAddr,
			referrerBps: params.referrerBps,
			protocolBps: defaultProtocolBps,
			auctionMode: params.auctionMode,
			random: params.random
		});
		orderHash = keccak256(encodeKey(key));

		signedOrderHash.verify(orderHash, owner);

		require(params.destChainId != wormhole.chainId(), 'same src and dest chain');
		require(params.destChainId > 0, 'invalid dest chain id');
		require(orders[orderHash].destChainId == 0, 'duplicate key');

		orders[orderHash] = Order({
			destEmitter: params.destEmitter,
			destChainId: params.destChainId,
			status: Status.CREATED
		});

		if (params.destEmitter != bytes32(0)) {
			orders[orderHash].destEmitter = params.destEmitter;
		}

		emit OrderCreated(orderHash);		
	}

	function fulfillOrder(bytes memory encodedVm, bytes32 recepient) nonReentrant public payable returns (uint64 sequence) {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);
		require(vm.emitterChainId == auctionChainId, 'invalid auction chain');
		require(vm.emitterAddress == auctionAddr, 'invalid auction address');

		FulfillMsg memory fulfillMsg = parseFulfillPayload(vm.payload);

		require(fulfillMsg.destChainId == wormhole.chainId(), 'wrong chain id');
		require(truncateAddress(fulfillMsg.driver) == msg.sender, 'invalid driver');

		require(orders[fulfillMsg.orderHash].status == Status.CREATED, 'invalid order status');
		orders[fulfillMsg.orderHash].status = Status.FULFILLED;

		makePayments(
			fulfillMsg.destAddr,
			fulfillMsg.tokenOut,
			fulfillMsg.amountPromised,
			fulfillMsg.gasDrop,
			fulfillMsg.referrerAddr,
			fulfillMsg.referrerBps,
			fulfillMsg.protocolBps
		);

		UnlockMsg memory unlockMsg = UnlockMsg({
			action: 2,
			orderHash: fulfillMsg.orderHash,
			srcChainId: fulfillMsg.srcChainId,
			tokenIn: fulfillMsg.tokenIn,
			amountIn: fulfillMsg.amountIn,
			recipient: recepient
		});

		bytes memory encoded = encodeUnlockMsg(unlockMsg);

		sequence = wormhole.publishMessage{
			value : wormhole.messageFee()
		}(0, encoded, consistencyLevel);

		emit OrderFulfilled(fulfillMsg.orderHash);
	}

	function fulfillSimple(bytes32 orderHash,
		bytes32 trader,
		uint16 srcChainId,
		bytes32 tokenIn,
		uint64 amountIn,
		uint8 protocolBps,
		OrderParams memory params
	) public nonReentrant payable returns (uint64 sequence) {
		Key memory key = Key({
			trader: trader,
			srcChainId: srcChainId,
			tokenIn: tokenIn,
			amountIn: amountIn,
			tokenOut: params.tokenOut,
			minAmountOut: params.minAmountOut,
			gasDrop: params.gasDrop,
			destAddr: params.destAddr,
			destChainId: wormhole.chainId(),
			referrerAddr: params.referrerAddr,
			referrerBps: params.referrerBps,
			protocolBps: protocolBps,
			auctionMode: params.auctionMode,
			random: params.random
		});
		bytes32 computedOrderHash = keccak256(encodeKey(key));

		require(computedOrderHash == orderHash, 'invalid order hash');

		require(orders[computedOrderHash].status == Status.CREATED, 'invalid order status');
		orders[computedOrderHash].status = Status.FULFILLED;

		makePayments(
			params.destAddr,
			params.tokenOut,
			params.minAmountOut,
			params.gasDrop,
			params.referrerAddr,
			params.referrerBps,
			protocolBps
		);

		UnlockMsg memory unlockMsg = UnlockMsg({
			action: 2,
			orderHash: computedOrderHash,
			srcChainId: key.srcChainId,
			tokenIn: key.tokenIn,
			amountIn: key.amountIn,
			recipient: key.trader
		});

		bytes memory encoded = encodeUnlockMsg(unlockMsg);

		sequence = wormhole.publishMessage{
			value : wormhole.messageFee()
		}(0, encoded, consistencyLevel);

		emit OrderFulfilled(computedOrderHash);
	}

	function unlockOrder(bytes memory encodedVm) nonReentrant public {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);

		require(valid, reason);

		UnlockMsg memory swift = parseUnlockPayload(vm.payload);
		Order memory order = getOrder(swift.orderHash);

		require(vm.emitterChainId == order.destChainId, 'invalid emitter chain');
		require(vm.emitterAddress == order.destEmitter, 'invalid emitter address');

		require(swift.srcChainId == wormhole.chainId(), 'invalid source chain');
		require(order.destChainId > 0, 'order not exists');
		require(order.status == Status.CREATED, 'order is not created');

		if (swift.action == 2) {
			orders[swift.orderHash].status = Status.UNLOCKED;
		} else if (swift.action == 3) {
			orders[swift.orderHash].status = Status.REFUNDED;
		} else {
			revert('invalid action');
		}
		
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
		
		if (swift.action == 2) {
			emit OrderUnlocked(swift.orderHash);
		} else if (swift.action == 3) {
			emit OrderRefunded(swift.orderHash);
		}
	}

	function cancelOrder(
		bytes32 trader,
		uint16 srcChainId,
		bytes32 tokenIn,
		uint64 amountIn,
		bytes32 tokenOut,
		uint64 minAmountOut,
		uint64 gasDrop,
		bytes32 referrerAddr,
		uint8 referrerBps,
		uint8 protocolBps,
		uint8 auctionMode,
		bytes32 random
	) public nonReentrant payable returns (uint64 sequence) {
		Key memory key = Key({
			trader: trader,
			srcChainId: srcChainId,
			tokenIn: tokenIn,
			amountIn: amountIn,
			tokenOut: tokenOut,
			minAmountOut: minAmountOut,
			gasDrop: gasDrop,
			destAddr: bytes32(uint256(uint160(msg.sender))),
			destChainId: wormhole.chainId(),
			referrerAddr: referrerAddr,
			referrerBps: referrerBps,
			protocolBps: protocolBps,
			auctionMode: auctionMode,
			random: random
		});
		bytes32 orderHash = keccak256(encodeKey(key));
		Order memory order = orders[orderHash];

		require(order.status == Status.CREATED, 'invalid order status');
		orders[orderHash].status = Status.CANCELED;

		UnlockMsg memory cancelMsg = UnlockMsg({
			action: 3,
			orderHash: orderHash,
			srcChainId: key.srcChainId,
			tokenIn: key.tokenIn,
			amountIn: key.amountIn,
			recipient: key.trader
		});

		bytes memory encoded = encodeUnlockMsg(cancelMsg);

		sequence = wormhole.publishMessage{
			value : msg.value
		}(0, encoded, consistencyLevel);

		emit OrderCanceled(orderHash);
	}

	function makePayments(bytes32 _destAddr, bytes32 _tokenOut, uint64 _amountPromised, uint64 _gasDrop, bytes32 _referrerAddr, uint64 _referrerBps, uint64 _protocolBps) internal {
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
		if (tokenOut == address(0)) {
			require(msg.value == amountPromised + wormholeFee, 'invalid amount value');
			if (amountReferrer > 0) {
				payable(referrerAddr).transfer(amountReferrer);
			}
			if (amountProtocol > 0) {
				payable(feeCollector).transfer(amountProtocol);
			}
			payable(destAddr).transfer(amountPromised - amountReferrer - amountProtocol);
		} else {
			if (_gasDrop > 0) {
				uint256 gasDrop = deNormalizeAmount(_gasDrop, 18);
				require(msg.value == gasDrop + wormholeFee, 'invalid gas drop value');
				payable(destAddr).transfer(gasDrop);
			} else {
				require(msg.value == wormholeFee, 'invalid bridge fee value');
			}
			
			if (amountReferrer > 0) {
				IERC20(tokenOut).safeTransferFrom(msg.sender, referrerAddr, amountReferrer);
			}
			if (amountProtocol > 0) {
				IERC20(tokenOut).safeTransferFrom(msg.sender, feeCollector, amountProtocol);
			}
			IERC20(tokenOut).safeTransferFrom(msg.sender, destAddr, amountPromised - amountReferrer - amountProtocol);
		}
	}

	function parseFulfillPayload(bytes memory encoded) public pure returns (FulfillMsg memory fulfillMsg) {
		uint index = 0;

		fulfillMsg.action = encoded.toUint8(index);
		index += 1;

		require(fulfillMsg.action == 1, 'invalid action');

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

		require(encoded.length == index, 'invalid msg lenght');
	}

	function parseUnlockPayload(bytes memory encoded) public pure returns (UnlockMsg memory unlockMsg) {
		uint index = 0;

		unlockMsg.action = encoded.toUint8(index);
		index += 1;

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

		require(encoded.length == index, 'invalid msg lenght');
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
			key.referrerAddr,
			key.referrerBps,
			key.protocolBps,
			key.auctionMode,
			key.random
		);
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

	function setFeeCollector(address _feeCollector) public {
		require(msg.sender == guardian, 'only guardian');
		feeCollector = _feeCollector;
	}

	function setDefaultMayanBps(uint8 _defaultProtocolBps) public {
		require(msg.sender == guardian, 'only guardian');
		defaultProtocolBps = _defaultProtocolBps;
	}

	function setConsistencyLevel(uint8 _consistencyLevel) public {
		require(msg.sender == guardian, 'only guardian');
		consistencyLevel = _consistencyLevel;
	}

	function changeGuardian(address newGuardian) public {
		require(msg.sender == guardian, 'only guardian');
		nextGuardian = newGuardian;
	}

	function claimGuardian() public {
		require(msg.sender == nextGuardian, 'only next guardian');
		guardian = nextGuardian;
	}

	function getOrder(bytes32 orderHash) public view returns (Order memory order) {
		order = orders[orderHash];
		if (order.destEmitter == bytes32(0)) {
			if (order.destChainId == 1) {
				order.destEmitter = solanaEmitter;
			} else {
				order.destEmitter = bytes32(uint256(uint160(address(this))));
			}
		}
	}

	receive() external payable {}
}