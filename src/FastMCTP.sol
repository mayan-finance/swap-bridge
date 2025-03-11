// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "ExcessivelySafeCall/ExcessivelySafeCall.sol";
import "./libs/BytesLib.sol";
import "./interfaces/CCTP/v2/ITokenMessengerV2.sol";

contract FastMCTP is ReentrancyGuard {
	using SafeERC20 for IERC20;
	using BytesLib for bytes;
	using ExcessivelySafeCall for address;

	ITokenMessengerV2 public immutable cctpTokenMessengerV2;
	address public feeManager;

	mapping(bytes32 => bytes32) public keyToMintRecipient;
	mapping(uint32 => bytes32) public domainToCaller;

	mapping(address => bool) public whitelistedSwapProtocols;
	mapping(address => bool) public whitelistedMsgSenders;

	address public guardian;
	address public nextGuardian;
	bool public paused;

	uint8 internal constant ETH_DECIMALS = 18;

	uint256 internal constant CCTPV2_SOURCE_DOMAIN_INDEX = 4;
	uint256 internal constant CCTPV2_DESTINATION_DOMAIN_INDEX = 8;
	uint256 internal constant CCTPV2_NONCE_INDEX = 12;
	uint256 internal constant CCTPV2_DETINATION_CALLER_INDEX = 108;
	uint256 internal constant CCTPV2_MESSAGE_BODY_INDEX = 148;
	uint256 internal constant CCTPV2_SOURCE_TOKEN_INDEX = CCTPV2_MESSAGE_BODY_INDEX + 4;
	uint256 internal constant CCTPV2_MINT_RECIPIENT_INDEX = CCTPV2_MESSAGE_BODY_INDEX + 36;
	uint256 internal constant HOOK_DATA_INDEX = CCTPV2_MESSAGE_BODY_INDEX + 228;

	uint256 internal constant GAS_LIMIT_FEE_MANAGER = 1000000;

	event OrderFulfilled(uint32 sourceDomain, bytes32 sourceNonce, uint256 amount);
	event OrderRefunded(uint32 sourceDomain, bytes32 sourceNonce, uint256 amount);

	error Paused();
	error Unauthorized();
	error CctpReceiveFailed();
	error InvalidGasDrop();
	error InvalidMintRecipient();
	error InvalidRedeemFee();
	error InvalidPayload();
	error DeadlineViolation();
	error InvalidAddress();
	error InvalidPayloadType();
	error EthTransferFailed();
	error InvalidAmountOut();
	error MintRecipientNotSet();
	error CallerNotSet();
	error InvalidRefundFee();
	error AlreadySet();
	error UnauthorizedSwapProtocol();
	error UnauthorizedMsgSender();

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

	modifier checkRecipient(bytes memory cctpMsg) {
		if (truncateAddress(cctpMsg.toBytes32(CCTPV2_MINT_RECIPIENT_INDEX)) != address(this)) {
			revert InvalidMintRecipient();
		}
		_;
	}

	modifier whenNotPaused() {
		if (paused) {
			revert Paused();
		}
		_;
	}

	constructor(
		address _cctpTokenMessengerV2,
		address _feeManager
	) {
		cctpTokenMessengerV2 = ITokenMessengerV2(_cctpTokenMessengerV2);
		feeManager = _feeManager;
		guardian = msg.sender;
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
	) external nonReentrant whenNotPaused {
		if (redeemFee + circleMaxFee >= amountIn) {
			revert InvalidRedeemFee();
		}

		if (payloadType != 1 && payloadType != 2) {
			revert InvalidPayloadType();
		}

		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		approveIfNeeded(tokenIn, address(cctpTokenMessengerV2), amountIn, true);

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

		sendCctp(tokenIn, amountIn, destDomain, circleMaxFee, minFinalityThreshold, encodeBridgePayload(bridgePayload));
	}

	function createOrder(
		address tokenIn,
		uint256 amountIn,
		uint256 circleMaxFee,
		uint32 destDomain,
		uint32 minFinalityThreshold,
		OrderPayload memory orderPayload
	) external nonReentrant whenNotPaused {
		if (orderPayload.redeemFee + circleMaxFee >= amountIn) {
			revert InvalidRedeemFee();
		}

		if (orderPayload.refundFee + circleMaxFee >= amountIn) {
			revert InvalidRefundFee();
		}

		if (orderPayload.payloadType != 3) {
			revert InvalidPayloadType();
		}

		require(orderPayload.referrerBps <= 100, "ReferrerBps should be less than 100");

		if (orderPayload.tokenOut == bytes32(0) && orderPayload.gasDrop > 0) {
			revert InvalidGasDrop();
		}

		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		approveIfNeeded(tokenIn, address(cctpTokenMessengerV2), amountIn, true);

		sendCctp(tokenIn, amountIn, destDomain, circleMaxFee, minFinalityThreshold, encodeOrderPayload(orderPayload));
	}

	function redeem(
		bytes memory cctpMsg,
		bytes memory cctpSigs
	) external nonReentrant payable checkRecipient(cctpMsg) {

		BridgePayload memory bridgePayload = recreateBridgePayload(cctpMsg);

		if (bridgePayload.payloadType != 1 && bridgePayload.payloadType != 2) {
			revert InvalidPayloadType();
		}

		address recipient = truncateAddress(bridgePayload.destAddr);
		if (bridgePayload.payloadType == 2 && msg.sender != recipient) {
			revert Unauthorized();
		}

		(address localToken, uint256 amount) = receiveCctp(cctpMsg, cctpSigs);

		if (bridgePayload.redeemFee > amount) {
			revert InvalidRedeemFee();
		}

		amount = amount - uint256(bridgePayload.redeemFee);

		uint8 referrerBps = bridgePayload.referrerBps > 100 ? 100 : bridgePayload.referrerBps;
		uint8 protocolBps = safeCalcFastMCTPProtocolBps(
			bridgePayload.payloadType,
			localToken,
			amount,
			localToken,
			truncateAddress(bridgePayload.referrerAddr),
			referrerBps
		);
		protocolBps = protocolBps > 100 ? 100 : protocolBps;
		uint256 protocolAmount = amount * protocolBps / 10000;
		uint256 referrerAmount = amount * referrerBps / 10000;

		depositRelayerFee(msg.sender, localToken, uint256(bridgePayload.redeemFee));
		IERC20(localToken).safeTransfer(recipient, amount - protocolAmount - referrerAmount);

		if (referrerAmount > 0) {
			try IERC20(localToken).transfer(truncateAddress(bridgePayload.referrerAddr), referrerAmount) {} catch {}
		}
		if (protocolAmount > 0) {
			try IERC20(localToken).transfer(safeGetFeeCollector(), protocolAmount) {} catch {}
		}

		if (bridgePayload.gasDrop > 0) {
			uint256 denormalizedGasDrop = deNormalizeAmount(bridgePayload.gasDrop, ETH_DECIMALS);
			if (msg.value != denormalizedGasDrop) {
				revert InvalidGasDrop();
			}
			payEth(recipient, denormalizedGasDrop, false);
		}
	}

	function fulfillOrder(
		bytes memory cctpMsg,
		bytes memory cctpSigs,
		address swapProtocol,
		bytes memory swapData
	) external nonReentrant payable checkRecipient(cctpMsg) {
		OrderPayload memory orderPayload = recreateOrderPayload(cctpMsg);
		if (orderPayload.payloadType != 3) {
			revert InvalidPayloadType();
		}

		if (orderPayload.deadline < block.timestamp) {
			revert DeadlineViolation();
		}

		if (!whitelistedSwapProtocols[swapProtocol]) {
			revert UnauthorizedSwapProtocol();
		}

		if (swapProtocol == address(cctpTokenMessengerV2) || swapProtocol == address(cctpTokenMessengerV2.localMessageTransmitter())) {
			revert UnauthorizedSwapProtocol();
		}

		if (!whitelistedMsgSenders[msg.sender]) {
			revert UnauthorizedMsgSender();
		}

		(address localToken, uint256 cctpAmount) = receiveCctp(cctpMsg, cctpSigs);

		if (orderPayload.redeemFee > 0) {
			IERC20(localToken).safeTransfer(msg.sender, orderPayload.redeemFee);
		}

		cctpAmount = cctpAmount - uint256(orderPayload.redeemFee);

		(uint256 referrerAmount, uint256 protocolAmount) = getFeeAmounts(orderPayload, cctpAmount, localToken);

		if (referrerAmount > 0) {
			try IERC20(localToken).transfer(truncateAddress(orderPayload.referrerAddr), referrerAmount) {} catch {}
		}

		if (protocolAmount > 0) {
			try IERC20(localToken).transfer(safeGetFeeCollector(), protocolAmount) {} catch {}
		}

		address tokenOut = truncateAddress(orderPayload.tokenOut);
		require(tokenOut != localToken, "tokenOut cannot be localToken");
		approveIfNeeded(localToken, swapProtocol, cctpAmount - protocolAmount - referrerAmount, false);

		uint256 amountOut;
		if (tokenOut == address(0)) {
			amountOut = address(this).balance;
		} else {
			amountOut = IERC20(tokenOut).balanceOf(address(this));
		}

		(bool swapSuccess, bytes memory swapReturn) = swapProtocol.call{value: 0}(swapData);
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

		makePayments(
			orderPayload,
			tokenOut,
			amountOut
		);

		if (amountOut < deNormalizeAmount(orderPayload.amountOutMin, decimals)) {
			revert InvalidAmountOut();
		}

		logFulfilled(cctpMsg, amountOut);
	}

	function refund(
		bytes memory cctpMsg,
		bytes memory cctpSigs
	) external nonReentrant payable checkRecipient(cctpMsg) {
		(address localToken, uint256 amount) = receiveCctp(cctpMsg, cctpSigs);

		OrderPayload memory orderPayload = recreateOrderPayload(cctpMsg);
		if (orderPayload.payloadType != 3) {
			revert InvalidPayloadType();
		}

		if (orderPayload.deadline >= block.timestamp && localToken != truncateAddress(orderPayload.tokenOut)) {
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
		IERC20(localToken).safeTransfer(destAddr, amount - orderPayload.refundFee);

		emit OrderRefunded(cctpMsg.toUint32(CCTPV2_SOURCE_DOMAIN_INDEX), cctpMsg.toBytes32(CCTPV2_NONCE_INDEX), amount);
	}

	function receiveCctp(bytes memory cctpMsg, bytes memory cctpSigs) internal returns (address, uint256) {
		uint32 cctpSourceDomain = cctpMsg.toUint32(CCTPV2_SOURCE_DOMAIN_INDEX);
		bytes32 cctpSourceToken = cctpMsg.toBytes32(CCTPV2_SOURCE_TOKEN_INDEX);
		address localToken = cctpTokenMessengerV2.localMinter().getLocalToken(cctpSourceDomain, cctpSourceToken);

		uint256 amount = IERC20(localToken).balanceOf(address(this));
		bool success = cctpTokenMessengerV2.localMessageTransmitter().receiveMessage(cctpMsg, cctpSigs);
		if (!success) {
			revert CctpReceiveFailed();
		}
		amount = IERC20(localToken).balanceOf(address(this)) - amount;
		return (localToken, amount);
	}

	function sendCctp(
		address tokenIn,
		uint256 amountIn,
		uint32 destDomain,
		uint256 maxFee,
		uint32 minFinalityThreshold,
		bytes memory hookData
	) internal {
		cctpTokenMessengerV2.depositForBurnWithHook(
			amountIn,
			destDomain,
			getMintRecipient(destDomain, tokenIn),
			tokenIn,
			getCaller(destDomain),
			maxFee,
			minFinalityThreshold,
			hookData
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
				uint256 gasDrop = deNormalizeAmount(orderPayload.gasDrop, ETH_DECIMALS);
				if (msg.value != gasDrop) {
					revert InvalidGasDrop();
				}
				payEth(destAddr, gasDrop, false);
			}
			IERC20(tokenOut).safeTransfer(destAddr, amount);
		}
	}

	function logFulfilled(bytes memory cctpMsg, uint256 amount) internal {
		emit OrderFulfilled(cctpMsg.toUint32(CCTPV2_SOURCE_DOMAIN_INDEX), cctpMsg.toBytes32(CCTPV2_NONCE_INDEX), amount);
	}

	function recreateBridgePayload(
		bytes memory cctpMsg
	) internal pure returns (BridgePayload memory) {
		return BridgePayload({
			payloadType: cctpMsg.toUint8(HOOK_DATA_INDEX),
			destAddr: cctpMsg.toBytes32(HOOK_DATA_INDEX + 1),
			gasDrop: cctpMsg.toUint64(HOOK_DATA_INDEX + 33),
			redeemFee: cctpMsg.toUint64(HOOK_DATA_INDEX + 41),
			referrerAddr: cctpMsg.toBytes32(HOOK_DATA_INDEX + 49),
			referrerBps: cctpMsg.toUint8(HOOK_DATA_INDEX + 81),
			customPayload: cctpMsg.toBytes32(HOOK_DATA_INDEX + 82)
		});
	}

	function encodeBridgePayload(BridgePayload memory bridgePayload) internal pure returns (bytes memory) {
		return abi.encodePacked(
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
		bytes memory cctpMsg
	) internal pure returns (OrderPayload memory) {
		return OrderPayload({
			payloadType: cctpMsg.toUint8(HOOK_DATA_INDEX),
			destAddr: cctpMsg.toBytes32(HOOK_DATA_INDEX + 1),
			tokenOut: cctpMsg.toBytes32(HOOK_DATA_INDEX + 33),
			amountOutMin: cctpMsg.toUint64(HOOK_DATA_INDEX + 65),
			gasDrop: cctpMsg.toUint64(HOOK_DATA_INDEX + 73),
			redeemFee: cctpMsg.toUint64(HOOK_DATA_INDEX + 81),
			refundFee: cctpMsg.toUint64(HOOK_DATA_INDEX + 89),
			deadline: cctpMsg.toUint64(HOOK_DATA_INDEX + 97),
			referrerAddr: cctpMsg.toBytes32(HOOK_DATA_INDEX + 105),
			referrerBps: cctpMsg.toUint8(HOOK_DATA_INDEX + 137)
		});
	}

	function encodeOrderPayload(OrderPayload memory orderPayload) internal pure returns (bytes memory) {
		return abi.encodePacked(
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

	function payEth(address to, uint256 amount, bool revertOnFailure) internal {
		(bool success, ) = payable(to).call{value: amount}('');
		if (revertOnFailure) {
			if (success != true) {
				revert EthTransferFailed();
			}
		}
	}

	function getFeeAmounts(OrderPayload memory orderPayload, uint256 cctpAmount, address localToken) internal returns (uint256 referrerAmount, uint256 protocolAmount) {
		uint8 referrerBps = orderPayload.referrerBps > 100 ? 100 : orderPayload.referrerBps;
		referrerAmount = cctpAmount * referrerBps / 10000;
		uint8 protocolBps = safeCalcFastMCTPProtocolBps(
			orderPayload.payloadType,
			localToken,
			cctpAmount,
			truncateAddress(orderPayload.tokenOut),
			truncateAddress(orderPayload.referrerAddr),
			referrerBps
		);
		protocolBps = protocolBps > 100 ? 100 : protocolBps;
		protocolAmount = cctpAmount * protocolBps / 10000;

		return (referrerAmount, protocolAmount);
	}

    function safeCalcFastMCTPProtocolBps(
        uint8 payloadType,
        address localToken,
        uint256 cctpAmount,
        address tokenOut,
        address referrerAddr,
        uint8 referrerBps
    ) internal returns (uint8) {
		(, bytes memory returnData) = address(feeManager)
            .excessivelySafeCall(
                GAS_LIMIT_FEE_MANAGER, // _gas
                0, // _value
                32, // _maxCopy
                abi.encodeWithSignature(
                    "calcFastMCTPProtocolBps(uint8,address,uint256,address,address,uint8)",
                    payloadType,
                    localToken,
                    cctpAmount,
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
        (, bytes memory returnData) = address(feeManager)
			.excessivelySafeCall(
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

	function depositRelayerFee(address relayer, address token, uint256 amount) internal {
		try IERC20(token).transfer(address(feeManager), amount) {} catch {}

		address(feeManager)
			.excessivelySafeCall(
				GAS_LIMIT_FEE_MANAGER, // _gas
				0, // _value
				32, // _maxCopy
				abi.encodeWithSignature("depositFee(address,address,uint256)", relayer, token, amount)
			);
	}

	function getMintRecipient(uint32 destDomain, address tokenIn) internal view returns (bytes32) {
		bytes32 mintRecepient = keyToMintRecipient[keccak256(abi.encodePacked(destDomain, tokenIn))];
		if (mintRecepient == bytes32(0)) {
			revert MintRecipientNotSet();
		}
		return mintRecepient;
	}

	function setMintRecipient(uint32 destDomain, address tokenIn, bytes32 mintRecipient) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		bytes32 key = keccak256(abi.encodePacked(destDomain, tokenIn));
		if (keyToMintRecipient[key] != bytes32(0)) {
			revert AlreadySet();
		}
		keyToMintRecipient[key] = mintRecipient;
	}

	function getCaller(uint32 destDomain) internal view returns (bytes32 caller) {
		caller = domainToCaller[destDomain];
		if (caller == bytes32(0)) {
			revert CallerNotSet();
		}
		return caller;
	}

	function setDomainCallers(uint32 domain, bytes32 caller) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		if (domainToCaller[domain] != bytes32(0)) {
			revert AlreadySet();
		}
		domainToCaller[domain] = caller;
	}

	function setWhitelistedSwapProtocols(address protocol, bool isWhitelisted) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		whitelistedSwapProtocols[protocol] = isWhitelisted;
	}

	function setWhitelistedMsgSenders(address sender, bool isWhitelisted) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		whitelistedMsgSenders[sender] = isWhitelisted;
	}

	function decimalsOf(address token) internal view returns(uint8) {
		(,bytes memory queriedDecimals) = token.staticcall(abi.encodeWithSignature('decimals()'));
		return abi.decode(queriedDecimals, (uint8));
	}

	function deNormalizeAmount(uint256 amount, uint8 decimals) internal pure returns(uint256) {
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

	function rescueRedeem(bytes memory cctpMsg, bytes memory cctpSigs) public {
		if (truncateAddress(cctpMsg.toBytes32(CCTPV2_MINT_RECIPIENT_INDEX)) == address(this)) {
			revert Unauthorized();
		}

		bool success = cctpTokenMessengerV2.localMessageTransmitter().receiveMessage(cctpMsg, cctpSigs);
		if (!success) {
			revert CctpReceiveFailed();
		}
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
