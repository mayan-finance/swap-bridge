// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../libs/BytesLib.sol";
import "../interfaces/IHCBridge.sol";

interface IMayanCircle {
	function bridgeWithFee(
		address tokenIn,
		uint256 amountIn,
		uint64 redeemFee,
		uint64 gasDrop,
		bytes32 destAddr,
		uint32 destDomain,
		uint8 payloadType,
		bytes memory depositPayload
	) external payable returns (uint64 sequence);
}

interface IFastMCTP {
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
		bytes memory depositPayload
	) external;
}

contract HCDepositInitiator is ReentrancyGuard {
	using SafeERC20 for IERC20;
	using BytesLib for bytes;

	error Unauthorized();
	error AlreadySet();
	error InsufficientAmount();

	address public mayanCircle;
	address public fastMCTP;
	bytes32 immutable hcProcessor;
	uint16 constant hcDomain = 3;
	address immutable usdc;
	address public guardian;
	address public nextGuardian;

	struct DepositPayload {
		uint64 relayerFee;
		IHCBridge.DepositWithPermit permit;
	}

	constructor(address _hcProcessor, address _usdc) {
		guardian = msg.sender;
		hcProcessor = bytes32(uint256(uint160(_hcProcessor)));
		usdc = _usdc;
	}

	function fastDeposit(
		address tokenIn,
		uint256 amountIn,
		address trader,
		uint256 circleMaxFee,
		uint64 gasDrop,
		bytes32 referrerAddress,
		uint8 referrerBps,
		uint32 minFinalityThreshold,
		DepositPayload calldata depositPayload
	) external nonReentrant {
		require(fastMCTP != address(0), "FastMCTP not enabled");
		require(tokenIn == usdc, "Only USDC supported");
		
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

		uint256 effectiveAmount = depositPayload.permit.usd + depositPayload.relayerFee + circleMaxFee;
		if (amountIn < effectiveAmount) {
			revert InsufficientAmount();
		}
		if (amountIn > effectiveAmount) {
			IERC20(tokenIn).safeTransfer(trader, amountIn - effectiveAmount);
		}

		maxApproveIfNeeded(usdc, fastMCTP, effectiveAmount);
		IFastMCTP(fastMCTP).bridge(
			tokenIn,
			effectiveAmount,
			0, // redeemFee
			circleMaxFee,
			gasDrop,
			hcProcessor,
			hcDomain,
			referrerAddress,
			referrerBps,
			2, // paylaodType
			minFinalityThreshold,
			encodeDepositPayload(depositPayload)
		);
	}

	function deposit(
		address tokenIn,
		uint256 amountIn,
		address trader,
		uint64 gasDrop,
		DepositPayload calldata depositPayload
	) external nonReentrant {
		require(mayanCircle != address(0), "FastMCTP not enabled");
		require(tokenIn == usdc, "Only USDC supported");
		
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

		uint256 effectiveAmount = depositPayload.permit.usd + depositPayload.relayerFee;
		if (amountIn < effectiveAmount) {
			revert InsufficientAmount();
		}

		if (amountIn > effectiveAmount) {
			IERC20(tokenIn).safeTransfer(trader, amountIn - effectiveAmount);
		}
		
		maxApproveIfNeeded(usdc, mayanCircle, effectiveAmount);

		IMayanCircle(mayanCircle).bridgeWithFee(
			tokenIn,
			effectiveAmount,
			0, // redeemFee
			gasDrop,
			hcProcessor,
			hcDomain,
			2, // payloadType
			encodeDepositPayload(depositPayload)
		);
	}

	function encodeDepositPayload(DepositPayload calldata dp) internal pure returns (bytes memory) {
		return abi.encodePacked(
			dp.relayerFee,
			dp.permit.user,
			dp.permit.usd,
			dp.permit.deadline,
			dp.permit.signature.r,
			dp.permit.signature.s,
			dp.permit.signature.v
		);
	}

	function maxApproveIfNeeded(address tokenAddr, address spender, uint256 amount) internal {
		IERC20 token = IERC20(tokenAddr);
		uint256 currentAllowance = token.allowance(address(this), spender);

		if (currentAllowance < amount) {
			token.safeApprove(spender, 0);
			token.safeApprove(spender, type(uint256).max);
		}
	}	

	function setMayanCircle(address _mayanCircle) external {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		if(mayanCircle != address(0)) {
			revert AlreadySet();
		}
		mayanCircle = _mayanCircle;
	}

	function setFastMCTP(address _fastMCTP) external {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		if(fastMCTP != address(0)) {
			revert AlreadySet();
		}
		fastMCTP = _fastMCTP;
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
}