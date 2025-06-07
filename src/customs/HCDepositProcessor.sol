// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../libs/BytesLib.sol";
import "../interfaces/IHCBridge.sol";


interface IMayanCircle {
	struct BridgeWithFeeParams {
		uint8 payloadType;
		bytes32 destAddr;
		uint64 gasDrop;
		uint64 redeemFee;
		uint64 burnAmount;
		bytes32 burnToken;
		bytes32 customPayload;
	}

	function redeemWithFee(
		bytes memory cctpMsg,
		bytes memory cctpSigs,
		bytes memory encodedVm,
		BridgeWithFeeParams memory bridgeParams
	) external;
}

interface IFastMCTP {
	struct BridgePayload {
		uint8 payloadType;
		bytes32 destAddr;
		uint64 gasDrop;
		uint64 redeemFee;
		bytes32 referrerAddr;
		uint8 referrerBps;
		bytes32 customPayload;
	}

	function redeem(
		bytes memory cctpMsg,
		bytes memory cctpSigs
	) external;
}

contract HCDepositProcessor is ReentrancyGuard {
	using SafeERC20 for IERC20;
	using BytesLib for bytes;

	address immutable mayanCricle;
	address immutable fastMCTP;
	address immutable hcBridge;
	address immutable usdc;

	uint256 constant MAX_GASDROP = 1_000_000_000_000_000; // 0.001 ETH

	error InvalidAddress();
	error IncompatiblePayload();
	error InvalidCustomPayload();
	error Unauthorized();
	error InvalidGasDrop();

	constructor(
		address _mayanCircle,
		address _fastMCTP,
		address _hcBridge,
		address _usdc
	) {
		mayanCricle = _mayanCircle;
		fastMCTP = _fastMCTP;
		hcBridge = _hcBridge;
		usdc = _usdc;
	}

	function fastRedeemAndDeposit(
		bytes memory cctpMsg,
		bytes memory cctpSigs,
		bytes memory customPayload
	) external payable nonReentrant {
		IFastMCTP.BridgePayload memory bridgePayload = recreateBridgePayload(cctpMsg);

		if (bridgePayload.payloadType != 2) {
			revert IncompatiblePayload();
		}
		
		bytes32 customPayloadHash = keccak256(customPayload);
		if (customPayloadHash != bridgePayload.customPayload) {
			revert InvalidCustomPayload();
		}
		IHCBridge.DepositWithPermit memory deposit = decodeDepositPayload(customPayload);
		IHCBridge.DepositWithPermit [] memory deposits = new IHCBridge.DepositWithPermit[](1);
		deposits[0] = deposit;

		uint256 amount = IERC20(usdc).balanceOf(address(this));
		IFastMCTP(fastMCTP).redeem(cctpMsg, cctpSigs);
		amount = IERC20(usdc).balanceOf(address(this)) - amount;

		IERC20(usdc).transfer(msg.sender, bridgePayload.redeemFee);
		IERC20(usdc).transfer(deposit.user, amount - bridgePayload.redeemFee);

		try IHCBridge(hcBridge).batchedDepositWithPermit(deposits) {} catch {
			uint256 gasDrop = deNormalizeAmount(bridgePayload.gasDrop, 18);
			if (gasDrop > MAX_GASDROP) {
				gasDrop = MAX_GASDROP;
			}
			if (msg.value != gasDrop) {
				revert InvalidGasDrop();
			}
			payable(deposit.user).call{value: gasDrop}('');
		}
	}

	function redeemAndDeposit(
		bytes memory cctpMsg,
		bytes memory cctpSigs,
		bytes memory encodedVm,
		IMayanCircle.BridgeWithFeeParams memory bridgeParams,
		bytes memory customPayload
	) external payable nonReentrant {
		if (bridgeParams.payloadType != 2) {
			revert IncompatiblePayload();
		}
		if (bridgeParams.customPayload != keccak256(customPayload)) {
			revert InvalidCustomPayload();
		}

		IHCBridge.DepositWithPermit memory deposit = decodeDepositPayload(customPayload);
		IHCBridge.DepositWithPermit [] memory deposits = new IHCBridge.DepositWithPermit[](1);
		deposits[0] = deposit;

		uint256 amount = IERC20(usdc).balanceOf(address(this));
		IMayanCircle(mayanCricle).redeemWithFee(cctpMsg, cctpSigs, encodedVm, bridgeParams);
		amount = IERC20(usdc).balanceOf(address(this)) - amount;

		IERC20(usdc).transfer(msg.sender, bridgeParams.redeemFee);
		IERC20(usdc).transfer(deposit.user, amount - bridgeParams.redeemFee);

		try IHCBridge(hcBridge).batchedDepositWithPermit(deposits) {} catch {
			uint256 gasDrop = deNormalizeAmount(bridgeParams.gasDrop, 18);
			if (gasDrop > MAX_GASDROP) {
				gasDrop = MAX_GASDROP;
			}
			if (msg.value != gasDrop) {
				revert InvalidGasDrop();
			}
			payable(deposit.user).call{value: gasDrop}('');
		}
	}

	function recreateBridgePayload(
		bytes memory cctpMsg
	) internal pure returns (IFastMCTP.BridgePayload memory) {
		uint256 HOOK_DATA_INDEX = 376;
		return IFastMCTP.BridgePayload({
			payloadType: cctpMsg.toUint8(HOOK_DATA_INDEX),
			destAddr: cctpMsg.toBytes32(HOOK_DATA_INDEX + 1),
			gasDrop: cctpMsg.toUint64(HOOK_DATA_INDEX + 33),
			redeemFee: cctpMsg.toUint64(HOOK_DATA_INDEX + 41),
			referrerAddr: cctpMsg.toBytes32(HOOK_DATA_INDEX + 49),
			referrerBps: cctpMsg.toUint8(HOOK_DATA_INDEX + 81),
			customPayload: cctpMsg.toBytes32(HOOK_DATA_INDEX + 82)
		});
	}

	function decodeDepositPayload(bytes memory payload) internal pure returns (IHCBridge.DepositWithPermit memory) {
		return IHCBridge.DepositWithPermit({
			user: truncateAddress(payload.toBytes32(0)),
			usd: payload.toUint64(20),
			deadline: payload.toUint64(28),
			signature: IHCBridge.Signature({
				r: payload.toUint256(36),
				s: payload.toUint256(68),
				v: payload.toUint8(100)
			})
		});
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
}