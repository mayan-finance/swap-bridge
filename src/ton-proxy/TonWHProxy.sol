// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IWormhole.sol";
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
        uint16 _auctionChainId,
        bytes32 _auctionAddr,
        uint8 _consistencyLevel
    ) {
        guardian = msg.sender;
        wormhole = IWormhole(_wormhole);
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
    ) public payable onlyGuardian nonReentrant returns (uint64 sequence) {
        (IWormhole.VM memory vm, bool valid, string memory reason) = wormhole
            .parseAndVerifyVM(encodedVm);
        require(valid, reason);

        if (vm.emitterChainId != auctionChainId) {
            revert InvalidEmitterChain();
        }
        if (vm.emitterAddress != auctionAddr) {
            revert InvalidEmitterAddress();
        }

        FulfillMsg memory fulfillMsg = parseFulfillPayload(vm.payload);

        params.destChainId = wormhole.chainId();

        bytes memory encodedUnlockMsg = encodeUnlockMsg(
            buildUnlockMsg(fulfillMsg.orderHash, params, extraParams, recipient)
        );

        if (batch) {
            unlockMsgs[fulfillMsg.orderHash] = encodedUnlockMsg;
        } else {
            sequence = wormhole.publishMessage{value: wormhole.messageFee()}(
                0,
                abi.encodePacked(Action.UNLOCK, encodedUnlockMsg),
                consistencyLevel
            );
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
    ) public payable onlyGuardian nonReentrant returns (uint64 sequence) {
        bytes memory uncodedUnlockMsg = encodeUnlockMsg(
            buildUnlockMsg(orderHash, params, extraParams, recipient)
        );

        if (batch) {
            unlockMsgs[orderHash] = uncodedUnlockMsg;
        } else {
            sequence = wormhole.publishMessage{value: wormhole.messageFee()}(
                0,
                abi.encodePacked(Action.UNLOCK, uncodedUnlockMsg),
                consistencyLevel
            );
        }

        emit OrderFulfilled(orderHash, sequence, fulfillAmount);
    }

    function cancelOrder(
        bytes32 orderHash,
        OrderParams memory params,
        ExtraParams memory extraParams,
        bytes32 canceler
    ) public payable onlyGuardian nonReentrant returns (uint64 sequence) {
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

        sequence = wormhole.publishMessage{value: msg.value}(
            0,
            encoded,
            consistencyLevel
        );

        emit OrderCanceled(orderHash, sequence);
    }

    function postBatch(
        bytes32[] memory orderHashes,
        bool compressed
    ) public payable onlyGuardian returns (uint64 sequence) {
        bytes memory encoded;
        for (uint i = 0; i < orderHashes.length; i++) {
            bytes memory unlockMsg = unlockMsgs[orderHashes[i]];
            if (unlockMsg.length == UNLOCK_MSG_SIZE) {
                revert OrderNotExists(orderHashes[i]);
            }
            encoded = abi.encodePacked(encoded);
            delete unlockMsgs[orderHashes[i]];
        }

        bytes memory payload;
        if (compressed) {
            payload = abi.encodePacked(
                uint8(Action.COMPRESSED_UNLOCK),
                uint16(orderHashes.length),
                keccak256(encoded)
            );
        } else {
            payload = abi.encodePacked(
                uint8(Action.BATCH_UNLOCK),
                uint16(orderHashes.length),
                encoded
            );
        }

        sequence = wormhole.publishMessage{value: msg.value}(
            0,
            payload,
            consistencyLevel
        );
    }

    function buildUnlockMsg(
        bytes32 orderHash,
        OrderParams memory params,
        ExtraParams memory extraParams,
        bytes32 recipient
    ) internal view returns (UnlockMsg memory) {
        return
            UnlockMsg({
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

    function parseFulfillPayload(
        bytes memory encoded
    ) public pure returns (FulfillMsg memory fulfillMsg) {
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

    function encodeUnlockMsg(
        UnlockMsg memory unlockMsg
    ) internal pure returns (bytes memory encoded) {
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

    function encodeRefundMsg(
        RefundMsg memory refundMsg
    ) internal pure returns (bytes memory encoded) {
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

    function setPause(bool _pause) public onlyGuardian {
        paused = _pause;
    }

    function setAuctionConfig(
        uint16 _auctionChainId,
        bytes32 _auctionAddr
    ) public onlyGuardian {
        if (_auctionChainId == 0 || _auctionAddr == bytes32(0)) {
            revert InvalidAuctionConfig();
        }
        auctionChainId = _auctionChainId;
        auctionAddr = _auctionAddr;
    }

    function setConsistencyLevel(uint8 _consistencyLevel) public onlyGuardian {
        consistencyLevel = _consistencyLevel;
    }

    function changeGuardian(address newGuardian) public onlyGuardian {
        nextGuardian = newGuardian;
    }

    function claimGuardian() public {
        if (msg.sender != nextGuardian) {
            revert Unauthorized();
        }
        guardian = nextGuardian;
    }
}
