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
	address public guardian;
	address public nextGuardian;
	address public feeCollector;

	uint256 constant MAX_GASDROP = 1_000_000_000_000_000; // 0.001 ETH


	struct DepositPayload {
		uint64 relayerFee;
		IHCBridge.DepositWithPermit permit;
	}

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
		guardian = msg.sender;
		feeCollector = msg.sender;
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
		DepositPayload memory deposit = decodeDepositPayload(customPayload);
		IHCBridge.DepositWithPermit [] memory permits = new IHCBridge.DepositWithPermit[](1);
		permits[0] = deposit.permit;

		uint256 amount = IERC20(usdc).balanceOf(address(this));
		IFastMCTP(fastMCTP).redeem {value: msg.value} (cctpMsg, cctpSigs);
		amount = IERC20(usdc).balanceOf(address(this)) - amount;

		if (amount < deposit.permit.usd + deposit.relayerFee) {
			IERC20(usdc).transfer(deposit.permit.user, amount);
			return;
		}
		if (deposit.relayerFee > 0) {
			IERC20(usdc).transfer(msg.sender, deposit.relayerFee);
		}
		IERC20(usdc).transfer(deposit.permit.user, deposit.permit.usd);
		if (amount - deposit.relayerFee > deposit.permit.usd) {
			IERC20(usdc).transfer(feeCollector, amount - deposit.relayerFee - deposit.permit.usd);
		}

		uint256 gasDrop = deNormalizeAmount(bridgePayload.gasDrop, 18);
		try IHCBridge(hcBridge).batchedDepositWithPermit(permits) {
			if (gasDrop > 0) {
				payable(msg.sender).call{value: gasDrop}('');
			}
		} catch {
			if (gasDrop > 0) {
				payable(deposit.permit.user).call{value: gasDrop}('');
			}
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

		DepositPayload memory deposit = decodeDepositPayload(customPayload);
		IHCBridge.DepositWithPermit [] memory permits = new IHCBridge.DepositWithPermit[](1);
		permits[0] = deposit.permit;

		uint256 amount = IERC20(usdc).balanceOf(address(this));
		IMayanCircle(mayanCricle).redeemWithFee {value: msg.value} (cctpMsg, cctpSigs, encodedVm, bridgeParams);
		amount = IERC20(usdc).balanceOf(address(this)) - amount;

		if (amount < deposit.permit.usd + deposit.relayerFee) {
			IERC20(usdc).transfer(deposit.permit.user, amount);
			return;
		}
		if (deposit.relayerFee > 0) {
			IERC20(usdc).transfer(msg.sender, deposit.relayerFee);
		}
		IERC20(usdc).transfer(deposit.permit.user, deposit.permit.usd);
		if (amount - deposit.relayerFee > deposit.permit.usd) {
			IERC20(usdc).transfer(feeCollector, amount - deposit.relayerFee - deposit.permit.usd);
		}

		uint256 gasDrop = deNormalizeAmount(bridgePayload.gasDrop, 18);
		try IHCBridge(hcBridge).batchedDepositWithPermit(permits) {
			if (gasDrop > 0) {
				payable(msg.sender).call{value: gasDrop}('');
			}
		} catch {
			if (gasDrop > 0) {
				payable(deposit.permit.user).call{value: gasDrop}('');
			}
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

	function decodeDepositPayload(bytes memory payload) internal pure returns (DepositPayload memory) {
		return DepositPayload ({
			relayerFee: payload.toUint64(0),
			permit: IHCBridge.DepositWithPermit({
				user: payload.toAddress(8),
				usd: payload.toUint64(28),
				deadline: payload.toUint64(36),
				signature: IHCBridge.Signature({
					r: payload.toUint256(44),
					s: payload.toUint256(76),
					v: payload.toUint8(108)
				})
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

	function setFeeCollector(address newFeeCollector) external {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		feeCollector = newFeeCollector;
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
		payable(to).call{value: amount}('');
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