// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libs/BytesLib.sol";
import "./interfaces/CCTP/IReceiver.sol";
import "./interfaces/CCTP/ITokenMessenger.sol";
import "./interfaces/IWormhole.sol";
import "./interfaces/IFeeManager.sol";

contract MayanCircle is ReentrancyGuard {
	using SafeERC20 for IERC20;
	using BytesLib for bytes;

	IWormhole public immutable wormhole;
	ITokenMessenger public immutable cctpTokenMessenger;
	IFeeManager public feeManager;

	uint32 public immutable localDomain;
	uint16 public immutable auctionChainId;
	bytes32 public immutable auctionAddr;

	uint8 public consistencyLevel;
	address public guardian;
	address nextGuardian;
	bool public paused;

	mapping(uint64 => FeeLock) public feeStorage;

	mapping(uint16 => bytes32) public chainIdToEmitter;
	mapping(uint32 => bytes32) public domainToCaller;
	mapping(bytes32 => bytes32) public keyToMintRecipient; // key is domain + local token address
	mapping(uint16 => uint32) private chainIdToDomain;

	uint8 constant ETH_DECIMALS = 18;

	uint32 constant SOLANA_DOMAIN = 5;
	uint16 constant SOLANA_CHAIN_ID = 1;

	uint32 constant SUI_DOMAIN = 8;

	uint256 constant CCTP_DOMAIN_INDEX = 4;
	uint256 constant CCTP_NONCE_INDEX = 12;
	uint256 constant CCTP_TOKEN_INDEX = 120;
	uint256 constant CCTP_RECIPIENT_INDEX = 152;
	uint256 constant CCTP_AMOUNT_INDEX = 208;

	event OrderFulfilled(uint32 sourceDomain, uint64 sourceNonce, uint256 amount);
	event OrderRefunded(uint32 sourceDomain, uint64 sourceNonce, uint256 amount);

	error Paused();
	error Unauthorized();
	error InvalidDomain();
	error InvalidNonce();
	error InvalidOrder();
	error CctpReceiveFailed();
	error InvalidGasDrop();
	error InvalidAction();
	error InvalidEmitter();
	error EmitterAlreadySet();
	error InvalidDestAddr();
	error InvalidMintRecipient();
	error InvalidRedeemFee();
	error InvalidPayload();
	error CallerNotSet();
	error MintRecipientNotSet();
	error InvalidCaller();
	error DeadlineViolation();
	error InvalidAddress();
	error InvalidReferrerFee();
	error InvalidProtocolFee();
	error EthTransferFailed();
	error InvalidAmountOut();
	error DomainNotSet();
	error AlreadySet();

	enum Action {
		NONE,
		SWAP,
		FULFILL,
		BRIDGE_WITH_FEE,
		UNLOCK_FEE,
		UNLOCK_FEE_REFINE
	}

	struct Order {
		uint8 action;
		uint8 payloadType;
		bytes32 trader;
		uint16 sourceChain;
		bytes32 tokenIn;
		uint64 amountIn;
		bytes32 destAddr;
		uint16 destChain;
		bytes32 tokenOut;
		uint64 minAmountOut;
		uint64 gasDrop;
		uint64 redeemFee;
		uint64 deadline;
		bytes32 referrerAddr;
	}

	struct OrderFields {
		uint8 referrerBps;
		uint8 protocolBps;
		uint64 cctpSourceNonce;
		uint32 cctpSourceDomain;
	}

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

	struct ExtraParams {
		bytes32 trader;
		uint16 sourceChainId;
		uint8 protocolBps;
	}

	struct OrderMsg {
		uint8 action;
		uint8 payloadId;
		bytes32 orderHash;
	}

	struct FeeLock {
		bytes32 destAddr;
		uint64 gasDrop;
		address token;
		uint256 redeemFee;
	}

	struct BridgeWithFeeMsg {
		uint8 action;
		uint8 payloadType;
		uint64 cctpNonce;
		uint32 cctpDomain;
		bytes32 destAddr;
		uint64 gasDrop;
		uint64 redeemFee;
		uint64 burnAmount;
		bytes32 burnToken;
		bytes32 customPayload;
	}

	struct BridgeWithFeeParams {
		uint8 payloadType;
		bytes32 destAddr;
		uint64 gasDrop;
		uint64 redeemFee;
		uint64 burnAmount;
		bytes32 burnToken;
		bytes32 customPayload;		
	}

	struct UnlockFeeMsg {
		uint8 action;
		uint8 payloadType;
		uint64 cctpNonce;
		uint32 cctpDomain;
		bytes32 unlockerAddr;
		uint64 gasDrop;
	}

	struct UnlockParams {
		bytes32 unlockerAddr;
		uint64 gasDrop;
	}

	struct UnlockRefinedFeeMsg {
		uint8 action;
		uint8 payloadType;
		uint64 cctpNonce;
		uint32 cctpDomain;
		bytes32 unlockerAddr;
		uint64 gasDrop;
		bytes32 destAddr;
	}

	struct FulfillMsg {
		uint8 action;
		uint8 payloadType;
		bytes32 tokenIn;
		uint64 amountIn;
		bytes32 destAddr;
		uint16 destChainId;
		bytes32 tokenOut;
		uint64 promisedAmount;
		uint64 gasDrop;
		uint64 redeemFee;
		uint64 deadline;
		bytes32 referrerAddr;
		uint8 referrerBps;
		uint8 protocolBps;
		uint64 cctpSourceNonce;
		uint32 cctpSourceDomain;
		bytes32 driver;
	}

	struct FulfillParams {
		bytes32 destAddr;
		uint16 destChainId;
		bytes32 tokenOut;
		uint64 promisedAmount;
		uint64 gasDrop;
		uint64 redeemFee;
		uint64 deadline;
		bytes32 referrerAddr;
		uint8 referrerBps;
		uint8 protocolBps;
		bytes32 driver;
	}

	constructor(
		address _cctpTokenMessenger,
		address _wormhole,
		address _feeManager,
		uint16 _auctionChainId,
		bytes32 _auctionAddr,
		uint8 _consistencyLevel
	) {
		cctpTokenMessenger = ITokenMessenger(_cctpTokenMessenger);
		wormhole = IWormhole(_wormhole);
		feeManager = IFeeManager(_feeManager);
		auctionChainId = _auctionChainId;
		auctionAddr = _auctionAddr;
		consistencyLevel = _consistencyLevel;
		localDomain = ITokenMessenger(_cctpTokenMessenger).localMessageTransmitter().localDomain();
		guardian = msg.sender;
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
	) external payable nonReentrant returns (uint64 sequence) {
		if (paused) {
			revert Paused();
		}
		if (redeemFee >= amountIn) {
			revert InvalidRedeemFee();
		}

		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		approveIfNeeded(tokenIn, address(cctpTokenMessenger), amountIn, true);
		uint64 cctpNonce = sendCctp(tokenIn, amountIn, destDomain);

		bytes32 customPayloadHash;
		if (payloadType == 2) {
			customPayloadHash = keccak256(customPayload);
		}

		BridgeWithFeeMsg memory	bridgeMsg = BridgeWithFeeMsg({
			action: uint8(Action.BRIDGE_WITH_FEE),
			payloadType: payloadType,
			cctpNonce: cctpNonce,
			cctpDomain: localDomain,
			destAddr: destAddr,
			gasDrop: gasDrop,
			redeemFee: redeemFee,
			burnAmount: uint64(amountIn),
			burnToken: bytes32(uint256(uint160(tokenIn))),
			customPayload: customPayloadHash
		});

		bytes memory payload = abi.encodePacked(keccak256(encodeBridgeWithFee(bridgeMsg)));

		sequence = wormhole.publishMessage{
			value : msg.value
		}(0, payload, consistencyLevel);
	}

	function bridgeWithLockedFee(
		address tokenIn,
		uint256 amountIn,
		uint64 gasDrop,
		uint256 redeemFee,
		uint32 destDomain,
		bytes32 destAddr
	) external nonReentrant returns (uint64 cctpNonce) {
		if (paused) {
			revert Paused();
		}
		if (bytes12(destAddr) != 0) {
			revert InvalidDomain();
		}
		if (redeemFee == 0) {
			revert InvalidRedeemFee();
		}

		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		approveIfNeeded(tokenIn, address(cctpTokenMessenger), amountIn - redeemFee, true);
		cctpNonce = cctpTokenMessenger.depositForBurnWithCaller(
			amountIn - redeemFee,
			destDomain,
			destAddr,
			tokenIn,
			getCaller(destDomain)
		);

		feeStorage[cctpNonce] = FeeLock({
			destAddr: destAddr,
			gasDrop: gasDrop,
			token: tokenIn,
			redeemFee: redeemFee
		});
	}

	function createOrder(
		OrderParams memory params
	) external payable nonReentrant returns (uint64 sequence) {
		if (paused) {
			revert Paused();
		}
		if (params.redeemFee >= params.amountIn) {
			revert InvalidRedeemFee();
		}
		if (params.tokenOut == bytes32(0) && params.gasDrop > 0) {
			revert InvalidGasDrop();
		}

		IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
		approveIfNeeded(params.tokenIn, address(cctpTokenMessenger), params.amountIn, true);
		uint64 cctpNonce = sendCctp(params.tokenIn, params.amountIn, getDomain(params.destChain));

		if (params.referrerBps > 100) {
			revert InvalidReferrerFee();
		}
		uint8 protocolBps = feeManager.calcProtocolBps(uint64(params.amountIn), params.tokenIn, params.tokenOut, params.destChain, params.referrerBps);
		if (protocolBps > 100) {
			revert InvalidProtocolFee();
		}

		Order memory order = Order({
			action: uint8(Action.SWAP),
			payloadType: 1,
			trader: bytes32(uint256(uint160(msg.sender))),
			sourceChain: wormhole.chainId(),
			tokenIn: bytes32(uint256(uint160(params.tokenIn))),
			amountIn: uint64(params.amountIn),
			destAddr: params.destAddr,
			destChain: params.destChain,
			tokenOut: params.tokenOut,
			minAmountOut: params.minAmountOut,
			gasDrop: params.gasDrop,
			redeemFee: params.redeemFee,
			deadline: params.deadline,
			referrerAddr: params.referrerAddr
		});

		bytes memory encodedOrder = encodeOrder(order);

		OrderFields memory orderFields = OrderFields({
			referrerBps: params.referrerBps,
			protocolBps: protocolBps,
			cctpSourceNonce: cctpNonce,
			cctpSourceDomain: cctpTokenMessenger.localMessageTransmitter().localDomain()
		});

		encodedOrder = encodedOrder.concat(encodeOrderFields(orderFields));
		bytes memory payload = abi.encodePacked(keccak256(encodedOrder));

		sequence = wormhole.publishMessage{
			value : msg.value
		}(0, payload, consistencyLevel);
	}

	function redeemWithFee(
		bytes memory cctpMsg,
		bytes memory cctpSigs,
		bytes memory encodedVm,
		BridgeWithFeeParams memory bridgeParams
	) external nonReentrant payable {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
		require(valid, reason);

		validateEmitter(vm.emitterAddress, vm.emitterChainId);

		if (truncateAddress(cctpMsg.toBytes32(CCTP_RECIPIENT_INDEX)) != address(this)) {
			revert InvalidMintRecipient();
		}

		BridgeWithFeeMsg memory bridgeMsg = recreateBridgeWithFee(bridgeParams, cctpMsg);

		bytes32 calculatedPayload = keccak256(encodeBridgeWithFee(bridgeMsg));
		if (vm.payload.length != 32 || calculatedPayload != vm.payload.toBytes32(0)) {
			revert InvalidPayload();
		}

		if (bridgeMsg.payloadType == 2 && msg.sender != truncateAddress(bridgeMsg.destAddr)) {
			revert Unauthorized();
		}

		(address localToken, uint256 amount) = receiveCctp(cctpMsg, cctpSigs);

		if (bridgeMsg.redeemFee > amount) {
			revert InvalidRedeemFee();
		}
		depositRelayerFee(msg.sender, localToken, uint256(bridgeMsg.redeemFee));
		address recipient = truncateAddress(bridgeMsg.destAddr);
		IERC20(localToken).safeTransfer(recipient, amount - uint256(bridgeMsg.redeemFee));

		if (bridgeMsg.gasDrop > 0) {
			uint256 denormalizedGasDrop = deNormalizeAmount(bridgeMsg.gasDrop, ETH_DECIMALS);
			if (msg.value != denormalizedGasDrop) {
				revert InvalidGasDrop();
			}
			payEth(recipient, denormalizedGasDrop, false);
		}
	}

	function redeemWithLockedFee(bytes memory cctpMsg, bytes memory cctpSigs, bytes32 unlockerAddr) external nonReentrant payable returns (uint64 sequence) {
		uint32 cctpSourceDomain = cctpMsg.toUint32(CCTP_DOMAIN_INDEX);
		uint64 cctpNonce = cctpMsg.toUint64(CCTP_NONCE_INDEX);
		address mintRecipient = truncateAddress(cctpMsg.toBytes32(CCTP_RECIPIENT_INDEX));
		if (mintRecipient == address(this)) {
			revert InvalidMintRecipient();
		}

		bool success = cctpTokenMessenger.localMessageTransmitter().receiveMessage(cctpMsg, cctpSigs);
		if (!success) {
			revert CctpReceiveFailed();
		}

		uint256 wormholeFee = wormhole.messageFee();
		if (msg.value > wormholeFee) {
			payEth(mintRecipient, msg.value - wormholeFee, false);
		}

		UnlockFeeMsg memory unlockMsg = UnlockFeeMsg({
			action: uint8(Action.UNLOCK_FEE),
			payloadType: 1,
			cctpDomain: cctpSourceDomain,
			cctpNonce: cctpNonce,
			unlockerAddr: unlockerAddr,
			gasDrop: uint64(normalizeAmount(msg.value - wormholeFee, ETH_DECIMALS))
		});

		bytes memory encodedMsg = encodeUnlockFeeMsg(unlockMsg);
		bytes memory payload = abi.encodePacked(keccak256(encodedMsg));

		sequence = wormhole.publishMessage{
			value : wormholeFee
		}(0, payload, consistencyLevel);
	}

	function refineFee(uint32 cctpNonce, uint32 cctpDomain, bytes32 destAddr, bytes32 unlockerAddr) external nonReentrant payable returns (uint64 sequence) {
		uint256 wormholeFee = wormhole.messageFee();
		if (msg.value > wormholeFee) {
			payEth(truncateAddress(destAddr), msg.value - wormholeFee, false);
		}

		UnlockRefinedFeeMsg memory unlockMsg = UnlockRefinedFeeMsg({
			action: uint8(Action.UNLOCK_FEE_REFINE),
			payloadType: 1,
			cctpDomain: cctpDomain,
			cctpNonce: cctpNonce,
			unlockerAddr: unlockerAddr,
			gasDrop: uint64(normalizeAmount(msg.value - wormholeFee, ETH_DECIMALS)),
			destAddr: destAddr
		});

		bytes memory encodedMsg = encodeUnlockRefinedFeeMsg(unlockMsg);
		bytes memory payload = abi.encodePacked(keccak256(encodedMsg));

		sequence = wormhole.publishMessage{
			value : wormholeFee
		}(0, payload, consistencyLevel);
	}

	function unlockFee(
		bytes memory encodedVm,
		UnlockFeeMsg memory unlockMsg
	) external nonReentrant {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
		require(valid, reason);

		validateEmitter(vm.emitterAddress, vm.emitterChainId);

		unlockMsg.action = uint8(Action.UNLOCK_FEE);
		bytes32 calculatedPayload = keccak256(encodeUnlockFeeMsg(unlockMsg));
		if (vm.payload.length != 32 || calculatedPayload != vm.payload.toBytes32(0)) {
			revert InvalidPayload();
		}

		if (unlockMsg.cctpDomain != localDomain) {
			revert InvalidDomain();
		}

		FeeLock memory feeLock = feeStorage[unlockMsg.cctpNonce];
		if (feeLock.redeemFee == 0) {
			revert InvalidOrder();
		}

		if (unlockMsg.gasDrop < feeLock.gasDrop) {
			revert InvalidGasDrop();
		}
		IERC20(feeLock.token).safeTransfer(truncateAddress(unlockMsg.unlockerAddr), feeLock.redeemFee);
		delete feeStorage[unlockMsg.cctpNonce];
	}

	function unlockFeeRefined(
		bytes memory encodedVm1,
		bytes memory encodedVm2,
		UnlockFeeMsg memory unlockMsg,
		UnlockRefinedFeeMsg memory refinedMsg
	) external nonReentrant {
		(IWormhole.VM memory vm1, bool valid1, string memory reason1) = wormhole.parseAndVerifyVM(encodedVm1);
		require(valid1, reason1);

		validateEmitter(vm1.emitterAddress, vm1.emitterChainId);

		unlockMsg.action = uint8(Action.UNLOCK_FEE);
		bytes32 calculatedPayload1 = keccak256(encodeUnlockFeeMsg(unlockMsg));
		if (vm1.payload.length != 32 || calculatedPayload1 != vm1.payload.toBytes32(0)) {
			revert InvalidPayload();
		}
		if (unlockMsg.cctpDomain != localDomain) {
			revert InvalidDomain();
		}

		FeeLock memory feeLock = feeStorage[unlockMsg.cctpNonce];
		if (feeLock.redeemFee == 0) {
			revert InvalidOrder();
		}
		if (unlockMsg.gasDrop >= feeLock.gasDrop) {
			revert InvalidAction();
		}

		(IWormhole.VM memory vm2, bool valid2, string memory reason2) = wormhole.parseAndVerifyVM(encodedVm2);
		require(valid2, reason2);

		validateEmitter(vm2.emitterAddress, vm2.emitterChainId);

		refinedMsg.action = uint8(Action.UNLOCK_FEE_REFINE);
		bytes32 calculatedPayload2 = keccak256(encodeUnlockRefinedFeeMsg(refinedMsg));
		if (vm2.payload.length != 32 || calculatedPayload2 != vm2.payload.toBytes32(0)) {
			revert InvalidPayload();
		}

		if (refinedMsg.destAddr != feeLock.destAddr) {
			revert InvalidDestAddr();
		}
		if (refinedMsg.cctpNonce != unlockMsg.cctpNonce) {
			revert InvalidNonce();
		}
		if (refinedMsg.cctpDomain != unlockMsg.cctpDomain) {
			revert InvalidDomain();
		}
		if (refinedMsg.gasDrop + unlockMsg.gasDrop < feeLock.gasDrop) {
			revert InvalidGasDrop();
		}

		IERC20(feeLock.token).safeTransfer(truncateAddress(refinedMsg.unlockerAddr), feeLock.redeemFee);
		delete feeStorage[unlockMsg.cctpNonce];
	}

	function fulfillOrder(
		bytes memory cctpMsg,
		bytes memory cctpSigs,
		bytes memory encodedVm,
		FulfillParams memory params,
		address swapProtocol,
		bytes memory swapData
	) external nonReentrant payable {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
		require(valid, reason);

		if (vm.emitterChainId != SOLANA_CHAIN_ID || vm.emitterAddress != auctionAddr) {
			revert InvalidEmitter();
		}

		FulfillMsg memory fulfillMsg = recreateFulfillMsg(params, cctpMsg);
		if (fulfillMsg.deadline < block.timestamp) {
			revert DeadlineViolation();
		}
		if (msg.sender != truncateAddress(fulfillMsg.driver)) {
			revert Unauthorized();
		}
		
		bytes32 calculatedPayload = calcFulfillPayload(fulfillMsg);
		if (vm.payload.length != 32 || calculatedPayload != vm.payload.toBytes32(0)) {
			revert InvalidPayload();
		}

		(address localToken, uint256 cctpAmount) = receiveCctp(cctpMsg, cctpSigs);

		if (fulfillMsg.redeemFee > 0) {
			IERC20(localToken).safeTransfer(msg.sender, fulfillMsg.redeemFee);
		}

		address tokenOut = truncateAddress(fulfillMsg.tokenOut);
		approveIfNeeded(localToken, swapProtocol, cctpAmount - uint256(fulfillMsg.redeemFee), false);

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

		uint256 promisedAmount = deNormalizeAmount(fulfillMsg.promisedAmount, decimals);
		if (amountOut < promisedAmount) {
			revert InvalidAmountOut();
		}

		makePayments(
			fulfillMsg,
			tokenOut,
			amountOut
		);

		emit OrderFulfilled(fulfillMsg.cctpSourceDomain, fulfillMsg.cctpSourceNonce, amountOut);
	}

	function refund(
		bytes memory encodedVm,
		bytes memory cctpMsg,
		bytes memory cctpSigs,
		OrderParams memory orderParams,
		ExtraParams memory extraParams
	) external nonReentrant payable {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
		require(valid, reason);

		validateEmitter(vm.emitterAddress, vm.emitterChainId);

		(address localToken, uint256 amount) = receiveCctp(cctpMsg, cctpSigs);

		Order memory order = recreateOrder(orderParams, cctpMsg, extraParams);
		bytes memory encodedOrder = encodeOrder(order);
		OrderFields memory orderFields = OrderFields({
			referrerBps: orderParams.referrerBps,
			protocolBps: extraParams.protocolBps,
			cctpSourceNonce: cctpMsg.toUint64(CCTP_NONCE_INDEX),
			cctpSourceDomain: cctpMsg.toUint32(CCTP_DOMAIN_INDEX)
		});
		encodedOrder = encodedOrder.concat(encodeOrderFields(orderFields));
		if (vm.payload.length != 32 || keccak256(encodedOrder) != vm.payload.toBytes32(0)) {
			revert InvalidPayload();
		}

		if (order.deadline >= block.timestamp) {
			revert DeadlineViolation();
		}

		uint256 gasDrop = deNormalizeAmount(order.gasDrop, ETH_DECIMALS);
		if (msg.value != gasDrop) {
			revert InvalidGasDrop();
		}

		address destAddr = truncateAddress(order.destAddr);
		if (gasDrop > 0) {
			payEth(destAddr, gasDrop, false);
		}

		IERC20(localToken).safeTransfer(msg.sender, order.redeemFee);
		IERC20(localToken).safeTransfer(destAddr, amount - order.redeemFee);

		logRefund(cctpMsg, amount);
	}

	function sendCctp(
		address tokenIn,
		uint256 amountIn,
		uint32 destDomain
	) internal returns (uint64 cctpNonce) {
		if (destDomain == SUI_DOMAIN) {
			cctpNonce = cctpTokenMessenger.depositForBurn(amountIn, destDomain, getMintRecipient(destDomain, tokenIn), tokenIn);
		} else {
			cctpNonce = cctpTokenMessenger.depositForBurnWithCaller(
				amountIn,
				destDomain,
				getMintRecipient(destDomain, tokenIn),
				tokenIn,
				getCaller(destDomain)
			);
		}
	}

	function receiveCctp(bytes memory cctpMsg, bytes memory cctpSigs) internal returns (address, uint256) {
		uint32 cctpDomain = cctpMsg.toUint32(CCTP_DOMAIN_INDEX);
		bytes32 cctpSourceToken = cctpMsg.toBytes32(CCTP_TOKEN_INDEX);
		address localToken = cctpTokenMessenger.localMinter().getLocalToken(cctpDomain, cctpSourceToken);

		uint256 amount = IERC20(localToken).balanceOf(address(this));
		bool success = cctpTokenMessenger.localMessageTransmitter().receiveMessage(cctpMsg, cctpSigs);
		if (!success) {
			revert CctpReceiveFailed();
		}
		amount = IERC20(localToken).balanceOf(address(this)) - amount;
		return (localToken, amount);
	}

	function getMintRecipient(uint32 destDomain, address tokenIn) internal view returns (bytes32) {
		bytes32 mintRecepient = keyToMintRecipient[keccak256(abi.encodePacked(destDomain, tokenIn))];
		if (mintRecepient == bytes32(0)) {
			revert MintRecipientNotSet();
		}
		return mintRecepient;
	}

	function getCaller(uint32 destDomain) internal view returns (bytes32 caller) {
		caller = domainToCaller[destDomain];
		if (caller == bytes32(0)) {
			revert CallerNotSet();
		}
		return caller;
	}

	function makePayments(
		FulfillMsg memory fulfillMsg,
		address tokenOut,
		uint256 amount
	) internal {
		address referrerAddr = truncateAddress(fulfillMsg.referrerAddr);
		uint256 referrerAmount = 0;
		if (referrerAddr != address(0) && fulfillMsg.referrerBps != 0) {
			referrerAmount = amount * fulfillMsg.referrerBps / 10000;
		}

		uint256 protocolAmount = 0;
		if (fulfillMsg.protocolBps != 0) {
			protocolAmount = amount * fulfillMsg.protocolBps / 10000;
		}

		address destAddr = truncateAddress(fulfillMsg.destAddr);
		if (tokenOut == address(0)) {
			if (referrerAmount > 0) {
				payEth(referrerAddr, referrerAmount, false);
			}
			if (protocolAmount > 0) {
				payEth(feeManager.feeCollector(), protocolAmount, false);
			}
			payEth(destAddr, amount - referrerAmount - protocolAmount, true);
		} else {
			if (fulfillMsg.gasDrop > 0) {
				uint256 gasDrop = deNormalizeAmount(fulfillMsg.gasDrop, ETH_DECIMALS);
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

	function encodeBridgeWithFee(BridgeWithFeeMsg memory bridgeMsg) internal pure returns (bytes memory) {
		return abi.encodePacked(
			bridgeMsg.action,
			bridgeMsg.payloadType,
			bridgeMsg.cctpNonce,
			bridgeMsg.cctpDomain,
			bridgeMsg.destAddr,
			bridgeMsg.gasDrop,
			bridgeMsg.redeemFee,
			bridgeMsg.burnAmount,
			bridgeMsg.burnToken,
			bridgeMsg.customPayload
		);
	}

	function recreateBridgeWithFee(
			BridgeWithFeeParams memory bridgeParams,
			bytes memory cctpMsg
	) internal pure returns (BridgeWithFeeMsg memory) {
		return BridgeWithFeeMsg({
			action: uint8(Action.BRIDGE_WITH_FEE),
			payloadType: bridgeParams.payloadType,
			cctpNonce: cctpMsg.toUint64(CCTP_NONCE_INDEX),
			cctpDomain: cctpMsg.toUint32(CCTP_DOMAIN_INDEX),
			destAddr: bridgeParams.destAddr,
			gasDrop: bridgeParams.gasDrop,
			redeemFee: bridgeParams.redeemFee,
			burnAmount: cctpMsg.toUint64(CCTP_AMOUNT_INDEX),
			burnToken: cctpMsg.toBytes32(CCTP_TOKEN_INDEX),
			customPayload: bridgeParams.customPayload
		});
	}

	function encodeUnlockFeeMsg(UnlockFeeMsg memory unlockMsg) internal pure returns (bytes memory) {
		return abi.encodePacked(
			unlockMsg.action,
			unlockMsg.payloadType,
			unlockMsg.cctpNonce,
			unlockMsg.cctpDomain,
			unlockMsg.unlockerAddr,
			unlockMsg.gasDrop
		);
	}

	function encodeUnlockRefinedFeeMsg(UnlockRefinedFeeMsg memory unlockMsg) internal pure returns (bytes memory) {
		return abi.encodePacked(
			unlockMsg.action,
			unlockMsg.payloadType,
			unlockMsg.cctpNonce,
			unlockMsg.cctpDomain,
			unlockMsg.unlockerAddr,
			unlockMsg.gasDrop,
			unlockMsg.destAddr
		);
	}

	function parseUnlockFeeMsg(bytes memory payload) internal pure returns (UnlockFeeMsg memory) {
		return UnlockFeeMsg({
			action: payload.toUint8(0),
			payloadType: payload.toUint8(1),
			cctpNonce: payload.toUint64(2),
			cctpDomain: payload.toUint32(10),
			unlockerAddr: payload.toBytes32(14),
			gasDrop: payload.toUint64(46)
		});
	}

	function parseUnlockRefinedFee(bytes memory payload) internal pure returns (UnlockRefinedFeeMsg memory) {
		return UnlockRefinedFeeMsg({
			action: payload.toUint8(0),
			payloadType: payload.toUint8(1),
			cctpNonce: payload.toUint64(2),
			cctpDomain: payload.toUint32(10),
			unlockerAddr: payload.toBytes32(14),
			gasDrop: payload.toUint64(46),
			destAddr: payload.toBytes32(54)
		});
	}

	function encodeOrder(Order memory order) internal pure returns (bytes memory) {
		return abi.encodePacked(
			order.action,
			order.payloadType,
			order.trader,
			order.sourceChain,
			order.tokenIn,
			order.amountIn,
			order.destAddr,
			order.destChain,
			order.tokenOut,
			order.minAmountOut,
			order.gasDrop,
			order.redeemFee,
			order.deadline,
			order.referrerAddr
		);
	}

	function encodeOrderFields(OrderFields memory orderFields) internal pure returns (bytes memory) {
		return abi.encodePacked(
			orderFields.referrerBps,
			orderFields.protocolBps,
			orderFields.cctpSourceNonce,
			orderFields.cctpSourceDomain
		);
	}

	function calcFulfillPayload(FulfillMsg memory fulfillMsg) internal pure returns (bytes32) {
		bytes memory partialPayload = encodeFulfillMsg(fulfillMsg);
		bytes memory completePayload = partialPayload.concat(abi.encodePacked(fulfillMsg.cctpSourceNonce, fulfillMsg.cctpSourceDomain, fulfillMsg.driver));
		return keccak256(completePayload);
	}

	function recreateOrder(
		OrderParams memory params,
		bytes memory cctpMsg,
		ExtraParams memory extraParams
	) internal pure returns (Order memory) {
		return Order({
			action: uint8(Action.SWAP),
			payloadType: 1,
			trader: extraParams.trader,
			sourceChain: extraParams.sourceChainId,
			tokenIn: cctpMsg.toBytes32(CCTP_TOKEN_INDEX),
			amountIn: cctpMsg.toUint64(CCTP_AMOUNT_INDEX),
			destAddr: params.destAddr,
			destChain: params.destChain,
			tokenOut: params.tokenOut,
			minAmountOut: params.minAmountOut,
			gasDrop: params.gasDrop,
			redeemFee: params.redeemFee,
			deadline: params.deadline,
			referrerAddr: params.referrerAddr
		});
	}	

	function encodeFulfillMsg(FulfillMsg memory fulfillMsg) internal pure returns (bytes memory) {
		return abi.encodePacked(
			fulfillMsg.action,
			fulfillMsg.payloadType,
			fulfillMsg.tokenIn,
			fulfillMsg.amountIn,
			fulfillMsg.destAddr,
			fulfillMsg.destChainId,
			fulfillMsg.tokenOut,
			fulfillMsg.promisedAmount,
			fulfillMsg.gasDrop,
			fulfillMsg.redeemFee,
			fulfillMsg.deadline,
			fulfillMsg.referrerAddr,
			fulfillMsg.referrerBps,
			fulfillMsg.protocolBps
		);
	}

	function recreateFulfillMsg(
		FulfillParams memory params,
		bytes memory cctpMsg
	) internal pure returns (FulfillMsg memory) {
		return FulfillMsg({
			action: uint8(Action.FULFILL),
			payloadType: 1,
			tokenIn: cctpMsg.toBytes32(CCTP_TOKEN_INDEX),
			amountIn: cctpMsg.toUint64(CCTP_AMOUNT_INDEX),
			destAddr: params.destAddr,
			destChainId: params.destChainId,
			tokenOut: params.tokenOut,
			promisedAmount: params.promisedAmount,
			gasDrop: params.gasDrop,
			redeemFee: params.redeemFee,
			deadline: params.deadline,
			referrerAddr: params.referrerAddr,
			referrerBps: params.referrerBps,
			protocolBps: params.protocolBps,
			cctpSourceNonce: cctpMsg.toUint64(CCTP_NONCE_INDEX),
			cctpSourceDomain: cctpMsg.toUint32(CCTP_DOMAIN_INDEX),
			driver: params.driver
		});
	}

	function validateEmitter(bytes32 emitter, uint16 chainId) view internal {
		if (emitter != chainIdToEmitter[chainId]) {
			revert InvalidEmitter();
		}
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

	function logRefund(bytes memory cctpMsg, uint256 amount) internal {
		emit OrderRefunded(cctpMsg.toUint32(CCTP_DOMAIN_INDEX), cctpMsg.toUint64(CCTP_NONCE_INDEX), amount);
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

	function setConsistencyLevel(uint8 _consistencyLevel) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		consistencyLevel = _consistencyLevel;
	}

	function setPause(bool _pause) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		paused = _pause;
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

	function setDomainCallers(uint32 domain, bytes32 caller) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		if (domainToCaller[domain] != bytes32(0)) {
			revert AlreadySet();
		}
		domainToCaller[domain] = caller;
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

	function setEmitter(uint16 chainId, bytes32 emitter) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		if (chainIdToEmitter[chainId] != bytes32(0)) {
			revert AlreadySet();
		}
		chainIdToEmitter[chainId] = emitter;
	}

	function setDomains(uint16[] memory chainIds, uint32[] memory domains) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		for (uint i = 0; i < chainIds.length; i++) {
			if (chainIdToDomain[chainIds[i]] != 0) {
				revert AlreadySet();
			}
			chainIdToDomain[chainIds[i]] = domains[i] + 1; // to distinguish between unset and 0
		}
	}

	function getDomain(uint16 chainId) public view returns (uint32 domain) {
		domain = chainIdToDomain[chainId];
		if (domain == 0) {
			revert DomainNotSet();
		}
		return domain - 1;
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