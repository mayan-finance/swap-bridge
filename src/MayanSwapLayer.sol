// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "ExcessivelySafeCall/ExcessivelySafeCall.sol";
import "./libs/BytesLib.sol";
import "./interfaces/wormhole-ll/ITokenRouter.sol";
import "./interfaces/IWormhole.sol";
import {OrderResponse} from "./interfaces/wormhole-ll/ITokenRouterTypes.sol";

contract MayanSwapLayer is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BytesLib for bytes;
    using ExcessivelySafeCall for address;

    ITokenRouter public immutable tokenRouter;
    IWormhole public immutable wormhole;
    address public immutable localToken;
    address public feeManager;

    mapping(uint16 => bytes32) public domainToCaller;

    mapping(address => bool) public whitelistedSwapProtocols;
    mapping(address => bool) public whitelistedMsgSenders;

    address public guardian;
    address public nextGuardian;
    bool public paused;

    uint8 internal constant ETH_DECIMALS = 18;

    uint256 internal constant GAS_LIMIT_FEE_MANAGER = 1000000;

    event OrderFulfilled(bytes32 sender, uint16 senderChain, uint256 amount);
    event OrderRefunded(bytes32 sender, uint16 senderChain, uint256 amount);

    error Paused();
    error Unauthorized();
    error InvalidGasDrop();
    error InvalidRedeemFee();
    error InvalidPayload();
    error DeadlineViolation();
    error InvalidPayloadType();
    error EthTransferFailed();
    error InvalidAmountOut();
    error CallerNotSet();
    error InvalidRefundFee();
    error AlreadySet();
    error UnauthorizedSwapProtocol();
    error UnauthorizedMsgSender();
    error InsufficientWormholeFee();

    struct BridgePayload {
        uint8 payloadType;
        bytes32 destAddr;
        uint64 gasDrop;
        uint64 redeemFee;
        bytes32 referrerAddr;
        uint8 referrerBps;
        bytes32 customPayload;
    }

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

    modifier whenNotPaused() {
        if (paused) {
            revert Paused();
        }
        _;
    }

    constructor(address _tokenRouter, address _feeManager) {
        tokenRouter = ITokenRouter(_tokenRouter);
        wormhole = tokenRouter.wormhole();
        localToken = address(tokenRouter.orderToken());
        feeManager = _feeManager;
        guardian = msg.sender;
    }

    function bridge(
        uint64 amountIn,
        uint64 redeemFee,
        uint64 gasDrop,
        bytes32 destAddr,
        uint16 destDomain,
        bytes32 referrerAddress,
        uint8 referrerBps,
        uint8 payloadType,
        bytes memory customPayload
    ) external nonReentrant whenNotPaused {
        if (redeemFee >= amountIn) {
            revert InvalidRedeemFee();
        }

        if (payloadType != 1 && payloadType != 2) {
            revert InvalidPayloadType();
        }

        IERC20(localToken).safeTransferFrom(
            msg.sender,
            address(this),
            amountIn
        );
        approveIfNeeded(localToken, address(tokenRouter), amountIn, true);

        require(referrerBps <= 100, "ReferrerBps should be less than 100");

        bytes32 customPayloadHash;
        if (payloadType == 2) {
            customPayloadHash = keccak256(customPayload);
        }

        BridgePayload memory bridgePayload = BridgePayload({
            payloadType: payloadType,
            destAddr: destAddr,
            gasDrop: gasDrop,
            redeemFee: redeemFee,
            referrerAddr: referrerAddress,
            referrerBps: referrerBps,
            customPayload: customPayloadHash
        });

        sendWormholeLL(
            amountIn,
            destDomain,
            getCaller(destDomain),
            encodeBridgePayload(bridgePayload)
        );
    }

    function createOrder(
        uint64 amountIn,
        uint16 destDomain,
        OrderPayload memory orderPayload
    ) external nonReentrant whenNotPaused {
        if (orderPayload.redeemFee >= amountIn) {
            revert InvalidRedeemFee();
        }

        if (orderPayload.refundFee >= amountIn) {
            revert InvalidRefundFee();
        }

        if (orderPayload.payloadType != 3) {
            revert InvalidPayloadType();
        }

        require(
            orderPayload.referrerBps <= 100,
            "ReferrerBps should be less than 100"
        );

        if (orderPayload.tokenOut == bytes32(0) && orderPayload.gasDrop > 0) {
            revert InvalidGasDrop();
        }

        IERC20(localToken).safeTransferFrom(
            msg.sender,
            address(this),
            amountIn
        );
        approveIfNeeded(localToken, address(tokenRouter), amountIn, true);

        sendWormholeLL(
            amountIn,
            destDomain,
            getCaller(destDomain),
            encodeOrderPayload(orderPayload)
        );
    }

    function redeem(
        bytes memory encodedVM,
        bytes memory cctpMsg,
        bytes memory cctpSigs
    ) external payable nonReentrant {
        RedeemedFill memory redeemedFill = receiveWormholeLL(
            encodedVM,
            cctpMsg,
            cctpSigs
        );
        BridgePayload memory bridgePayload = recreateBridgePayload(
            redeemedFill.message
        );

        if (bridgePayload.payloadType != 1 && bridgePayload.payloadType != 2) {
            revert InvalidPayloadType();
        }

        address recipient = truncateAddress(bridgePayload.destAddr);
        if (bridgePayload.payloadType == 2 && msg.sender != recipient) {
            revert Unauthorized();
        }

        if (bridgePayload.redeemFee > redeemedFill.amount) {
            revert InvalidRedeemFee();
        }

        uint256 amount = redeemedFill.amount - uint256(bridgePayload.redeemFee);

        uint8 referrerBps = bridgePayload.referrerBps > 100
            ? 100
            : bridgePayload.referrerBps;
        uint8 protocolBps = safeCalcFastMCTPProtocolBps(
            bridgePayload.payloadType,
            amount,
            localToken,
            truncateAddress(bridgePayload.referrerAddr),
            referrerBps
        );
        protocolBps = protocolBps > 100 ? 100 : protocolBps;
        uint256 protocolAmount = (amount * protocolBps) / 10000;
        uint256 referrerAmount = (amount * referrerBps) / 10000;

        depositRelayerFee(
            msg.sender,
            localToken,
            uint256(bridgePayload.redeemFee)
        );
        IERC20(localToken).safeTransfer(
            recipient,
            amount - protocolAmount - referrerAmount
        );

        if (referrerAmount > 0) {
            try
                IERC20(localToken).transfer(
                    truncateAddress(bridgePayload.referrerAddr),
                    referrerAmount
                )
            {} catch {}
        }
        if (protocolAmount > 0) {
            try
                IERC20(localToken).transfer(
                    safeGetFeeCollector(),
                    protocolAmount
                )
            {} catch {}
        }

        if (bridgePayload.gasDrop > 0) {
            uint256 denormalizedGasDrop = deNormalizeAmount(
                bridgePayload.gasDrop,
                ETH_DECIMALS
            );
            if (msg.value != denormalizedGasDrop) {
                revert InvalidGasDrop();
            }
            payEth(recipient, denormalizedGasDrop, false);
        }
    }

    function fulfillOrder(
        bytes memory encodedVM,
        bytes memory cctpMsg,
        bytes memory cctpSigs,
        address swapProtocol,
        bytes memory swapData
    ) external payable nonReentrant {
        RedeemedFill memory redeemedFill = receiveWormholeLL(
            encodedVM,
            cctpMsg,
            cctpSigs
        );
        OrderPayload memory orderPayload = recreateOrderPayload(
            redeemedFill.message
        );
        if (orderPayload.payloadType != 3) {
            revert InvalidPayloadType();
        }

        if (orderPayload.deadline < block.timestamp) {
            revert DeadlineViolation();
        }

        if (!whitelistedSwapProtocols[swapProtocol]) {
            revert UnauthorizedSwapProtocol();
        }

        if (swapProtocol == address(tokenRouter)) {
            revert UnauthorizedSwapProtocol();
        }

        if (!whitelistedMsgSenders[msg.sender]) {
            revert UnauthorizedMsgSender();
        }

        if (orderPayload.redeemFee > 0) {
            IERC20(localToken).safeTransfer(msg.sender, orderPayload.redeemFee);
        }

        uint256 whLLAmount = redeemedFill.amount -
            uint256(orderPayload.redeemFee);

        (uint256 referrerAmount, uint256 protocolAmount) = getFeeAmounts(
            orderPayload,
            whLLAmount
        );

        if (referrerAmount > 0) {
            try
                IERC20(localToken).transfer(
                    truncateAddress(orderPayload.referrerAddr),
                    referrerAmount
                )
            {} catch {}
        }

        if (protocolAmount > 0) {
            try
                IERC20(localToken).transfer(
                    safeGetFeeCollector(),
                    protocolAmount
                )
            {} catch {}
        }

        address tokenOut = truncateAddress(orderPayload.tokenOut);
        require(tokenOut != localToken, "tokenOut cannot be localToken");
        approveIfNeeded(
            localToken,
            swapProtocol,
            whLLAmount - protocolAmount - referrerAmount,
            false
        );

        uint256 amountOut;
        if (tokenOut == address(0)) {
            amountOut = address(this).balance;
        } else {
            amountOut = IERC20(tokenOut).balanceOf(address(this));
        }

        (bool swapSuccess, bytes memory swapReturn) = swapProtocol.call{
            value: 0
        }(swapData);
        require(swapSuccess, string(swapReturn));

        if (tokenOut == address(0)) {
            amountOut = address(this).balance - amountOut;
        } else {
            amountOut = IERC20(tokenOut).balanceOf(address(this)) - amountOut;
        }

        uint8 decimals;
        if (tokenOut == address(0)) {
            decimals = ETH_DECIMALS;
        } else {
            decimals = decimalsOf(tokenOut);
        }

        makePayments(orderPayload, tokenOut, amountOut);

        if (
            amountOut < deNormalizeAmount(orderPayload.amountOutMin, decimals)
        ) {
            revert InvalidAmountOut();
        }

        logFulfilled(redeemedFill, amountOut);
    }

    function refund(
        bytes memory encodedVM,
        bytes memory cctpMsg,
        bytes memory cctpSigs
    ) external payable nonReentrant {
        RedeemedFill memory redeemedFill = receiveWormholeLL(
            encodedVM,
            cctpMsg,
            cctpSigs
        );
        OrderPayload memory orderPayload = recreateOrderPayload(
            redeemedFill.message
        );
        if (orderPayload.payloadType != 3) {
            revert InvalidPayloadType();
        }

        if (
            orderPayload.deadline >= block.timestamp &&
            address(localToken) != truncateAddress(orderPayload.tokenOut)
        ) {
            revert DeadlineViolation();
        }

        uint256 gasDrop = deNormalizeAmount(orderPayload.gasDrop, ETH_DECIMALS);
        if (msg.value != gasDrop) {
            revert InvalidGasDrop();
        }

        address destAddr = truncateAddress(orderPayload.destAddr);
        if (gasDrop > 0) {
            payEth(destAddr, gasDrop, false);
        }

        IERC20(localToken).safeTransfer(msg.sender, orderPayload.refundFee);
        IERC20(localToken).safeTransfer(
            destAddr,
            redeemedFill.amount - orderPayload.refundFee
        );

        emit OrderRefunded(
            redeemedFill.sender,
            redeemedFill.senderChain,
            redeemedFill.amount
        );
    }

    function receiveWormholeLL(
        bytes memory encodedVM,
        bytes memory cctpMsg,
        bytes memory cctpSigs
    ) internal returns (RedeemedFill memory) {
        OrderResponse memory orderResponse = OrderResponse({
            encodedWormholeMessage: encodedVM,
            circleBridgeMessage: cctpMsg,
            circleAttestation: cctpSigs
        });
        RedeemedFill memory redeemedFill = tokenRouter.redeemFill(
            orderResponse
        );
        return redeemedFill;
    }

    function sendWormholeLL(
        uint64 amountIn,
        uint16 destDomain,
        bytes32 redeemer,
        bytes memory redeemerMessage
    ) internal {
        uint256 fee = wormhole.messageFee();
        if (msg.value < fee) {
            revert InsufficientWormholeFee();
        }

        tokenRouter.placeMarketOrder{value: fee}(
            amountIn,
            destDomain,
            redeemer,
            redeemerMessage
        );
    }

    function makePayments(
        OrderPayload memory orderPayload,
        address tokenOut,
        uint256 amount
    ) internal {
        address destAddr = truncateAddress(orderPayload.destAddr);
        if (tokenOut == address(0)) {
            payEth(destAddr, amount, true);
        } else {
            if (orderPayload.gasDrop > 0) {
                uint256 gasDrop = deNormalizeAmount(
                    orderPayload.gasDrop,
                    ETH_DECIMALS
                );
                if (msg.value != gasDrop) {
                    revert InvalidGasDrop();
                }
                payEth(destAddr, gasDrop, false);
            }
            IERC20(tokenOut).safeTransfer(destAddr, amount);
        }
    }

    function logFulfilled(
        RedeemedFill memory redeemedFill,
        uint256 amount
    ) internal {
        emit OrderFulfilled(
            redeemedFill.sender,
            redeemedFill.senderChain,
            amount
        );
    }

    function recreateBridgePayload(
        bytes memory payload
    ) internal pure returns (BridgePayload memory) {
        return
            BridgePayload({
                payloadType: payload.toUint8(0),
                destAddr: payload.toBytes32(1),
                gasDrop: payload.toUint64(33),
                redeemFee: payload.toUint64(41),
                referrerAddr: payload.toBytes32(49),
                referrerBps: payload.toUint8(81),
                customPayload: payload.toBytes32(82)
            });
    }

    function encodeBridgePayload(
        BridgePayload memory bridgePayload
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                bridgePayload.payloadType,
                bridgePayload.destAddr,
                bridgePayload.gasDrop,
                bridgePayload.redeemFee,
                bridgePayload.referrerAddr,
                bridgePayload.referrerBps,
                bridgePayload.customPayload
            );
    }

    function recreateOrderPayload(
        bytes memory payload
    ) internal pure returns (OrderPayload memory) {
        return
            OrderPayload({
                payloadType: payload.toUint8(0),
                destAddr: payload.toBytes32(1),
                tokenOut: payload.toBytes32(33),
                amountOutMin: payload.toUint64(65),
                gasDrop: payload.toUint64(73),
                redeemFee: payload.toUint64(81),
                refundFee: payload.toUint64(89),
                deadline: payload.toUint64(97),
                referrerAddr: payload.toBytes32(105),
                referrerBps: payload.toUint8(137)
            });
    }

    function encodeOrderPayload(
        OrderPayload memory orderPayload
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                orderPayload.payloadType,
                orderPayload.destAddr,
                orderPayload.tokenOut,
                orderPayload.amountOutMin,
                orderPayload.gasDrop,
                orderPayload.redeemFee,
                orderPayload.refundFee,
                orderPayload.deadline,
                orderPayload.referrerAddr,
                orderPayload.referrerBps
            );
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

    function payEth(address to, uint256 amount, bool revertOnFailure) internal {
        (bool success, ) = payable(to).call{value: amount}("");
        if (revertOnFailure) {
            if (success != true) {
                revert EthTransferFailed();
            }
        }
    }

    function getFeeAmounts(
        OrderPayload memory orderPayload,
        uint256 whLLAmount
    ) internal returns (uint256 referrerAmount, uint256 protocolAmount) {
        uint8 referrerBps = orderPayload.referrerBps > 100
            ? 100
            : orderPayload.referrerBps;
        referrerAmount = (whLLAmount * referrerBps) / 10000;
        uint8 protocolBps = safeCalcFastMCTPProtocolBps(
            orderPayload.payloadType,
            whLLAmount,
            truncateAddress(orderPayload.tokenOut),
            truncateAddress(orderPayload.referrerAddr),
            referrerBps
        );
        protocolBps = protocolBps > 100 ? 100 : protocolBps;
        protocolAmount = (whLLAmount * protocolBps) / 10000;

        return (referrerAmount, protocolAmount);
    }

    function safeCalcFastMCTPProtocolBps(
        uint8 payloadType,
        uint256 whLLAmount,
        address tokenOut,
        address referrerAddr,
        uint8 referrerBps
    ) internal returns (uint8) {
        (, bytes memory returnData) = address(feeManager).excessivelySafeCall(
            GAS_LIMIT_FEE_MANAGER, // _gas
            0, // _value
            32, // _maxCopy
            abi.encodeWithSignature(
                "calcFastMCTPProtocolBps(uint8,address,uint256,address,address,uint8)",
                payloadType,
                localToken,
                whLLAmount,
                tokenOut,
                referrerAddr,
                referrerBps
            )
        );

        uint256 protocolBps;
        if (returnData.length < 32) {
            protocolBps = 0;
        } else {
            protocolBps = abi.decode(returnData, (uint256));
        }
        return uint8(protocolBps);
    }

    function safeGetFeeCollector() internal returns (address) {
        (, bytes memory returnData) = address(feeManager).excessivelySafeCall(
            GAS_LIMIT_FEE_MANAGER, // _gas
            0, // _value
            32, // _maxCopy
            abi.encodeWithSignature("feeCollector()")
        );

        uint256 feeCollector;
        if (returnData.length < 32) {
            feeCollector = 0;
        } else {
            feeCollector = abi.decode(returnData, (uint256));
        }
        return address(uint160(feeCollector));
    }

    function depositRelayerFee(
        address relayer,
        address token,
        uint256 amount
    ) internal {
        try IERC20(token).transfer(address(feeManager), amount) {} catch {}

        address(feeManager).excessivelySafeCall(
            GAS_LIMIT_FEE_MANAGER, // _gas
            0, // _value
            32, // _maxCopy
            abi.encodeWithSignature(
                "depositFee(address,address,uint256)",
                relayer,
                token,
                amount
            )
        );
    }

    function getCaller(
        uint16 destDomain
    ) internal view returns (bytes32 caller) {
        caller = domainToCaller[destDomain];
        if (caller == bytes32(0)) {
            revert CallerNotSet();
        }
        return caller;
    }

    function setDomainCallers(uint16 domain, bytes32 caller) public {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        if (domainToCaller[domain] != bytes32(0)) {
            revert AlreadySet();
        }
        domainToCaller[domain] = caller;
    }

    function setWhitelistedSwapProtocols(
        address protocol,
        bool isWhitelisted
    ) public {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        whitelistedSwapProtocols[protocol] = isWhitelisted;
    }

    function setWhitelistedMsgSenders(
        address sender,
        bool isWhitelisted
    ) public {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        whitelistedMsgSenders[sender] = isWhitelisted;
    }

    function decimalsOf(address token) internal view returns (uint8) {
        (, bytes memory queriedDecimals) = token.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        return abi.decode(queriedDecimals, (uint8));
    }

    function deNormalizeAmount(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256) {
        if (decimals > 8) {
            amount *= 10 ** (decimals - 8);
        }
        return amount;
    }

    function truncateAddress(bytes32 b) internal pure returns (address) {
        return address(uint160(uint256(b)));
    }

    function setFeeManager(address _feeManager) public {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        feeManager = _feeManager;
    }

    function rescueToken(address token, uint256 amount, address to) public {
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

    function rescueRedeem(
        bytes memory encodedVM,
        bytes memory cctpMsg,
        bytes memory cctpSigs
    ) public {
        receiveWormholeLL(encodedVM, cctpMsg, cctpSigs);
    }

    function setPause(bool _pause) public {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        paused = _pause;
    }

    function changeGuardian(address newGuardian) public {
        if (msg.sender != guardian) {
            revert Unauthorized();
        }
        nextGuardian = newGuardian;
    }

    function claimGuardian() public {
        if (msg.sender != nextGuardian) {
            revert Unauthorized();
        }
        guardian = nextGuardian;
    }

    receive() external payable {}
}
