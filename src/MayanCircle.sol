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

	IWormhole wormhole;
	ITokenMessenger cctpTokenMessenger;
	IFeeManager feeManager;

	uint32 public immutable localDomain;
	uint16 public immutable auctionChainId;
	bytes32 public immutable auctionAddr;
	bytes32 public immutable solanaEmitter;
	uint8 consistencyLevel;
	address guardian;
	address nextGuardian;
	bool paused;

	mapping(uint64 => FeeLock) public feeStorage;

	uint8 constant ETH_DECIMALS = 18;
	uint32 constant SOLANA_DOMAIN = 5;
	uint16 constant SOLANA_CHAIN_ID = 1;

	enum Action {
		NONE,
		SWAP,
		FULFILL,
		BRIDGE_WITH_FEE,
		UNLOCK_FEE,
		UNLOCK_FEE_REFINE
	}

	struct Order {
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
		bytes32 refAddr;
		uint8 referrerBps;
		uint8 protocolBps;
	}

	struct OrderParams {
		bytes32 destAddr;
		uint16 destChain;
		bytes32 tokenOut;
		uint64 minAmountOut;
		uint64 redeemFee;
		uint64 deadline;
		bytes32 refAddr;
		uint8 referrerBps;
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

	struct CctpRecipient {
		uint32 destDomain;
		bytes32 mintRecipient;
		bytes32 callerAddr;
	}

	struct BridgeWithFeeMsg {
		uint8 action;
		uint8 payloadId;
		uint64 cctpNonce;
		uint32 cctpDomain;
		bytes32 destAddr;
		uint64 gasDrop;
		uint64 redeemFee;
	}

	struct UnlockFeeMsg {
		uint8 action;
		uint8 payloadId;
		uint64 cctpNonce;
		uint32 cctpDomain;
		bytes32 unlockerAddr;
		uint64 gasDrop;
	}

	struct UnlockRefinedFeeMsg {
		uint8 action;
		uint8 payloadId;
		uint64 cctpNonce;
		uint32 cctpDomain;
		bytes32 unlockerAddr;
		uint64 gasDrop;
		bytes32 destAddr;
	}	

	constructor(
		address _cctpTokenMessenger,
		address _wormhole,
		address _feeManager,
		uint16 _auctionChainId,
		bytes32 _auctionAddr,
		bytes32 _solanaEmitter,
		uint8 _consistencyLevel
	) {
		cctpTokenMessenger = ITokenMessenger(_cctpTokenMessenger);
		wormhole = IWormhole(_wormhole);
		feeManager = IFeeManager(_feeManager);
		auctionChainId = _auctionChainId;
		auctionAddr = _auctionAddr;
		solanaEmitter = _solanaEmitter;
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
		CctpRecipient memory recipient,
		bytes memory customPayload
	) public payable nonReentrant returns (uint64 sequence) {
		require(paused == false, 'contract is paused');

		uint256 burnAmount = IERC20(tokenIn).balanceOf(address(this));
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		burnAmount = IERC20(tokenIn).balanceOf(address(this)) - burnAmount;

		SafeERC20.safeApprove(IERC20(tokenIn), address(cctpTokenMessenger), burnAmount);
		uint64 ccptNonce = cctpTokenMessenger.depositForBurnWithCaller(burnAmount, recipient.destDomain, recipient.mintRecipient, tokenIn, recipient.callerAddr);

		BridgeWithFeeMsg memory	bridgeMsg = BridgeWithFeeMsg({
			action: uint8(Action.BRIDGE_WITH_FEE),
			payloadId: customPayload.length > 0 ? 2 : 1,
			cctpNonce: ccptNonce,
			cctpDomain: localDomain,
			destAddr: destAddr,
			gasDrop: gasDrop,
			redeemFee: redeemFee
		});

		bytes memory encoded = encodeBridgeWithFee(bridgeMsg);

		if (customPayload.length > 0) {
			encoded = encoded.concat(customPayload);
		}

		sequence = wormhole.publishMessage{
			value : msg.value
		}(0, encoded, consistencyLevel);
	}

	function bridgeWithLockedFee(address tokenIn, uint256 amountIn, uint256 redeemFee, uint64 gasDrop, bytes32 destAddr, CctpRecipient memory recipient) public nonReentrant returns (uint64 cctpNonce) {
		require(paused == false, 'contract is paused');
		require(recipient.destDomain != SOLANA_DOMAIN, 'invalid dest domain'); // solana is not supported for locking

		uint256 burnAmount = IERC20(tokenIn).balanceOf(address(this));
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		burnAmount = IERC20(tokenIn).balanceOf(address(this)) - burnAmount;

		SafeERC20.safeApprove(IERC20(tokenIn), address(cctpTokenMessenger), burnAmount - redeemFee);
		cctpNonce = cctpTokenMessenger.depositForBurnWithCaller(burnAmount - redeemFee, recipient.destDomain, recipient.mintRecipient, tokenIn, recipient.callerAddr);

		feeStorage[cctpNonce] = FeeLock({
			destAddr: destAddr,
			gasDrop: gasDrop,
			token: tokenIn,
			redeemFee: redeemFee
		});
	}

	function swap(
		address tokenIn,
		uint256 amountIn,
		uint64 redeemFee,
		uint64 gasDrop,
		OrderParams memory params,
		CctpRecipient memory recipient,
		bytes memory customPayload
	) public payable nonReentrant {
		require(paused == false, 'contract is paused');

		uint256 burnAmount = IERC20(tokenIn).balanceOf(address(this));
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
		burnAmount = IERC20(tokenIn).balanceOf(address(this)) - burnAmount;

		SafeERC20.safeApprove(IERC20(tokenIn), address(cctpTokenMessenger), burnAmount);
		uint64 ccptNonce = cctpTokenMessenger.depositForBurnWithCaller(burnAmount, recipient.destDomain, recipient.mintRecipient, tokenIn, recipient.callerAddr);

		Order memory order = Order({
			trader: bytes32(uint256(uint160(msg.sender))),
			sourceChain: wormhole.chainId(),
			tokenIn: bytes32(uint256(uint160(tokenIn))),
			amountIn: uint64(burnAmount),
			destAddr: params.destAddr,
			destChain: params.destChain,
			tokenOut: params.tokenOut,
			minAmountOut: params.minAmountOut,
			gasDrop: gasDrop,
			redeemFee: redeemFee,
			deadline: params.deadline,
			refAddr: params.refAddr,
			referrerBps: params.referrerBps,
			protocolBps: feeManager.calcProtocolBps(uint64(burnAmount), tokenIn, params.tokenOut, params.destChain, params.referrerBps)
		});
		
		bytes memory encodedOrder = encodeOrder(order);
		encodedOrder = abi.encodePacked(ccptNonce, cctpTokenMessenger.localMessageTransmitter().localDomain());

		bytes32 orderHash = keccak256(encodedOrder);
		OrderMsg memory orderMsg = OrderMsg({
			action: uint8(Action.SWAP),
			payloadId: customPayload.length > 0 ? 2 : 1,
			orderHash: orderHash
		});

		bytes memory encodedMsg = encodeOrderMsg(orderMsg);

		if (orderMsg.payloadId == 2) {
			encodedMsg = encodedMsg.concat(abi.encodePacked(customPayload));
		}

		wormhole.publishMessage{
			value : msg.value
		}(0, encodedMsg, consistencyLevel);
	}

	function redeemWithFee(bytes memory cctpMsg, bytes memory cctpSigs, bytes memory encodedVm) public nonReentrant payable {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
		require(valid, reason);

		if (vm.emitterChainId == SOLANA_CHAIN_ID) {
			require(vm.emitterAddress == solanaEmitter, 'invalid solana emitter');
		} else {
			require(truncateAddress(vm.emitterAddress) == address(this), 'invalid evm emitter');
		}

		BridgeWithFeeMsg memory redeemMsg = parseBridgeWithFee(vm.payload);
		require(redeemMsg.action == uint8(Action.BRIDGE_WITH_FEE), 'invalid action');

		uint256 denormalizedGasDrop = deNormalizeAmount(redeemMsg.gasDrop, ETH_DECIMALS);
		require(msg.value == denormalizedGasDrop, 'invalid gas drop');

		uint32 cctpSourceDomain = cctpMsg.toUint32(4);
		uint64 cctpNonce = cctpMsg.toUint64(12);
		bytes32 cctpSourceToken = cctpMsg.toBytes32(120);

		require(cctpSourceDomain == redeemMsg.cctpDomain, 'invalid cctp domain');
		require(cctpNonce == redeemMsg.cctpNonce, 'invalid cctp nonce');

		address localToken = cctpTokenMessenger.localMinter().getLocalToken(cctpSourceDomain, cctpSourceToken);
		require(localToken != address(0), 'invalid local token');
		uint256 amount = IERC20(localToken).balanceOf(address(this));
		bool success = cctpTokenMessenger.localMessageTransmitter().receiveMessage(cctpMsg, cctpSigs);
		require(success, 'invalid cctp msg');
		amount = IERC20(localToken).balanceOf(address(this)) - amount;

		IERC20(localToken).safeTransfer(msg.sender, uint256(redeemMsg.redeemFee));
		address recipient = truncateAddress(redeemMsg.destAddr);
		IERC20(localToken).safeTransfer(recipient, amount - uint256(redeemMsg.redeemFee));
		payable(recipient).transfer(denormalizedGasDrop);
	}

	function redeemWithLockedFee(bytes memory cctpMsg, bytes memory cctpSigs, bytes32 unlockerAddr) public nonReentrant payable returns (uint64 sequence) {
		uint32 cctpSourceDomain = cctpMsg.toUint32(4);
		uint64 cctpNonce = cctpMsg.toUint64(12);
		address caller = truncateAddress(cctpMsg.toBytes32(84));
		require(caller == address(this), 'invalid caller');
		address mintRecipient = truncateAddress(cctpMsg.toBytes32(152));

		bool success = cctpTokenMessenger.localMessageTransmitter().receiveMessage(cctpMsg, cctpSigs);
		require(success, 'invalid cctp msg');

		uint256 wormholeFee = wormhole.messageFee();
		payable(mintRecipient).transfer(msg.value - wormholeFee);

		UnlockFeeMsg memory unlockMsg = UnlockFeeMsg({
			action: uint8(Action.UNLOCK_FEE),
			payloadId: 1,
			cctpDomain: cctpSourceDomain,
			cctpNonce: cctpNonce,
			unlockerAddr: unlockerAddr,
			gasDrop: uint64(normalizeAmount(msg.value - wormholeFee, ETH_DECIMALS))
		});

		bytes memory encodedMsg = encodeUnlockFeeMsg(unlockMsg);

		sequence = wormhole.publishMessage{
			value : wormholeFee
		}(0, encodedMsg, consistencyLevel);
	}

	function refineFee(uint32 cctpNonce, uint32 cctpDomain, bytes32 destAddr, bytes32 unlockerAddr) public nonReentrant payable returns (uint64 sequence) {
		uint256 wormholeFee = wormhole.messageFee();
		payable(truncateAddress(destAddr)).transfer(msg.value - wormholeFee);

		UnlockRefinedFeeMsg memory unlockMsg = UnlockRefinedFeeMsg({
			action: uint8(Action.UNLOCK_FEE_REFINE),
			payloadId: 1,
			cctpDomain: cctpDomain,
			cctpNonce: cctpNonce,
			unlockerAddr: unlockerAddr,
			gasDrop: uint64(normalizeAmount(msg.value - wormholeFee, ETH_DECIMALS)),
			destAddr: destAddr
		});

		bytes memory encodedMsg = encodeUnlockRefinedFeeMsg(unlockMsg);

		sequence = wormhole.publishMessage{
			value : wormholeFee
		}(0, encodedMsg, consistencyLevel);
	}

	function unlockFee(bytes memory encodedVm) public nonReentrant {
		(IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVm);
		require(valid, reason);

		if (vm.emitterChainId == SOLANA_CHAIN_ID) {
			require(vm.emitterAddress == solanaEmitter, 'invalid solana emitter');
		} else {
			require(truncateAddress(vm.emitterAddress) == address(this), 'invalid evm emitter');
		}

		UnlockFeeMsg memory unlockMsg = parseUnlockFeeMsg(vm.payload);
		require(unlockMsg.action == uint8(Action.UNLOCK_FEE), 'invalid action');
		require(unlockMsg.cctpDomain == localDomain, 'invalid cctp domain');

		FeeLock memory feeLock = feeStorage[unlockMsg.cctpNonce];
		require(feeLock.redeemFee > 0, 'fee not locked');

		require(unlockMsg.gasDrop >= feeLock.gasDrop, 'insufficient gas');
		IERC20(feeLock.token).safeTransfer(truncateAddress(unlockMsg.unlockerAddr), feeLock.redeemFee);
		delete feeStorage[unlockMsg.cctpNonce];
	}

	function unlockFeeRefined(bytes memory encodedVm1, bytes memory encodedVm2) public nonReentrant {
		(IWormhole.VM memory vm1, bool valid1, string memory reason1) = wormhole.parseAndVerifyVM(encodedVm1);
		require(valid1, reason1);

		if (vm1.emitterChainId == SOLANA_CHAIN_ID) {
			require(vm1.emitterAddress == solanaEmitter, 'vm1 invalid solana emitter');
		} else {
			require(truncateAddress(vm1.emitterAddress) == address(this), 'vm1 invalid evm emitter');
		}

		UnlockFeeMsg memory unlockMsg = parseUnlockFeeMsg(vm1.payload);
		require(unlockMsg.action == uint8(Action.UNLOCK_FEE_REFINE), 'invalid action');
		require(unlockMsg.cctpDomain == localDomain, 'invalid cctp domain');

		FeeLock memory feeLock = feeStorage[unlockMsg.cctpNonce];
		require(feeLock.redeemFee > 0, 'fee not locked');
		require(unlockMsg.gasDrop < feeLock.gasDrop, 'gas was sufficient');

		(IWormhole.VM memory vm2, bool valid2, string memory reason2) = wormhole.parseAndVerifyVM(encodedVm2);
		require(valid2, reason2);

		if (vm2.emitterChainId == SOLANA_CHAIN_ID) {
			require(vm2.emitterAddress == solanaEmitter, 'invalid solana emitter');
		} else {
			require(truncateAddress(vm2.emitterAddress) == address(this), 'invalid evm emitter');
		}

		UnlockRefinedFeeMsg memory refinedMsg = parseUnlockRefinedFee(vm1.payload);

		require(refinedMsg.destAddr == feeLock.destAddr, 'invalid dest addr');
		require(refinedMsg.cctpNonce == unlockMsg.cctpNonce, 'invalid cctp nonce');
		require(refinedMsg.cctpDomain == unlockMsg.cctpDomain, 'invalid cctp domain');
		require(refinedMsg.gasDrop + unlockMsg.gasDrop >= feeLock.gasDrop, 'invalid gas drop');

		IERC20(feeLock.token).safeTransfer(truncateAddress(refinedMsg.unlockerAddr), feeLock.redeemFee);
		delete feeStorage[unlockMsg.cctpNonce];
	}

	function encodeBridgeWithFee(BridgeWithFeeMsg memory bridgeMsg) internal pure returns (bytes memory) {
		return abi.encodePacked(
			bridgeMsg.action,
			bridgeMsg.payloadId,
			bridgeMsg.cctpNonce,
			bridgeMsg.cctpDomain,
			bridgeMsg.destAddr,
			bridgeMsg.gasDrop,
			bridgeMsg.redeemFee
		);
	}

	function parseBridgeWithFee(bytes memory payload) internal pure returns (BridgeWithFeeMsg memory) {
		return BridgeWithFeeMsg({
			action: payload.toUint8(0),
			payloadId: payload.toUint8(1),
			cctpNonce: payload.toUint64(2),
			cctpDomain: payload.toUint32(10),
			destAddr: payload.toBytes32(14),
			gasDrop: payload.toUint64(46),
			redeemFee: payload.toUint64(54)
		});
	}

	function encodeUnlockFeeMsg(UnlockFeeMsg memory unlockMsg) internal pure returns (bytes memory) {
		return abi.encodePacked(
			unlockMsg.action,
			unlockMsg.payloadId,
			unlockMsg.cctpNonce,
			unlockMsg.cctpDomain,
			unlockMsg.unlockerAddr,
			unlockMsg.gasDrop
		);
	}

	function encodeUnlockRefinedFeeMsg(UnlockRefinedFeeMsg memory unlockMsg) internal pure returns (bytes memory) {
		return abi.encodePacked(
			unlockMsg.action,
			unlockMsg.payloadId,
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
			payloadId: payload.toUint8(1),
			cctpNonce: payload.toUint64(2),
			cctpDomain: payload.toUint32(10),
			unlockerAddr: payload.toBytes32(14),
			gasDrop: payload.toUint64(46)
		});
	}

	function parseUnlockRefinedFee(bytes memory payload) internal pure returns (UnlockRefinedFeeMsg memory) {
		return UnlockRefinedFeeMsg({
			action: payload.toUint8(0),
			payloadId: payload.toUint8(1),
			cctpNonce: payload.toUint64(2),
			cctpDomain: payload.toUint32(10),
			unlockerAddr: payload.toBytes32(14),
			gasDrop: payload.toUint64(46),
			destAddr: payload.toBytes32(54)
		});
	}

	function encodeOrder(Order memory order) internal pure returns (bytes memory) {
		return abi.encodePacked(
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
			order.refAddr,
			order.referrerBps,
			order.protocolBps
		);
	}

	function encodeOrderMsg(OrderMsg memory orderMsg) internal pure returns (bytes memory) {
		return abi.encodePacked(
			orderMsg.action,
			orderMsg.payloadId,
			orderMsg.orderHash
		);
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

	function truncateAddress(bytes32 b) internal pure returns (address) {
		require(bytes12(b) == 0, 'invalid EVM address');
		return address(uint160(uint256(b)));
	}

	function setConsistencyLevel(uint8 _consistencyLevel) public {
		require(msg.sender == guardian, 'only guardian');
		consistencyLevel = _consistencyLevel;
	}

	function setPause(bool _pause) public {
		require(msg.sender == guardian, 'only guardian');
		paused = _pause;
	}

	function isPaused() public view returns(bool) {
		return paused;
	}

	function changeGuardian(address newGuardian) public {
		require(msg.sender == guardian, 'only guardian');
		nextGuardian = newGuardian;
	}

	function claimGuardian() public {
		require(msg.sender == nextGuardian, 'only next guardian');
		guardian = nextGuardian;
	}
}