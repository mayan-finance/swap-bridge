
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libs/BytesLib.sol";
import "./interfaces/CCTP/v2/ITokenMessengerV2.sol";
import "./interfaces/CCTP/ITokenMessenger.sol";
import "./interfaces/IFeeManager.sol";
import "./interfaces/IWormhole.sol";
import "./interfaces/IMayanCircle.sol";
import "./interfaces/IFastMCTP.sol";


contract ZeroXHub is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BytesLib for bytes;

    IFastMCTP public fastMCTP;
    IMayanCircle public mayanCircle;

    mapping(bytes32 => uint256) public hubRelayerFee;

    uint256 constant CCTPV2_DOMAIN_INDEX = 4;
	uint256 constant CCTPV2_TOKEN_INDEX = 152;

    uint256 constant CCTP_DOMAIN_INDEX = 4;
	uint256 constant CCTP_NONCE_INDEX = 12;
	uint256 constant CCTP_TOKEN_INDEX = 120;
	uint256 constant CCTP_AMOUNT_INDEX = 208;

    // Constants and state variables
    address public guardian;
    address public nextGuardian;

    // Errors
    error Unauthorized();
    error UnsupportedHubPayloadType();
    error EthTransferFailed();
    error UnsupportedRoute();

    enum PayloadProtocol {
        FastMCTP,
        MayanCircle
    }

    struct HubPayloadBridge {
        // 0xHub specific
        uint8 hubPayloadType;
        uint64 hubRelayerFee;
        bytes32 sourceAddress;

        bytes32 destAddress;
        uint16 destChain;
        uint64 gasDrop;
        uint64 redeemFee;
        bytes32 referrerAddress;
        uint8 referrerBps;

        // FastMCTP specific
        uint64 circleMaxFee;
        uint32 minFinalityThreshold;
    }

    struct HubPayloadOrder {
        // 0xHub specific
        uint8 hubPayloadType;
        uint64 hubRelayerFee;
        bytes32 sourceAddress;

        bytes32 destAddress;
        uint16 destChain;
        bytes32 tokenOut;
        uint64 amountOutMin;
        uint64 gasDrop;
        uint64 redeemFee;
        uint64 refundFee;
        uint64 deadline;
        bytes32 referrerAddr;
        uint8 referrerBps;

        // FastMCTP specific
        uint64 circleMaxFee;
        uint32 minFinalityThreshold;
    }

    // Constants for hub payload types
    uint8 internal constant HUB_PAYLOAD_TYPE_BRIDGE = 1;
    uint8 internal constant HUB_PAYLOAD_TYPE_ORDER = 2;

    // Constants for hook data parsing
    uint256 internal constant HOOK_DATA_INDEX = 148 + 228 + 82; // CCTPV2_MESSAGE_BODY_INDEX + 228 (from FastMCTP)

    constructor(
        address _fastMCTP,
        address _mayanCircle
    ) {
        fastMCTP = IFastMCTP(_fastMCTP);
        mayanCircle = IMayanCircle(_mayanCircle);
        guardian = msg.sender;
    }

    function processFastMCTPIncoming(
        bytes memory payload,
        bytes memory cctpMsg,
        bytes memory cctpSigs
    ) external nonReentrant {
        (address localToken, uint256 amount) = receiveFastMCTPMessage(
            cctpMsg,
            cctpSigs
        );

        bytes32 payloadHash = cctpMsg.toBytes32(HOOK_DATA_INDEX);
        require(payloadHash == keccak256(payload), "Invalid payload hash");

        route(payload, amount, localToken, PayloadProtocol.MayanCircle);
    }

    function processMayanCircleIncoming(
        bytes memory payload,
        bytes memory cctpMsg,
        bytes memory cctpSigs,
        bytes memory encodedVm,
        uint64 burnAmount,
        bytes32 burnToken
    ) external nonReentrant {
        IMayanCircle.BridgeWithFeeParams memory params = IMayanCircle.BridgeWithFeeParams ({
            payloadType: uint8(2),
            destAddr: bytes32(uint256(uint160(address(this)))),
            gasDrop: 0,
            redeemFee: 0,
            burnAmount: burnAmount,
            burnToken: burnToken,
            customPayload: keccak256(payload)
        });

        (address localToken, uint256 amount) = receiveMayanCircleMessage(cctpMsg, cctpSigs, encodedVm, params);

        route(payload, amount, localToken, PayloadProtocol.FastMCTP);
    }

    function route(bytes memory payload, uint256 amount, address localToken, PayloadProtocol destProtocol) internal {
        uint8 hubPayloadType = uint8(payload[0]);

        if (hubPayloadType == HUB_PAYLOAD_TYPE_BRIDGE) {
            HubPayloadBridge memory bridgePayload = decodeHubPayloadBridge(
                payload
            );
            
            amount = amount - bridgePayload.hubRelayerFee;
            bytes32 relayerKey = getRelayerKey(localToken, tx.origin);
            hubRelayerFee[relayerKey] += bridgePayload.hubRelayerFee;

            processBridgePayload(localToken, amount, bridgePayload, destProtocol);
        } else if (hubPayloadType == HUB_PAYLOAD_TYPE_ORDER) {
            HubPayloadOrder memory orderPayload = decodeHubPayloadOrder(
                payload
            );

            amount = amount - orderPayload.hubRelayerFee;
            bytes32 relayerKey = getRelayerKey(localToken, tx.origin);
            hubRelayerFee[relayerKey] += orderPayload.hubRelayerFee;

            processOrderPayload(localToken, amount, orderPayload, destProtocol);
        } else {
            revert UnsupportedHubPayloadType();
        }
    }

    function processBridgePayload(
        address localToken,
        uint256 amount,
        HubPayloadBridge memory bridgePayload,
        PayloadProtocol protocol
    ) internal {
        bytes memory empty;
        if (protocol == PayloadProtocol.FastMCTP) {
            fastMCTP.bridge(
                localToken,
                amount,
                bridgePayload.redeemFee,
                uint256(bridgePayload.circleMaxFee),
                bridgePayload.gasDrop,
                bridgePayload.destAddress,
                bridgePayload.destChain,
                bridgePayload.referrerAddress,
                bridgePayload.referrerBps,
                uint8(1),
                bridgePayload.minFinalityThreshold,
                empty
            );
        } else if (protocol == PayloadProtocol.MayanCircle) {
            mayanCircle.bridgeWithFee(
                localToken,
                amount,
                bridgePayload.redeemFee,
                bridgePayload.gasDrop,
                bridgePayload.destAddress,
                bridgePayload.destChain,
                uint8(1),
                empty
            );
        } else {
            revert UnsupportedRoute();
        }
    }

    function processOrderPayload(
        address localToken,
        uint256 amount,
        HubPayloadOrder memory orderPayload,
        PayloadProtocol protocol
    ) internal {
        if (protocol == PayloadProtocol.FastMCTP) {
            IFastMCTP.OrderPayload memory fastMCTPPayload = IFastMCTP.OrderPayload ({
                payloadType: uint8(3),
                destAddr: orderPayload.destAddress,
                tokenOut: orderPayload.tokenOut,
                amountOutMin: orderPayload.amountOutMin,
                gasDrop: orderPayload.gasDrop,
                redeemFee: orderPayload.redeemFee,
                refundFee: orderPayload.refundFee,
                deadline: orderPayload.deadline,
                referrerAddr: orderPayload.referrerAddr,
                referrerBps: orderPayload.referrerBps
            });
            fastMCTP.createOrder(
                localToken,
                amount,
                uint256(orderPayload.circleMaxFee),
                orderPayload.destChain,
                orderPayload.minFinalityThreshold,
                fastMCTPPayload
            );
        } else if (protocol == PayloadProtocol.MayanCircle) {
            IMayanCircle.OrderParams memory mayanCircleOrderParams = IMayanCircle.OrderParams ({
                tokenIn: localToken,
                amountIn: amount,
                gasDrop: orderPayload.gasDrop,
                destAddr: orderPayload.destAddress,
                destChain: orderPayload.destChain,
                tokenOut: orderPayload.tokenOut,
                minAmountOut: orderPayload.amountOutMin,
                deadline: orderPayload.deadline,
                redeemFee: orderPayload.redeemFee,
                referrerAddr: orderPayload.referrerAddr,
                referrerBps: orderPayload.referrerBps
            });
            mayanCircle.createOrder(mayanCircleOrderParams);
        } else {
            revert UnsupportedRoute();
        }
    }

    function rescueFastMCTP(
        bytes memory payload,
        bytes memory cctpMsg,
        bytes memory cctpSigs
    ) external payable {
        uint32 sourceDomain = cctpMsg.toUint32(CCTPV2_DOMAIN_INDEX);
        bytes32 sourceToken = cctpMsg.toBytes32(CCTPV2_TOKEN_INDEX);
        address localToken = fastMCTP.cctpTokenMessengerV2().localMinter().getLocalToken(sourceDomain, sourceToken);

        uint256 ethBalance = address(this).balance - msg.value;
        uint256 balance = IERC20(localToken).balanceOf(address(this));
        fastMCTP.redeem{value: msg.value}(cctpMsg, cctpSigs);
        uint256 receivedAmount = IERC20(localToken).balanceOf(address(this)) - balance;
        uint256 receivedEth = address(this).balance - ethBalance;
        payEth(tx.origin, receivedEth, false);

        bytes32 payloadHash = cctpMsg.toBytes32(HOOK_DATA_INDEX);
        require(payloadHash == keccak256(payload), "Invalid payload hash");

        rescueToken(payload, receivedAmount, localToken);
    }

    function rescueMayanCircle(
        bytes memory payload,
        bytes memory cctpMsg,
        bytes memory cctpSigs,
        bytes memory encodedVm,
        uint64 burnAmount,
        bytes32 burnToken,
        uint64 redeemFee
    ) external payable {
        IMayanCircle.BridgeWithFeeParams memory params = IMayanCircle.BridgeWithFeeParams ({
            payloadType: uint8(2),
            destAddr: bytes32(uint256(uint160(address(this)))),
            gasDrop: uint64(msg.value),
            redeemFee: redeemFee,
            burnAmount: burnAmount,
            burnToken: burnToken,
            customPayload: keccak256(payload)
        });

        uint32 sourceDomain = cctpMsg.toUint32(CCTP_DOMAIN_INDEX);
        bytes32 sourceToken = cctpMsg.toBytes32(CCTP_TOKEN_INDEX);
        address localToken = mayanCircle.cctpTokenMessenger().localMinter().getLocalToken(sourceDomain, sourceToken);

        uint256 ethBalance = address(this).balance - msg.value;
        uint256 balance = IERC20(localToken).balanceOf(address(this));
        mayanCircle.redeemWithFee(cctpMsg, cctpSigs, encodedVm, params);
        uint256 receivedAmount = IERC20(localToken).balanceOf(address(this)) - balance;
        uint256 receivedEth = address(this).balance - ethBalance;
        payEth(tx.origin, receivedEth, false);

        rescueToken(payload, receivedAmount, localToken);
    }

    function rescueToken(bytes memory payload, uint256 amount, address localToken) internal {
        uint8 payloadType = uint8(payload[0]);
        if (payloadType == HUB_PAYLOAD_TYPE_BRIDGE) {
            HubPayloadBridge memory bridgePayload = decodeHubPayloadBridge(payload);
            if (bytes32(uint256(uint160(tx.origin))) == bridgePayload.destAddress || bytes32(uint256(uint160(tx.origin))) == bridgePayload.sourceAddress) {
                IERC20(localToken).safeTransfer(tx.origin, amount);
            } else {
                revert Unauthorized();
            }
        } else if (payloadType == HUB_PAYLOAD_TYPE_ORDER) {
            HubPayloadOrder memory orderPayload = decodeHubPayloadOrder(payload);
            if (bytes32(uint256(uint160(tx.origin))) == orderPayload.destAddress || bytes32(uint256(uint160(tx.origin))) == orderPayload.sourceAddress) {
                IERC20(localToken).safeTransfer(tx.origin, amount);
            } else {
                revert Unauthorized();
            }
        } else {
            revert UnsupportedHubPayloadType();
        }
    }

    function decodeHubPayloadBridge(
        bytes memory data
    ) internal pure returns (HubPayloadBridge memory) {
        require(
            data.length >= 1 && uint8(data[0]) == HUB_PAYLOAD_TYPE_BRIDGE,
            "Invalid bridge payload type"
        );

        HubPayloadBridge memory payload;
        payload.hubPayloadType = data.toUint8(0);
        uint256 offset = 1;

        payload.hubRelayerFee = data.toUint64(offset);
        offset += 8;

        payload.destAddress = data.toBytes32(offset);
        offset += 32;

        payload.destChain = data.toUint16(offset);
        offset += 2;

        payload.gasDrop = data.toUint64(offset);
        offset += 8;

        payload.redeemFee = data.toUint64(offset);
        offset += 8;

        payload.referrerAddress = data.toBytes32(offset);
        offset += 32;

        payload.referrerBps = data.toUint8(offset);
        offset += 1;

        payload.circleMaxFee = data.toUint64(offset);
        offset += 8;

        payload.minFinalityThreshold = data.toUint32(offset);
        offset += 4;

        return payload;
    }

    function encodeHubPayloadBridge(
        HubPayloadBridge memory payload
    ) public pure returns (bytes memory) {
        return abi.encodePacked(
            HUB_PAYLOAD_TYPE_BRIDGE,
            payload.hubRelayerFee,
            payload.sourceAddress,
            payload.destAddress,
            payload.destChain,
            payload.gasDrop,
            payload.redeemFee,
            payload.referrerAddress,
            payload.referrerBps,
            payload.circleMaxFee,
            payload.minFinalityThreshold
        );
    }

    function decodeHubPayloadOrder(
        bytes memory data
    ) internal pure returns (HubPayloadOrder memory) {
        require(
            data.length >= 1 && uint8(data[0]) == HUB_PAYLOAD_TYPE_ORDER,
            "Invalid order payload type"
        );

        HubPayloadOrder memory payload;
        payload.hubPayloadType = data.toUint8(0);
        uint256 offset = 1;

        payload.hubRelayerFee = data.toUint64(offset);
        offset += 8;

        payload.sourceAddress = data.toBytes32(offset);
        offset += 32;

        payload.destAddress = data.toBytes32(offset);
        offset += 32;

        payload.destChain = data.toUint16(offset);
        offset += 2;

        payload.tokenOut = data.toBytes32(offset);
        offset += 32;

        payload.amountOutMin = data.toUint64(offset);
        offset += 8;

        payload.gasDrop = data.toUint64(offset);
        offset += 8;

        payload.redeemFee = data.toUint64(offset);
        offset += 8;

        payload.refundFee = data.toUint64(offset);
        offset += 8;

        payload.deadline = data.toUint64(offset);
        offset += 8;

        payload.referrerAddr = data.toBytes32(offset);
        offset += 32;

        payload.referrerBps = data.toUint8(offset);
        offset += 1;

        payload.circleMaxFee = data.toUint64(offset);
        offset += 8;

        payload.minFinalityThreshold = data.toUint32(offset);
        offset += 4;

        return payload;
    }

    function encodeHubPayloadOrder(
        HubPayloadOrder memory payload
    ) public pure returns (bytes memory) {
        bytes memory encoded;

        encoded = abi.encodePacked(
            HUB_PAYLOAD_TYPE_ORDER,
            payload.hubRelayerFee,
            payload.sourceAddress,
            payload.destAddress,
            payload.destChain,
            payload.tokenOut,
            payload.amountOutMin,
            payload.gasDrop,
            payload.redeemFee,
            payload.refundFee,
            payload.deadline,
            payload.referrerAddr,
            payload.referrerBps,
            payload.circleMaxFee
        );

        encoded = abi.encodePacked(
            encoded,
            payload.minFinalityThreshold
        );

        return encoded;
    }

    function receiveFastMCTPMessage(
        bytes memory cctpMsg,
        bytes memory cctpSigs
    ) internal returns (address, uint256) {
        uint32 sourceDomain = cctpMsg.toUint32(CCTPV2_DOMAIN_INDEX);
        bytes32 sourceToken = cctpMsg.toBytes32(CCTPV2_TOKEN_INDEX);
        address localToken = fastMCTP.cctpTokenMessengerV2().localMinter().getLocalToken(sourceDomain, sourceToken);

        uint256 balance = IERC20(localToken).balanceOf(address(this));
        fastMCTP.redeem(cctpMsg, cctpSigs);
        uint256 receivedAmount = IERC20(localToken).balanceOf(address(this)) - balance;

        return (localToken, receivedAmount);
    }

    function receiveMayanCircleMessage(
        bytes memory cctpMsg,
        bytes memory cctpSigs,
        bytes memory encodedVm,
        IMayanCircle.BridgeWithFeeParams memory params
    ) internal returns (address, uint256) {
        uint32 sourceDomain = cctpMsg.toUint32(CCTP_DOMAIN_INDEX);
        bytes32 sourceToken = cctpMsg.toBytes32(CCTP_TOKEN_INDEX);
        address localToken = mayanCircle.cctpTokenMessenger().localMinter().getLocalToken(sourceDomain, sourceToken);

        uint256 balance = IERC20(localToken).balanceOf(address(this));
        mayanCircle.redeemWithFee(cctpMsg, cctpSigs, encodedVm, params);
        uint256 receivedAmount = IERC20(localToken).balanceOf(address(this)) - balance;

        return (localToken, receivedAmount);
    }

	function approveIfNeeded(address tokenAddr, address spender, uint256 amount, bool max) internal {
		IERC20 token = IERC20(tokenAddr);
		uint256 currentAllowance = token.allowance(address(this), spender);

		if (currentAllowance < amount) {
			if (currentAllowance > 0) {
				token.safeApprove(spender, 0);
			}
			token.safeApprove(spender, max ? type(uint256).max : amount);
		}
	}

    function truncateAddress(bytes32 b) internal pure returns (address) {
        return address(uint160(uint256(b)));
    }

    function withdrawRelayerFee(address token) external {
        bytes32 relayerKey = getRelayerKey(token, tx.origin);
        uint256 fee = hubRelayerFee[relayerKey];
        hubRelayerFee[relayerKey] = 0;
        IERC20(token).safeTransfer(tx.origin, fee);
    }

    function getRelayerKey(address token, address relayer) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(token, relayer));
    }

    function changeGuardian(address newGuardian) external {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        nextGuardian = newGuardian;
    }

    function claimGuardian() external {
        if (msg.sender != nextGuardian) {
            revert Unauthorized();
        }
        guardian = nextGuardian;
    }

	function rescueEth(uint256 amount, address payable to) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		payEth(to, amount, true);
	}

    function payEth(address to, uint256 amount, bool revertOnFailure) internal {
		(bool success, ) = payable(to).call{value: amount}('');
		if (revertOnFailure) {
			if (success != true) {
				revert EthTransferFailed();
			}
		}
	}

    receive() external payable {}
}
