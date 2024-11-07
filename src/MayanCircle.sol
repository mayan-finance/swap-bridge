// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libs/BytesLib.sol";
import "./interfaces/CCTP/IReceiver.sol";
import "./interfaces/CCTP/ITokenMessenger.sol";
import "./interfaces/IWormhole.sol";
import "./interfaces/ITokenBridge.sol";
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
	bytes32 public immutable solanaEmitter;
	bytes32 public immutable suiEmitter;
	uint8 public consistencyLevel;
	address public guardian;
	address nextGuardian;
	bool public paused;

	mapping(uint64 => FeeLock) public feeStorage;

	mapping(uint32 => bytes32) public domainToCaller;
	mapping(bytes32 => bytes32) public keyToMintRecipient; // key is domain + local token address

	uint8 constant ETH_DECIMALS = 18;
	uint32 constant SOLANA_DOMAIN = 5;
	uint16 constant SOLANA_CHAIN_ID = 1;
	uint32 constant SUI_DOMAIN = 8;
	uint16 constant SUI_CHAIN_ID = 21;

	uint256 constant CCTP_DOMAIN_INDEX = 4;
	uint256 constant CCTP_NONCE_INDEX = 12;
	uint256 constant CCTP_TOKEN_INDEX = 120;
	uint256 constant CCTP_AMOUNT_INDEX = 184;

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
	error InvalidDestAddr();
	error InvalidMintRecipient();
	error InvalidRedeemFee();
	error InvalidPayload();
	error CallerNotSet();
	error MintRecepientNotSet();

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
		bytes32 _solanaEmitter,
		bytes32 _suiEmitter,
		uint8 _consistencyLevel
	) {
		cctpTokenMessenger = ITokenMessenger(_cctpTokenMessenger);
		wormhole = IWormhole(_wormhole);
		feeManager = IFeeManager(_feeManager);
		auctionChainId = _auctionChainId;
		auctionAddr = _auctionAddr;
		solanaEmitter = _solanaEmitter;
		suiEmitter = _suiEmitter;
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
		bytes32 customPayload
	) external payable nonReentrant returns (uint64 sequence) {
		if (paused) {
			revert Paused();
		}
		if (redeemFee >= amountIn) {
			revert InvalidRedeemFee();
		}

		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

		maxApproveIfNeeded(tokenIn, address(cctpTokenMessenger), amountIn);

		uint64 ccptNonce = cctpTokenMessenger.depositForBurnWithCaller(
			amountIn,
			destDomain,
			getMintRecipient(destDomain, tokenIn),
			tokenIn,
			getCaller(destDomain)
		);

		BridgeWithFeeMsg memory	bridgeMsg = BridgeWithFeeMsg({
			action: uint8(Action.BRIDGE_WITH_FEE),
			payloadType: payloadType,
			cctpNonce: ccptNonce,
			cctpDomain: localDomain,
			destAddr: destAddr,
			gasDrop: gasDrop,
			redeemFee: redeemFee,
			burnAmount: uint64(amountIn),
			burnToken: bytes32(uint256(uint160(tokenIn))),
			customPayload: customPayload
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
		uint32 destDomain
	) external nonReentrant returns (uint64 cctpNonce) {
		if (paused) {
			revert Paused();
		}
		if (destDomain == SOLANA_DOMAIN || destDomain == SUI_DOMAIN) {
			revert InvalidDomain();
		}
		require(redeemFee > 0, 'zero redeem fee');

		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

		maxApproveIfNeeded(tokenIn, address(cctpTokenMessenger), amountIn - redeemFee);

		bytes32 mintRecipient = getMintRecipient(destDomain, tokenIn);
		cctpNonce = cctpTokenMessenger.depositForBurnWithCaller(amountIn - redeemFee, destDomain, mintRecipient, tokenIn, getCaller(destDomain));

		feeStorage[cctpNonce] = FeeLock({
			destAddr: mintRecipient,
			gasDrop: gasDrop,
			token: tokenIn,
			redeemFee: redeemFee
		});
	}

	function createOrder(
		OrderParams memory params,
		uint32 destDomain
	) external payable nonReentrant {
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
		maxApproveIfNeeded(params.tokenIn, address(cctpTokenMessenger), params.amountIn);

		bytes32 cctpRecipient = getMintRecipient(destDomain, params.tokenIn);
		uint64 ccptNonce = cctpTokenMessenger.depositForBurnWithCaller(params.amountIn, destDomain, cctpRecipient, params.tokenIn, getCaller(destDomain));

		require(params.referrerBps <= 50, 'invalid referrer bps');
		uint8 protocolBps = feeManager.calcProtocolBps(uint64(params.amountIn), params.tokenIn, params.tokenOut, params.destChain, params.referrerBps);
		require(protocolBps <= 50, 'invalid protocol bps');

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
			cctpSourceNonce: ccptNonce,
			cctpSourceDomain: cctpTokenMessenger.localMessageTransmitter().localDomain()
		});

		encodedOrder = encodedOrder.concat(encodeOrderFields(orderFields));
		bytes memory payload = abi.encodePacked(keccak256(encodedOrder));

		wormhole.publishMessage{
			value : msg.value
		}(0, payload, consistencyLevel);
	}

	function redeemWithFee(bytes memory cctpMsg, bytes memory cctpSigs, bytes memory encodedVm, BridgeWithFeeParams memory bridgeParams) external nonReentrant payable {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
		require(valid, reason);

		validateEmitter(vm.emitterAddress);

		if (truncateAddress(cctpMsg.toBytes32(152)) != address(this)) {
			revert InvalidMintRecipient();
		}

		BridgeWithFeeMsg memory bridgeMsg = recreateBridgeWithFee(bridgeParams, cctpMsg);

		if (vm.payload.length != 32) {
			revert InvalidPayload();
		}

		bytes32 calculatedPayload = keccak256(encodeBridgeWithFee(bridgeMsg));
		if (vm.payload.length != 32 || calculatedPayload != vm.payload.toBytes32(0)) {
			revert InvalidPayload();
		}

		if (bridgeMsg.payloadType == 2 && msg.sender != truncateAddress(bridgeMsg.destAddr)) {
			revert Unauthorized();
		}

		uint256 denormalizedGasDrop = deNormalizeAmount(bridgeMsg.gasDrop, ETH_DECIMALS);
		if (msg.value != denormalizedGasDrop) {
			revert InvalidGasDrop();
		}

		address localToken = cctpTokenMessenger.localMinter().getLocalToken(bridgeMsg.cctpDomain, bridgeMsg.burnToken);
		uint256 amount = IERC20(localToken).balanceOf(address(this));
		bool success = cctpTokenMessenger.localMessageTransmitter().receiveMessage(cctpMsg, cctpSigs);
		if (!success) {
			revert CctpReceiveFailed();
		}
		amount = IERC20(localToken).balanceOf(address(this)) - amount;

		IERC20(localToken).safeTransfer(msg.sender, uint256(bridgeMsg.redeemFee));
		address recipient = truncateAddress(bridgeMsg.destAddr);
		IERC20(localToken).safeTransfer(recipient, amount - uint256(bridgeMsg.redeemFee));
		payEth(recipient, denormalizedGasDrop, false);
	}

	function redeemWithLockedFee(bytes memory cctpMsg, bytes memory cctpSigs, bytes32 unlockerAddr) external nonReentrant payable returns (uint64 sequence) {
		uint32 cctpSourceDomain = cctpMsg.toUint32(4);
		uint64 cctpNonce = cctpMsg.toUint64(12);
		address mintRecipient = truncateAddress(cctpMsg.toBytes32(152));
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
	) public nonReentrant {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
		require(valid, reason);

		validateEmitter(vm.emitterAddress);

		unlockMsg.action = uint8(Action.UNLOCK_FEE);
		bytes32 calculatedPayload = keccak256(encodeUnlockFeeMsg(unlockMsg));
		if (vm.payload.length != 32 || calculatedPayload != vm.payload.toBytes32(0)) {
			revert InvalidPayload();
		}

		if (unlockMsg.cctpDomain != localDomain) {
			revert InvalidDomain();
		}

		FeeLock memory feeLock = feeStorage[unlockMsg.cctpNonce];
		require(feeLock.redeemFee > 0, 'fee not locked');

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
	) public nonReentrant {
		(IWormhole.VM memory vm1, bool valid1, string memory reason1) = wormhole.parseAndVerifyVM(encodedVm1);
		require(valid1, reason1);

		validateEmitter(vm1.emitterAddress);

		unlockMsg.action = uint8(Action.UNLOCK_FEE);
		bytes32 calculatedPayload1 = keccak256(encodeUnlockFeeMsg(unlockMsg));
		if (vm1.payload.length != 32 || calculatedPayload1 != vm1.payload.toBytes32(0)) {
			revert InvalidPayload();
		}
		if (unlockMsg.cctpDomain != localDomain) {
			revert InvalidDomain();
		}

		FeeLock memory feeLock = feeStorage[unlockMsg.cctpNonce];
		require(feeLock.redeemFee > 0, 'fee not locked');
		require(unlockMsg.gasDrop < feeLock.gasDrop, 'gas was sufficient');

		(IWormhole.VM memory vm2, bool valid2, string memory reason2) = wormhole.parseAndVerifyVM(encodedVm2);
		require(valid2, reason2);

		validateEmitter(vm2.emitterAddress);

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
	) public nonReentrant payable {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
		require(valid, reason);

		require(vm.emitterChainId == SOLANA_CHAIN_ID, 'invalid emitter chain');
		require(vm.emitterAddress == auctionAddr, 'invalid solana emitter');

		FulfillMsg memory fulfillMsg = recreateFulfillMsg(params, cctpMsg);
		require(fulfillMsg.deadline >= block.timestamp, 'deadline passed');
		require(msg.sender == truncateAddress(fulfillMsg.driver), 'invalid driver');
		
		bytes32 calculatedPayload = keccak256(encodeFulfillMsg(fulfillMsg).concat(abi.encodePacked(fulfillMsg.driver)));
		if (vm.payload.length != 32 || calculatedPayload != vm.payload.toBytes32(0)) {
			revert InvalidPayload();
		}

		(address localToken, uint256 cctpAmount) = receiveCctp(cctpMsg, cctpSigs);

		if (fulfillMsg.redeemFee > 0) {
			IERC20(localToken).safeTransfer(msg.sender, fulfillMsg.redeemFee);
		}

		address tokenOut = truncateAddress(fulfillMsg.tokenOut);
		maxApproveIfNeeded(localToken, swapProtocol, cctpAmount - uint256(fulfillMsg.redeemFee));

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
		require(amountOut >= promisedAmount, 'insufficient amount out');

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
	) public nonReentrant payable {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
		require(valid, reason);

		validateEmitter(vm.emitterAddress);

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

		require(order.deadline < block.timestamp, 'deadline not passed');

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

	function receiveCctp(bytes memory cctpMsg, bytes memory cctpSigs) internal returns (address, uint256) {
		uint32 cctpDomain = cctpMsg.toUint32(4);
		bytes32 cctpSourceToken = cctpMsg.toBytes32(120);
		address localToken = cctpTokenMessenger.localMinter().getLocalToken(cctpDomain, cctpSourceToken);

		uint256 amount = IERC20(localToken).balanceOf(address(this));
		bool success = cctpTokenMessenger.localMessageTransmitter().receiveMessage(cctpMsg, cctpSigs);
		if (!success) {
			revert CctpReceiveFailed();
		}
		amount = IERC20(localToken).balanceOf(address(this)) - amount;
		return (localToken, amount);
	}

	function getMintRecipient(uint32 destDomain, address tokenIn) internal view returns (bytes32 mintRecepient) {
		mintRecepient = keyToMintRecipient[keccak256(abi.encodePacked(destDomain, tokenIn))];
		if (mintRecepient == bytes32(0)) {
			revert MintRecepientNotSet();
		}
	}
	function getCaller(uint32 destDomain) internal view returns (bytes32 caller) {
		caller = domainToCaller[destDomain];
		if (caller == bytes32(0)) {
			revert CallerNotSet();
		}
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
			burnAmount: uint64(cctpMsg.toUint256(CCTP_AMOUNT_INDEX)),
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
			amountIn: uint64(cctpMsg.toUint256(CCTP_AMOUNT_INDEX)),
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
			fulfillMsg.destAddr,
			fulfillMsg.destChainId,
			fulfillMsg.tokenOut,
			fulfillMsg.promisedAmount,
			fulfillMsg.gasDrop,
			fulfillMsg.redeemFee,
			fulfillMsg.deadline,
			fulfillMsg.referrerAddr,
			fulfillMsg.referrerBps,
			fulfillMsg.protocolBps,
			fulfillMsg.cctpSourceNonce,
			fulfillMsg.cctpSourceDomain
		);
	}

	function recreateFulfillMsg(
		FulfillParams memory params,
		bytes memory cctpMsg
	) internal pure returns (FulfillMsg memory) {
		return FulfillMsg({
			action: uint8(Action.FULFILL),
			payloadType: 1,
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

	function validateEmitter(bytes32 emitter) internal {
		if (emitter != solanaEmitter
			&& emitter != suiEmitter
		 	&& truncateAddress(emitter) != address(this)) {
			revert InvalidEmitter();
		}
	}

	function maxApproveIfNeeded(address tokenAddr, address spender, uint256 amount) internal {
		IERC20 token = IERC20(tokenAddr);
		uint256 currentAllowance = token.allowance(address(this), spender);

		if (currentAllowance < amount) {
			token.safeApprove(spender, 0);
			token.safeApprove(spender, type(uint256).max);
		}
	}

	function payEth(address to, uint256 amount, bool revertOnFailure) internal {
		(bool success, ) = payable(to).call{value: amount}('');
		if (revertOnFailure) {
			require(success, 'payment failed');
		}
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
		require(bytes12(b) == 0, 'invalid EVM address');
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

	function isPaused() public view returns(bool) {
		return paused;
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
		require(to != address(0), 'transfer to the zero address');
		payEth(to, amount, true);
	}

	function setDomainCaller(uint32 domain, bytes32 caller) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		domainToCaller[domain] = caller;
	}

	function setMintRecipient(uint32 destDomain, address tokenIn, bytes32 mintRecipient) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		keyToMintRecipient[keccak256(abi.encodePacked(destDomain, tokenIn))] = mintRecipient;
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