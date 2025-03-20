
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libs/BytesLib.sol";
import "./interfaces/CCTP/v2/ITokenMessengerV2.sol";
import "./interfaces/CCTP/ITokenMessenger.sol";
import "./interfaces/IFeeManager.sol";

contract ZeroXHub is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BytesLib for bytes;

    // CCTP Interfaces
    ITokenMessengerV2 public immutable fastMCTPTokenMessenger;
    ITokenMessenger public immutable mayanTokenMessenger;
    address public feeManager;
    address public mayanForwarder; // Address of the MayanForwarder contract

    // Supported stablecoins (typically USDC/EUROC)
    mapping(address => bool) public supportedTokens;

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
    bool public paused;

    // Errors
    error Paused();
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

    // Empty permit params struct for forwarder calls
    struct PermitParams {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // Hub payload structs
    struct HubPayloadBridge {
        uint8 hubPayloadType;
        uint64 hubRelayerFee;
        bytes32 destAddress;
        uint16 destChain;
        uint64 gasDrop;
        uint64 redeemFee;
        uint8 bridgePayloadType;
        bytes32 referrerAddr;
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
    }

    // Constants for hub payload types
    uint8 internal constant HUB_PAYLOAD_TYPE_BRIDGE = 1;
    uint8 internal constant HUB_PAYLOAD_TYPE_ORDER = 2;

    // Constants for hook data parsing
    uint256 internal constant HOOK_DATA_INDEX = 148 + 228; // CCTPV2_MESSAGE_BODY_INDEX + 228 (from FastMCTP)

    modifier whenNotPaused() {
        if (paused) {
            revert Paused();
        }
        _;
    }

    constructor(
        address _fastMCTPTokenMessenger,
        address _mayanTokenMessenger,
        address _feeManager,
        address _mayanForwarder
    ) {
        fastMCTPTokenMessenger = ITokenMessengerV2(_fastMCTPTokenMessenger);
        mayanTokenMessenger = ITokenMessenger(_mayanTokenMessenger);
        feeManager = _feeManager;
        mayanForwarder = _mayanForwarder;
        guardian = msg.sender;
    }

    function processFastMCTPIncoming(
        bytes memory cctpMsg,
        bytes memory cctpSigs
    ) external nonReentrant whenNotPaused {
        (address localToken, uint256 amount) = receiveFastMCTPMessage(
            cctpMsg,
            cctpSigs
        );

        if (!supportedTokens[localToken]) {
            revert UnsupportedToken();
        }

        bytes memory hookData = extractHookData(cctpMsg);
        uint8 hubPayloadType = uint8(hookData[0]);

        if (hubPayloadType == HUB_PAYLOAD_TYPE_BRIDGE) {
            HubPayloadBridge memory bridgePayload = decodeHubPayloadBridge(
                hookData
            );

            if (amount <= bridgePayload.hubRelayerFee + bridgePayload.redeemFee) {
                revert InsufficientReceivedAmount();
            }

            if (!isMayanCircleDomain[uint32(bridgePayload.destChain)]) {
                revert UnsupportedDomain();
            }

            processBridgePayload(localToken, amount, bridgePayload);
        } else if (hubPayloadType == HUB_PAYLOAD_TYPE_ORDER) {
            HubPayloadOrder memory orderPayload = decodeHubPayloadOrder(
                hookData
            );

            if (amount <= orderPayload.hubRelayerFee + orderPayload.redeemFee) {
                revert InsufficientReceivedAmount();
            }

            if (!isMayanCircleDomain[uint32(orderPayload.destChain)]) {
                revert UnsupportedDomain();
            }

            processOrderPayload(localToken, amount, orderPayload);
        } else {
            revert UnsupportedHubPayloadType();
        }
    }

    function processMayanCircleIncoming(
        bytes memory cctpMsg,
        bytes memory cctpSigs
    ) external nonReentrant whenNotPaused {
        (address localToken, uint256 amount) = receiveMayanCircleMessage(
            cctpMsg,
            cctpSigs
        );

        if (!supportedTokens[localToken]) {
            revert UnsupportedToken();
        }

        bytes memory messageBody = extractMessageBody(cctpMsg);
        uint8 hubPayloadType = uint8(messageBody[0]);

        if (hubPayloadType == HUB_PAYLOAD_TYPE_BRIDGE) {
            HubPayloadBridge memory bridgePayload = decodeHubPayloadBridge(
                messageBody
            );

            if (amount <= bridgePayload.hubRelayerFee + bridgePayload.redeemFee) {
                revert InsufficientReceivedAmount();
            }

            if (!isFastMCTPDomain[uint32(bridgePayload.destChain)]) {
                revert UnsupportedDomain();
            }

            processBridgePayload(localToken, amount, bridgePayload);
        } else if (hubPayloadType == HUB_PAYLOAD_TYPE_ORDER) {
            HubPayloadOrder memory orderPayload = decodeHubPayloadOrder(
                messageBody
            );

            if (amount <= orderPayload.hubRelayerFee + orderPayload.redeemFee) {
                revert InsufficientReceivedAmount();
            }

            if (!isFastMCTPDomain[uint32(orderPayload.destChain)]) {
                revert UnsupportedDomain();
            }

            processOrderPayload(localToken, amount, orderPayload);
        } else {
            revert UnsupportedHubPayloadType();
        }
    }

    function processBridgePayload(
        address localToken,
        uint256 amount,
        HubPayloadBridge memory bridgePayload
    ) internal {
        approveIfNeeded(localToken, mayanForwarder, amount, false);

        PermitParams memory emptyPermit = PermitParams({
            value: 0,
            deadline: 0,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });

        address protocol;
        bytes memory protocolData;

        if (isMayanCircleDomain[uint32(bridgePayload.destChain)]) {
            // TODO: Call MayanCircle interface
            // protocol = address(mayanTokenMessenger);

            // protocolData = abi.encodeWithSelector(
            //     ITokenMessenger.depositForBurnWithCaller.selector,
            //     amount - bridgePayload.hubRelayerFee,
            //     uint32(bridgePayload.destChain),
            //     getMayanCircleMintRecipient(
            //         uint32(bridgePayload.destChain),
            //         localToken
            //     ),
            //     localToken,
            //     getMayanCircleCaller(uint32(bridgePayload.destChain))
            // );
        } else if (isFastMCTPDomain[uint32(bridgePayload.destChain)]) {
            // TODO: Call FastMCTP interface
            // protocol = address(fastMCTPTokenMessenger);

            // bytes memory hookData = bridgePayload.customPayload;

            // protocolData = abi.encodeWithSelector(
            //     ITokenMessengerV2.depositForBurnWithHook.selector,
            //     amount - bridgePayload.hubRelayerFee,
            //     uint32(bridgePayload.destChain),
            //     getFastMCTPMintRecipient(
            //         uint32(bridgePayload.destChain),
            //         localToken
            //     ),
            //     localToken,
            //     getFastMCTPCaller(uint32(bridgePayload.destChain)),
            //     0, // maxFee
            //     0, // minFinalityThreshold
            //     hookData
            // );
        } else {
            revert UnsupportedDomain();
        }

        // TODO: Remove forwarder call
        // (bool success, ) = mayanForwarder.call(
        //     abi.encodeWithSignature(
        //         "forwardERC20(address,uint256,(uint256,uint256,uint8,bytes32,bytes32),address,bytes)",
        //         localToken,
        //         amount,
        //         emptyPermit,
        //         protocol,
        //         protocolData
        //     )
        // );

        // if (!success) {
        //     revert ForwarderCallFailed();
        // }
    }

    function processOrderPayload(
        address localToken,
        uint256 amount,
        HubPayloadOrder memory orderPayload
    ) internal {
        approveIfNeeded(localToken, mayanForwarder, amount, false);

        PermitParams memory emptyPermit = PermitParams({
            value: 0,
            deadline: 0,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });

        address swapProtocol = address(0);
        bytes memory swapData = new bytes(0);

        address targetProtocol;
        bytes memory targetData;

        address middleToken = truncateAddress(orderPayload.tokenOut);

        if (isMayanCircleDomain[uint32(orderPayload.destChain)]) {
            // TODO: Call MayanCircle interface
            // targetProtocol = address(mayanTokenMessenger);

            // targetData = abi.encodeWithSelector(
            //     ITokenMessenger.depositForBurnWithCaller.selector,
            //     0, // Amount will be replaced by MayanForwarder
            //     uint32(orderPayload.destChain),
            //     getMayanCircleMintRecipient(
            //         uint32(orderPayload.destChain),
            //         middleToken
            //     ),
            //     middleToken,
            //     getMayanCircleCaller(uint32(orderPayload.destChain))
            // );
        } else if (isFastMCTPDomain[uint32(orderPayload.destChain)]) {
            // TODO: Call FastMCTP interface
            // targetProtocol = address(fastMCTPTokenMessenger);

            // bytes memory hookData = new bytes(0);

            // targetData = abi.encodeWithSelector(
            //     ITokenMessengerV2.depositForBurnWithHook.selector,
            //     0, // Amount will be replaced by MayanForwarder
            //     uint32(orderPayload.destChain),
            //     getFastMCTPMintRecipient(
            //         uint32(orderPayload.destChain),
            //         middleToken
            //     ),
            //     middleToken,
            //     getFastMCTPCaller(uint32(orderPayload.destChain)),
            //     0, // maxFee
            //     0, // minFinalityThreshold
            //     hookData
            // );
        } else {
            revert UnsupportedDomain();
        }

        // TODO: Remove forwarder call
        // (bool success, ) = mayanForwarder.call(
        //     abi.encodeWithSignature(
        //         "swapAndForwardERC20(address,uint256,(uint256,uint256,uint8,bytes32,bytes32),address,bytes,address,uint256,address,bytes)",
        //         localToken,
        //         amount,
        //         emptyPermit,
        //         swapProtocol,
        //         swapData,
        //         middleToken,
        //         orderPayload.minAmountOut,
        //         targetProtocol,
        //         targetData
        //     )
        // );

        // if (!success) {
        //     revert ForwarderCallFailed();
        // }
    }

    function extractHookData(
        bytes memory cctpMsg
    ) internal pure returns (bytes memory) {
        uint256 hookDataLength = cctpMsg.length - HOOK_DATA_INDEX;
        bytes memory hookData = new bytes(hookDataLength);

        for (uint256 i = 0; i < hookDataLength; i++) {
            hookData[i] = cctpMsg[HOOK_DATA_INDEX + i];
        }

        return hookData;
    }

    function extractMessageBody(
        bytes memory cctpMsg
    ) internal pure returns (bytes memory) {
        // For MayanCircle messages, the structure may be different
        uint256 messageBodyIndex = 120; // Adjust based on the CCTP message structure
        uint256 messageBodyLength = cctpMsg.length - messageBodyIndex;
        bytes memory messageBody = new bytes(messageBodyLength);

        for (uint256 i = 0; i < messageBodyLength; i++) {
            messageBody[i] = cctpMsg[messageBodyIndex + i];
        }

        return messageBody;
    }

    function decodeHubPayloadBridge(
        bytes memory data
    ) internal pure returns (HubPayloadBridge memory) {
        require(
            data.length >= 1 && uint8(data[0]) == HUB_PAYLOAD_TYPE_BRIDGE,
            "Invalid bridge payload type"
        );

        HubPayloadBridge memory payload;
        payload.hubPayloadType = uint8(data[0]);

        uint256 offset = 1;

        // hubRelayerFee (uint64 - 8 bytes)
        payload.hubRelayerFee = uint64(bytes8(extractBytes(data, offset, 8)));
        offset += 8;

        // destAddress (bytes32 - 32 bytes)
        payload.destAddress = bytes32(extractBytes(data, offset, 32));
        offset += 32;

        // destChain (uint16 - 2 bytes)
        payload.destChain = uint16(bytes2(extractBytes(data, offset, 2)));
        offset += 2;

        // gasDrop (uint64 - 8 bytes)
        payload.gasDrop = uint64(bytes8(extractBytes(data, offset, 8)));
        offset += 8;

        // redeemFee (uint64 - 8 bytes)
        payload.redeemFee = uint64(bytes8(extractBytes(data, offset, 8)));
        offset += 8;

        // bridgePayloadType (uint8 - 1 byte)
        payload.bridgePayloadType = uint8(data[offset]);
        offset += 1;

        // referrerAddr (bytes32 - 32 bytes)
        payload.referrerAddr = bytes32(extractBytes(data, offset, 32));
        offset += 32;

        // customPayload (remaining bytes)
        if (offset < data.length) {
            uint256 customPayloadLength = data.length - offset;
            payload.customPayload = new bytes(customPayloadLength);
            for (uint256 i = 0; i < customPayloadLength; i++) {
                payload.customPayload[i] = data[offset + i];
            }
        }

        return payload;
    }

    function decodeHubPayloadOrder(
        bytes memory data
    ) internal pure returns (HubPayloadOrder memory) {
        require(
            data.length >= 1 && uint8(data[0]) == HUB_PAYLOAD_TYPE_ORDER,
            "Invalid order payload type"
        );

        HubPayloadOrder memory payload;
        payload.hubPayloadType = uint8(data[0]);

        uint256 offset = 1;

        // hubRelayerFee (uint64 - 8 bytes)
        payload.hubRelayerFee = uint64(bytes8(extractBytes(data, offset, 8)));
        offset += 8;

        // destAddress (bytes32 - 32 bytes)
        payload.destAddress = bytes32(extractBytes(data, offset, 32));
        offset += 32;

        // destChain (uint16 - 2 bytes)
        payload.destChain = uint16(bytes2(extractBytes(data, offset, 2)));
        offset += 2;

        // tokenOut (bytes32 - 32 bytes)
        payload.tokenOut = bytes32(extractBytes(data, offset, 32));
        offset += 32;

        // minAmountOut (uint64 - 8 bytes)
        payload.minAmountOut = uint64(bytes8(extractBytes(data, offset, 8)));
        offset += 8;

        // gasDrop (uint64 - 8 bytes)
        payload.gasDrop = uint64(bytes8(extractBytes(data, offset, 8)));
        offset += 8;

        // redeemFee (uint64 - 8 bytes)
        payload.redeemFee = uint64(bytes8(extractBytes(data, offset, 8)));
        offset += 8;

        // referrerAddr (bytes32 - 32 bytes)
        payload.referrerAddr = bytes32(extractBytes(data, offset, 32));
        offset += 32;

        // referrerBps (uint8 - 1 byte)
        if (offset < data.length) {
            payload.referrerBps = uint8(data[offset]);
        }

        return payload;
    }

    function extractBytes(
        bytes memory data,
        uint256 start,
        uint256 length
    ) internal pure returns (bytes memory) {
        require(start + length <= data.length, "Invalid slice parameters");

        bytes memory result = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = data[start + i];
        }

        return result;
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
        address localToken = fastMCTPTokenMessenger.localMinter().getLocalToken(
            sourceDomain,
            sourceToken
        );

        uint256 balance = IERC20(localToken).balanceOf(address(this));

        bool success = fastMCTPTokenMessenger
            .localMessageTransmitter()
            .receiveMessage(cctpMsg, cctpSigs);
        if (!success) {
            revert CctpReceiveFailed();
        }

        uint256 newBalance = IERC20(localToken).balanceOf(address(this));
        uint256 receivedAmount = newBalance - balance;

        return (localToken, receivedAmount);
    }

    function receiveMayanCircleMessage(
        bytes memory cctpMsg,
        bytes memory cctpSigs
    ) internal returns (address, uint256) {
        // CCTP_TOKEN_INDEX
        uint256 sourceTokenIndex = 120;
        // CCTP_DOMAIN_INDEX
        uint256 sourceIndex = 4;

        uint32 sourceDomain = cctpMsg.toUint32(sourceIndex);
        bytes32 sourceToken = cctpMsg.toBytes32(sourceTokenIndex);
        address localToken = mayanTokenMessenger.localMinter().getLocalToken(
            sourceDomain,
            sourceToken
        );

        uint256 balance = IERC20(localToken).balanceOf(address(this));

        bool success = mayanTokenMessenger
            .localMessageTransmitter()
            .receiveMessage(cctpMsg, cctpSigs);
        if (!success) {
            revert CctpReceiveFailed();
        }

        uint256 newBalance = IERC20(localToken).balanceOf(address(this));
        uint256 receivedAmount = newBalance - balance;

        return (localToken, receivedAmount);
    }

    function getFastMCTPMintRecipient(
        uint32 destDomain,
        address tokenIn
    ) internal view returns (bytes32) {
        bytes32 key = keccak256(abi.encodePacked(destDomain, tokenIn));
        bytes32 mintRecipient = fastMCTPMintRecipients[key];
        if (mintRecipient == bytes32(0)) {
            revert MintRecipientNotSet();
        }
        return mintRecipient;
    }

    function getMayanCircleMintRecipient(
        uint32 destDomain,
        address tokenIn
    ) internal view returns (bytes32) {
        bytes32 key = keccak256(abi.encodePacked(destDomain, tokenIn));
        bytes32 mintRecipient = mayanCircleMintRecipients[key];
        if (mintRecipient == bytes32(0)) {
            revert MintRecipientNotSet();
        }
        return mintRecipient;
    }

    function getFastMCTPCaller(
        uint32 destDomain
    ) internal view returns (bytes32) {
        bytes32 caller = fastMCTPDomainCallers[destDomain];
        if (caller == bytes32(0)) {
            revert CallerNotSet();
        }
        return caller;
    }

    function getMayanCircleCaller(
        uint32 destDomain
    ) internal view returns (bytes32) {
        bytes32 caller = mayanCircleDomainCallers[destDomain];
        if (caller == bytes32(0)) {
            revert CallerNotSet();
        }
        return caller;
    }

    function approveIfNeeded(
        address tokenAddr,
        address spender,
        uint256 amount,
        bool max
    ) internal {
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

    function setSupportedToken(address token, bool isSupported) external {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        supportedTokens[token] = isSupported;
    }

    function setFastMCTPDomain(uint32 domain, bool isSupported) external {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        isFastMCTPDomain[domain] = isSupported;
    }

    function setMayanCircleDomain(uint32 domain, bool isSupported) external {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        isMayanCircleDomain[domain] = isSupported;
    }

    function setFastMCTPMintRecipient(
        uint32 destDomain,
        address tokenIn,
        bytes32 mintRecipient
    ) external {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        bytes32 key = keccak256(abi.encodePacked(destDomain, tokenIn));
        if (fastMCTPMintRecipients[key] != bytes32(0)) {
            revert AlreadySet();
        }
        fastMCTPMintRecipients[key] = mintRecipient;
    }

    function setMayanCircleMintRecipient(
        uint32 destDomain,
        address tokenIn,
        bytes32 mintRecipient
    ) external {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        bytes32 key = keccak256(abi.encodePacked(destDomain, tokenIn));
        if (mayanCircleMintRecipients[key] != bytes32(0)) {
            revert AlreadySet();
        }
        mayanCircleMintRecipients[key] = mintRecipient;
    }

    function setFastMCTPDomainCaller(uint32 domain, bytes32 caller) external {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        if (fastMCTPDomainCallers[domain] != bytes32(0)) {
            revert AlreadySet();
        }
        fastMCTPDomainCallers[domain] = caller;
    }

    function setMayanCircleDomainCaller(
        uint32 domain,
        bytes32 caller
    ) external {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        if (mayanCircleDomainCallers[domain] != bytes32(0)) {
            revert AlreadySet();
        }
        mayanCircleDomainCallers[domain] = caller;
    }

    function setFeeManager(address _feeManager) external {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        feeManager = _feeManager;
    }

    function setMayanForwarder(address _mayanForwarder) external {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        mayanForwarder = _mayanForwarder;
    }

    function setPause(bool _paused) external {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        paused = _paused;
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

    receive() external payable {}
}
