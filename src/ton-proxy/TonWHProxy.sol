// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IWormhole.sol";
import "../interfaces/IFeeManager.sol";
import "../libs/BytesLib.sol";
import "../libs/SignatureVerifier.sol";
import "../swift/SwiftStructs.sol";
import "../swift/SwiftErrors.sol";

contract TonWHProxy is ReentrancyGuard {
	event OrderCreated(bytes32 key);
	event OrderFulfilled(bytes32 key, uint64 sequence, uint256 fulfilledAmount);
	event OrderUnlocked(bytes32 key);
	event OrderCanceled(bytes32 key, uint64 sequence);
	event OrderRefunded(bytes32 key, uint256 refundedAmount);

	using BytesLib for bytes;
	using SignatureVerifier for bytes;

	IWormhole public immutable wormhole;
	uint16 public auctionChainId;
	bytes32 public auctionAddr;
	IFeeManager public feeManager;
	uint8 public consistencyLevel;
	address public guardian;
	address public nextGuardian;
	bool public paused;

	mapping(bytes32 => bytes) public unlockMsgs;

	modifier onlyGuardian() {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		_;
	}

	constructor(
		address _wormhole,
		address _feeManager,
		uint16 _auctionChainId,
		bytes32 _auctionAddr,
		uint8 _consistencyLevel
	) {
		guardian = msg.sender;
		wormhole = IWormhole(_wormhole);
		feeManager = IFeeManager(_feeManager);
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
		bool batch
	) onlyGuardian nonReentrant public payable returns (uint64 sequence) {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
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

		// in ton chain we should validate this. here as a proxy we just trust the payload
		// address tokenOut = truncateAddress(params.tokenOut);
		// if (tokenOut != address(0)) {
		// 	fulfillAmount = pullTokenIn(tokenOut, fulfillAmount, permit);
		// }

		// if (truncateAddress(fulfillMsg.driver) != tx.origin && block.timestamp <= params.deadline - params.penaltyPeriod) {
		// 	revert Unauthorized();
		// }

		if (block.timestamp > params.deadline) {
			revert DeadlineViolation();
		}

		bytes memory encodedUnlockMsg = encodeUnlockMsg(buildUnlockMsg(fulfillMsg.orderHash, params, extraParams, recipient));

		if (batch) {
			unlockMsgs[fulfillMsg.orderHash] = encodedUnlockMsg;
		} else {
			sequence = wormhole.publishMessage{
				value : wormhole.messageFee()
			}(0, abi.encodePacked(Action.UNLOCK, encodedUnlockMsg), consistencyLevel);
		}

		emit OrderFulfilled(fulfillMsg.orderHash, sequence, fulfillAmount);
	}

	function fulfillSimple(
		uint256 fulfillAmount,
		bytes32 orderHash,
		OrderParams memory params,
		ExtraParams memory extraParams,
		bytes32 recipient,
		bool batch
	) onlyGuardian nonReentrant public payable returns (uint64 sequence) {
		if (params.auctionMode != uint8(AuctionMode.BYPASS)) {
			revert InvalidAuctionMode();
		}

		params.destChainId = wormhole.chainId();
		if (keccak256(encodeKey(buildKey(params, extraParams))) != orderHash) {
			revert InvalidOrderHash();
		}

		if (block.timestamp > params.deadline) {
			revert DeadlineViolation();
		}

		bytes memory uncodedUnlockMsg = encodeUnlockMsg(buildUnlockMsg(orderHash, params, extraParams, recipient));

		if (batch) {
			unlockMsgs[orderHash] = uncodedUnlockMsg;
		} else {
			sequence = wormhole.publishMessage{
				value : wormhole.messageFee()
			}(0, abi.encodePacked(Action.UNLOCK, uncodedUnlockMsg), consistencyLevel);
		}

		emit OrderFulfilled(orderHash, sequence, fulfillAmount);
	}

	function cancelOrder(
		bytes32 orderHash,
		OrderParams memory params,
		ExtraParams memory extraParams,
		bytes32 canceler
	) onlyGuardian nonReentrant public payable returns (uint64 sequence) {
		params.destChainId = wormhole.chainId();
		bytes32 computedOrderHash = keccak256(encodeKey(buildKey(params, extraParams)));

		if (computedOrderHash != orderHash) {
			revert InvalidOrderHash();
		}

		if (block.timestamp <= params.deadline) {
			revert DeadlineViolation();
		}

		RefundMsg memory refundMsg = RefundMsg({
			action: uint8(Action.REFUND),
			orderHash: orderHash,
			srcChainId: extraParams.srcChainId,
			tokenIn: extraParams.tokenIn,
			recipient: params.trader,
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

	function postBatch(bytes32[] memory orderHashes, bool compressed) onlyGuardian public payable returns (uint64 sequence) {
		bytes memory encoded;
		for(uint i=0; i<orderHashes.length; i++) {
			bytes memory unlockMsg = unlockMsgs[orderHashes[i]];
			if (unlockMsg.length == UNLOCK_MSG_SIZE) {
				revert OrderNotExists(orderHashes[i]);
			}
			encoded = abi.encodePacked(encoded);
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
			recipient: recipient,
			driver: bytes32(uint256(uint160(tx.origin))),
			fulfillTime: uint64(block.timestamp)
		});
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

		fulfillMsg.driver = encoded.toBytes32(index);
		index += 32;

		fulfillMsg.promisedAmount = encoded.toUint64(index);
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
			//unlockMsg.action,
			unlockMsg.orderHash,
			unlockMsg.srcChainId,
			unlockMsg.tokenIn,
			unlockMsg.referrerAddr,
			unlockMsg.referrerBps,
			unlockMsg.protocolBps,
			unlockMsg.recipient,
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
			refundMsg.recipient,
			refundMsg.canceler,
			refundMsg.cancelFee,
			refundMsg.refundFee
		);
	}

	function truncateAddress(bytes32 b) internal pure returns (address) {
		if (bytes12(b) != 0) {
			revert InvalidEvmAddr();
		}
		return address(uint160(uint256(b)));
	}

	function setPause(bool _pause) onlyGuardian public {
		paused = _pause;
	}

	function setAuctionConfig(uint16 _auctionChainId, bytes32 _auctionAddr) onlyGuardian public {
		if (_auctionChainId == 0 || _auctionAddr == bytes32(0)) {
			revert InvalidAuctionConfig();
		}
		auctionChainId = _auctionChainId;
		auctionAddr = _auctionAddr;
	}	

	function setFeeManager(address _feeManager) onlyGuardian public {
		feeManager = IFeeManager(_feeManager);
	}

	function setConsistencyLevel(uint8 _consistencyLevel) onlyGuardian public {
		consistencyLevel = _consistencyLevel;
	}

	function changeGuardian(address newGuardian) onlyGuardian public {
		nextGuardian = newGuardian;
	}

	function claimGuardian() public {
		if (msg.sender != nextGuardian) {
			revert Unauthorized();
		}
		guardian = nextGuardian;
	}
}