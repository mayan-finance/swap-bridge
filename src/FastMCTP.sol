// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libs/BytesLib.sol";
import "./interfaces/CCTP/v2/ITokenMessengerV2.sol";
import "./interfaces/IFeeManager.sol";

contract FastMCTP is ReentrancyGuard {
	using SafeERC20 for IERC20;
	using BytesLib for bytes;

	ITokenMessengerV2 public immutable cctpTokenMessengerV2;
	IFeeManager public feeManager;

	address public guardian;
	address nextGuardian;

	uint8 constant ETH_DECIMALS = 18;

	uint256 constant CCTPV2_SOURCE_DOMAIN_INDEX = 4;
	uint256 constant CCTPV2_DESTINATION_DOMAIN_INDEX = 8;
	uint256 constant CCTPV2_NONCE_INDEX = 12;
	uint256 constant CCTPV2_DETINATION_CALLER_INDEX = 108;
	uint256 constant CCTPV2_MESSAGE_BODY_INDEX = 148;
	uint256 constant CCTPV2_SOURCE_TOKEN_INDEX = CCTPV2_MESSAGE_BODY_INDEX + 4;
	uint256 constant CCTPV2_MINT_RECIPIENT_INDEX = CCTPV2_MESSAGE_BODY_INDEX + 36;
	uint256 constant HOOK_DATA_INDEX = CCTPV2_MESSAGE_BODY_INDEX + 228;

	event OrderFulfilled(uint32 sourceDomain, bytes32 sourceNonce, uint256 amount);
	event OrderRefunded(uint32 sourceDomain, bytes32 sourceNonce, uint256 amount);

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

	constructor(
		address _cctpTokenMessengerV2,
		address _feeManager
	) {
		cctpTokenMessengerV2 = ITokenMessengerV2(_cctpTokenMessengerV2);
		feeManager = IFeeManager(_feeManager);
		guardian = msg.sender;
	}

	function redeemWithFee(
		bytes memory cctpMsg,
		bytes memory cctpSigs
	) external nonReentrant payable {
		if (truncateAddress(cctpMsg.toBytes32(CCTPV2_MINT_RECIPIENT_INDEX)) != address(this)) {
			revert InvalidMintRecipient();
		}

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

		depositRelayerFee(msg.sender, localToken, uint256(bridgePayload.redeemFee));
		IERC20(localToken).safeTransfer(recipient, amount - uint256(bridgePayload.redeemFee));

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
	) external nonReentrant payable {
		OrderPayload memory orderPayload = recreateOrderPayload(cctpMsg);
		if (orderPayload.payloadType != 3) {
			revert InvalidPayloadType();
		}

		if (orderPayload.deadline < block.timestamp) {
			revert DeadlineViolation();
		}

		// TODO: whitelist swapProtocol
		// TODO: swap protocol shouldn't be messageTransmitter or tokenMessenger
			
		(address localToken, uint256 cctpAmount) = receiveCctp(cctpMsg, cctpSigs);

		if (orderPayload.redeemFee > 0) {
			IERC20(localToken).safeTransfer(msg.sender, orderPayload.redeemFee);
		}

		address tokenOut = truncateAddress(orderPayload.tokenOut);
		require(tokenOut != localToken, "tokenOut cannot be localToken");
		approveIfNeeded(localToken, swapProtocol, cctpAmount - uint256(orderPayload.redeemFee), false);

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

		uint256 promisedAmount = deNormalizeAmount(orderPayload.amountOutMin, decimals);
		if (amountOut < promisedAmount) {
			revert InvalidAmountOut();
		}

		makePayments(
			orderPayload,
			tokenOut,
			amountOut
		);

		emit OrderFulfilled(cctpMsg.toUint32(CCTPV2_SOURCE_DOMAIN_INDEX), cctpMsg.toBytes32(CCTPV2_NONCE_INDEX), amountOut);
	}

	function refund(
		bytes memory cctpMsg,
		bytes memory cctpSigs
	) external nonReentrant payable {
		(address localToken, uint256 amount) = receiveCctp(cctpMsg, cctpSigs);

		OrderPayload memory orderPayload = recreateOrderPayload(cctpMsg);

		if (orderPayload.deadline >= block.timestamp) {
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

	function makePayments(
		OrderPayload memory orderPayload,
		address tokenOut,
		uint256 amount
	) internal {
		address referrerAddr = truncateAddress(orderPayload.referrerAddr);
		uint256 referrerAmount = 0;
		if (referrerAddr != address(0) && orderPayload.referrerBps != 0) {
			referrerAmount = amount * orderPayload.referrerBps / 10000;
		}

		// TODO: add protocol fee
		uint256 protocolAmount = 0;
		// if (orderPayload.protocolBps != 0) {
		// 	protocolAmount = amount * orderPayload.protocolBps / 10000;
		// }

		address destAddr = truncateAddress(orderPayload.destAddr);
		if (tokenOut == address(0)) {
			if (referrerAmount > 0) {
				payEth(referrerAddr, referrerAmount, false);
			}
			if (protocolAmount > 0) {
				payEth(feeManager.feeCollector(), protocolAmount, false);
			}
			payEth(destAddr, amount - referrerAmount - protocolAmount, true);
		} else {
			if (orderPayload.gasDrop > 0) {
				uint256 gasDrop = deNormalizeAmount(orderPayload.gasDrop, ETH_DECIMALS);
				if (msg.value != gasDrop) {
					revert InvalidGasDrop();
				}
				payEth(destAddr, gasDrop, false);
			}
			if (referrerAmount > 0) {
				IERC20(tokenOut).safeTransfer(referrerAddr, referrerAmount);
			}
			if (protocolAmount > 0) {
				IERC20(tokenOut).safeTransfer(feeManager.feeCollector(), protocolAmount);
			}
			IERC20(tokenOut).safeTransfer(destAddr, amount - referrerAmount - protocolAmount);
		}
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

	function depositRelayerFee(address relayer, address token, uint256 amount) internal {
		IERC20(token).transfer(address(feeManager), amount);
		try feeManager.depositFee(relayer, token, amount) {} catch {}
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
		if (bytes12(b) != 0) {
			revert InvalidAddress();
		}
		return address(uint160(uint256(b)));
	}

	function setFeeManager(address _feeManager) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		feeManager = IFeeManager(_feeManager);
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