
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libs/BytesLib.sol";
import "./interfaces/CCTP/v2/ITokenMessengerV2.sol";
import "./interfaces/CCTP/ITokenMessenger.sol";
import "./interfaces/IFeeManager.sol";

interface IMayanCircle {
    struct OrderParams {
		address tokenIn;
		uint256 amountIn;
		uint64 gasDrop;
		bytes32 destAddr;
		uint16 destChain;
		bytes32 tokenOut;
		uint64 minAmountOut;
		uint64 deadline;
		uint64 redeemFee;
		bytes32 referrerAddr;
		uint8 referrerBps;
	}

    function bridgeWithFee(
		address tokenIn,
		uint256 amountIn,
		uint64 redeemFee,
		uint64 gasDrop,
		bytes32 destAddr,
		uint32 destDomain,
		uint8 payloadType,
		bytes memory customPayload
	) external payable returns (uint64 sequence);

    function createOrder(
		OrderParams memory params
	) external payable returns (uint64 sequence);
}

interface IFastMCTP {
    struct OrderPayload {
		uint8 payloadType;
		bytes32 destAddr;
		bytes32 tokenOut;
		uint64 amountOutMin;
		uint64 gasDrop;
		uint64 redeemFee;
		uint64 refundFee;
		uint64 deadline;
		bytes32 referrerAddr;
		uint8 referrerBps;
	}

    function bridge(
		address tokenIn,
		uint256 amountIn,
		uint64 redeemFee,
		uint256 circleMaxFee,
		uint64 gasDrop,
		bytes32 destAddr,
		uint32 destDomain,
		bytes32 referrerAddress,
		uint8 referrerBps,
		uint8 payloadType,
		uint32 minFinalityThreshold,
		bytes memory customPayload
	) external;

    function createOrder(
		address tokenIn,
		uint256 amountIn,
		uint256 circleMaxFee,
		uint32 destDomain,
		uint32 minFinalityThreshold,
		OrderPayload memory orderPayload
	) external;

    function redeem(
		bytes memory cctpMsg,
		bytes memory cctpSigs
	) external payable;

    function cctpTokenMessengerV2() external view returns (ITokenMessengerV2);
}

contract ZeroXHub is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BytesLib for bytes;

    IFastMCTP public fastMCTP;
    IMayanCircle public mayanCircle;

    // Protocol mappings
    mapping(uint32 => bool) public isFastMCTPDomain;
    mapping(uint32 => bool) public isMayanCircleDomain;

    // Configuration mappings
    mapping(bytes32 => bytes32) public fastMCTPMintRecipients; // key is domain + tokenIn
    mapping(bytes32 => bytes32) public mayanCircleMintRecipients; // key is domain + tokenIn
    mapping(uint32 => bytes32) public fastMCTPDomainCallers;
    mapping(uint32 => bytes32) public mayanCircleDomainCallers;

    // Constants and state variables
    address public guardian;
    address public nextGuardian;

    // Errors
    error Unauthorized();
    error UnsupportedToken();
    error UnsupportedDomain();
    error InvalidMintRecipient();
    error CallerNotSet();
    error MintRecipientNotSet();
    error AlreadySet();
    error CctpReceiveFailed();
    error InvalidAmountOut();
    error ForwarderCallFailed();
    error InvalidPayloadType();
    error UnsupportedHubPayloadType();
    error InsufficientReceivedAmount();
    error EthTransferFailed();
    error UnsupportedRoute();

    enum HubRoute {
        None,
        FastMCTP,
        MayanCircle
    }

    struct HubPayloadBridge {
        uint8 hubPayloadType;
        uint64 hubRelayerFee;
        bytes32 destAddress;
        uint16 destChain;
        uint64 gasDrop;
        uint64 redeemFee;
        uint8 bridgePayloadType;
        HubRoute route;
        bytes customPayload;
    }

    struct HubPayloadOrder {
        uint8 hubPayloadType;
        uint64 hubRelayerFee;
        bytes32 destAddress;
        uint16 destChain;
        bytes32 tokenOut;
        uint64 minAmountOut;
        uint64 gasDrop;
        uint64 redeemFee;
        bytes32 referrerAddr;
        uint8 referrerBps;
        HubRoute route;
    }

    // Constants for hub payload types
    uint8 internal constant HUB_PAYLOAD_TYPE_BRIDGE = 1;
    uint8 internal constant HUB_PAYLOAD_TYPE_ORDER = 2;

    // Constants for hook data parsing
    uint256 internal constant HOOK_DATA_INDEX = 148 + 228; // CCTPV2_MESSAGE_BODY_INDEX + 228 (from FastMCTP)

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

        uint8 hubPayloadType = uint8(payload[0]);

        if (hubPayloadType == HUB_PAYLOAD_TYPE_BRIDGE) {
            HubPayloadBridge memory bridgePayload = decodeHubPayloadBridge(
                payload
            );

            // if (!isMayanCircleDomain[uint32(bridgePayload.destChain)]) {
            //     revert UnsupportedDomain();
            // }

            processBridgePayload(localToken, amount, bridgePayload);
        } else if (hubPayloadType == HUB_PAYLOAD_TYPE_ORDER) {
            HubPayloadOrder memory orderPayload = decodeHubPayloadOrder(
                payload
            );

            //     if (!isMayanCircleDomain[uint32(orderPayload.destChain)]) {
            //         revert UnsupportedDomain();
            // }

            processOrderPayload(localToken, amount, orderPayload);
        } else {
            revert UnsupportedHubPayloadType();
        }
    }

    // function processMayanCircleIncoming(
    //     bytes memory cctpMsg,
    //     bytes memory cctpSigs
    // ) external nonReentrant {
    //     (address localToken, uint256 amount) = receiveMayanCircleMessage(
    //         cctpMsg,
    //         cctpSigs
    //     );

    //     bytes memory messageBody = extractMessageBody(cctpMsg);
    //     uint8 hubPayloadType = uint8(messageBody[0]);

    //     if (hubPayloadType == HUB_PAYLOAD_TYPE_BRIDGE) {
    //         HubPayloadBridge memory bridgePayload = decodeHubPayloadBridge(
    //             messageBody
    //         );

    //         if (amount <= bridgePayload.hubRelayerFee + bridgePayload.redeemFee) {
    //             revert InsufficientReceivedAmount();
    //         }

    //         if (!isFastMCTPDomain[uint32(bridgePayload.destChain)]) {
    //             revert UnsupportedDomain();
    //         }

    //         processBridgePayload(localToken, amount, bridgePayload);
    //     } else if (hubPayloadType == HUB_PAYLOAD_TYPE_ORDER) {
    //         HubPayloadOrder memory orderPayload = decodeHubPayloadOrder(
    //             messageBody
    //         );

    //         if (amount <= orderPayload.hubRelayerFee + orderPayload.redeemFee) {
    //             revert InsufficientReceivedAmount();
    //         }

    //         if (!isFastMCTPDomain[uint32(orderPayload.destChain)]) {
    //             revert UnsupportedDomain();
    //         }

    //         processOrderPayload(localToken, amount, orderPayload);
    //     } else {
    //         revert UnsupportedHubPayloadType();
    //     }
    // }

    function processBridgePayload(
        address localToken,
        uint256 amount,
        HubPayloadBridge memory bridgePayload
    ) internal {
        if (bridgePayload.route == HubRoute.FastMCTP) {
            // fastMCTP.bridge(
            //     localToken,
            //     amount,
            //     bridgePayload.redeemFee,
            //     bridgePayload.hubRelayerFee,
            //     bridgePayload.gasDrop,
            //     bridgePayload.destAddress,
            //     bridgePayload.destChain,
            //     bridgePayload.bridgePayloadType,
            //     bridgePayload.customPayload
            // );
        } else if (bridgePayload.route == HubRoute.MayanCircle) {
            mayanCircle.bridgeWithFee(
                localToken,
                amount,
                bridgePayload.redeemFee,
                bridgePayload.gasDrop,
                bridgePayload.destAddress,
                bridgePayload.destChain,
                bridgePayload.bridgePayloadType,
                bridgePayload.customPayload
            );
        } else {
            revert UnsupportedRoute();
        }
    }

    function processOrderPayload(
        address localToken,
        uint256 amount,
        HubPayloadOrder memory orderPayload
    ) internal {
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

        // hubRelayerFee (uint64 - 8 bytes)
        payload.hubRelayerFee = data.toUint64(offset);
        offset += 8;

        // destAddress (bytes32 - 32 bytes)
        payload.destAddress = data.toBytes32(offset);
        offset += 32;

        // destChain (uint16 - 2 bytes)
        payload.destChain = data.toUint16(offset);
        offset += 2;

        // gasDrop (uint64 - 8 bytes)
        payload.gasDrop = data.toUint64(offset);
        offset += 8;

        // redeemFee (uint64 - 8 bytes)
        payload.redeemFee = data.toUint64(offset);
        offset += 8;

        // bridgePayloadType (uint8 - 1 byte)
        payload.bridgePayloadType = data.toUint8(offset);
        offset += 1;

        // route (uint8 - 1 byte)
        payload.route = HubRoute(data.toUint8(offset));
        offset += 1;

        // customPayload (remaining bytes)
        uint256 customPayloadLength = data.length - offset;
        payload.customPayload = new bytes(customPayloadLength);
        for (uint256 i = 0; i < customPayloadLength; i++) {
            payload.customPayload[i] = data[offset + i];
        }

        return payload;
    }

    function encodeHubPayloadBridge(
        HubPayloadBridge memory payload
    ) view returns (bytes memory) {
        return abi.encodePacked(
            HUB_PAYLOAD_TYPE_BRIDGE,
            payload.hubRelayerFee,
            payload.destAddress,
            payload.destChain,
            payload.gasDrop,
            payload.redeemFee,
            payload.bridgePayloadType,
            payload.route,
            payload.customPayload
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

        // hubRelayerFee (uint64 - 8 bytes)
        payload.hubRelayerFee = data.toUint64(offset);
        offset += 8;

        // destAddress (bytes32 - 32 bytes)
        payload.destAddress = data.toBytes32(offset);
        offset += 32;

        // destChain (uint16 - 2 bytes)
        payload.destChain = data.toUint16(offset);
        offset += 2;

        // tokenOut (bytes32 - 32 bytes)
        payload.tokenOut = data.toBytes32(offset);
        offset += 32;

        // minAmountOut (uint64 - 8 bytes)
        payload.minAmountOut = data.toUint64(offset);
        offset += 8;

        // gasDrop (uint64 - 8 bytes)
        payload.gasDrop = data.toUint64(offset);
        offset += 8;

        // redeemFee (uint64 - 8 bytes)
        payload.redeemFee = data.toUint64(offset);
        offset += 8;

        // referrerAddr (bytes32 - 32 bytes)
        payload.referrerAddr = data.toBytes32(offset);
        offset += 32;

        // referrerBps (uint8 - 1 byte)
        payload.referrerBps = data.toUint8(offset);
        offset += 1;

        // route (uint8 - 1 byte)
        payload.route = HubRoute(data.toUint8(offset));

        return payload;
    }

    function encodeHubPayloadOrder(
        HubPayloadOrder memory payload
    ) view returns (bytes memory) {
        return abi.encodePacked(
            HUB_PAYLOAD_TYPE_ORDER,
            payload.hubRelayerFee,
            payload.destAddress,
            payload.destChain,
            payload.tokenOut,
            payload.minAmountOut,
            payload.gasDrop,
            payload.redeemFee,
            payload.referrerAddr,
            payload.referrerBps,
            payload.route
        );
    }

    function receiveFastMCTPMessage(
        bytes memory cctpMsg,
        bytes memory cctpSigs
    ) internal returns (address, uint256) {
        // CCTPV2_MESSAGE_BODY_INDEX + 4
        uint256 sourceTokenIndex = 152;
        // CCTPV2_SOURCE_DOMAIN_INDEX
        uint256 sourceIndex = 4;

        uint32 sourceDomain = cctpMsg.toUint32(sourceIndex);
        bytes32 sourceToken = cctpMsg.toBytes32(sourceTokenIndex);
        address localToken = fastMCTP.cctpTokenMessengerV2().localMinter().getLocalToken(sourceDomain, sourceToken);

        uint256 balance = IERC20(localToken).balanceOf(address(this));
        fastMCTP.redeem(cctpMsg, cctpSigs);
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

    function rescueToken(address token, uint256 amount, address to) external {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        IERC20(token).safeTransfer(to, amount);
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
