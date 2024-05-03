// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "./libs/BytesLib.sol";


contract MayanForwarder {

	using SafeERC20 for IERC20;
	using BytesLib for bytes;

	event SwapAndForwarded(uint256 amount);

	address public guardian;
	address public nextGuardian;
	mapping(address => bool) public swapProtocols;
	mapping(address => bool) public mayanProtocols;

	event ForwardedEth(address mayanProtocol, bytes protocolData);
	event ForwardedERC20(address token, uint256 amount, address mayanProtocol, bytes protocolData);
	event SwapAndForwardedEth(uint256 amountIn, address swapProtocol, address middleToken, uint256 middleAmount, address mayanProtocol, bytes mayanData);
	event SwapAndForwardedERC20(address tokenIn, uint256 amountIn, address swapProtocol, address middleToken, uint256 middleAmount, address mayanProtocol, bytes mayanData);

	error UnsupportedProtocol();

	struct PermitParams {
		uint256 value;
		uint256 deadline;
		uint8 v;
		bytes32 r;
		bytes32 s;
	}

	constructor(address _guardian, address[] memory _swapProtocols, address[] memory _mayanProtocols) {
		guardian = _guardian;
		for (uint256 i = 0; i < _swapProtocols.length; i++) {
			swapProtocols[_swapProtocols[i]] = true;
		}
		for (uint256 i = 0; i < _mayanProtocols.length; i++) {
			mayanProtocols[_mayanProtocols[i]] = true;
		}
	}

	function forwardEth(
		address mayanProtocol,
		bytes calldata protocolData
	) external payable {
		if (!mayanProtocols[mayanProtocol]) {
			revert UnsupportedProtocol();
		}
		(bool success, bytes memory returnedData) = mayanProtocol.call{value: msg.value}(protocolData);
		require(success, string(returnedData));

		emit ForwardedEth(mayanProtocol, protocolData);
	}
	
	function forwardERC20(
		address tokenIn,
		uint256 amountIn,
		PermitParams calldata permitParams,
		address mayanProtocol,
		bytes calldata protocolData
		) external payable {
		if (!mayanProtocols[mayanProtocol]) {
			revert UnsupportedProtocol();
		}

		pullTokenIn(tokenIn, amountIn, permitParams);

		maxApproveIfNeeded(tokenIn, mayanProtocol, amountIn);
		(bool success, bytes memory returnedData) = mayanProtocol.call{value: msg.value}(protocolData);
		require(success, string(returnedData));

		emit ForwardedERC20(tokenIn, amountIn, mayanProtocol, protocolData);
	}

	function swapAndForwardEth(
		uint256 amountIn,
		address swapProtocol,
		bytes calldata swapData,
		address middleToken,
		uint256 minMiddleAmount,
		address mayanProtocol,
		bytes calldata mayanData
	) external payable {
		if (!swapProtocols[swapProtocol] || !mayanProtocols[mayanProtocol]) {
			revert UnsupportedProtocol();
		}
		require(middleToken != address(0), "middleToken cannot be zero address");

		require(msg.value >= amountIn, "insufficient amountIn");
		uint256 middleAmount = IERC20(middleToken).balanceOf(address(this));

		(bool success, bytes memory returnedData) = swapProtocol.call{value: amountIn}(swapData);
		require(success, string(returnedData));

		middleAmount = IERC20(middleToken).balanceOf(address(this)) - middleAmount;
		require(middleAmount >= minMiddleAmount, "MayanForwarder: insufficient middle token amount");

		maxApproveIfNeeded(middleToken, mayanProtocol, middleAmount);

		bytes memory modifiedData = replaceMiddleAmount(mayanData, middleAmount);
		(success, returnedData) = mayanProtocol.call{value: msg.value - amountIn}(modifiedData);
		require(success, string(returnedData));

		emit SwapAndForwardedEth(amountIn, swapProtocol, middleToken, middleAmount, mayanProtocol, mayanData);
	}

	function swapAndForwardERC20(
		address tokenIn,
		uint256 amountIn,
		PermitParams calldata permitParams,
		address swapProtocol,
		bytes calldata swapData,
		address middleToken,
		uint256 minMiddleAmount,
		address mayanProtocol,
		bytes calldata mayanData
	) external payable {
		if (!swapProtocols[swapProtocol] || !mayanProtocols[mayanProtocol]) {
			revert UnsupportedProtocol();
		}
		require(tokenIn != middleToken, "tokenIn and tokenOut must be different");

		pullTokenIn(tokenIn, amountIn, permitParams);

		maxApproveIfNeeded(tokenIn, swapProtocol, amountIn);
		uint256 middleAmount = IERC20(middleToken).balanceOf(address(this));

		(bool success, bytes memory returnedData) = swapProtocol.call{value: 0}(swapData);
		require(success, string(returnedData));

		middleAmount = IERC20(middleToken).balanceOf(address(this)) - middleAmount;
		require(middleAmount >= minMiddleAmount, "insufficient middle token");

		maxApproveIfNeeded(middleToken, mayanProtocol, middleAmount);
		bytes memory modifiedData = replaceMiddleAmount(mayanData, middleAmount);
		(success, returnedData) = mayanProtocol.call{value: msg.value}(modifiedData);
		require(success, string(returnedData));

		transferBackRemaining(tokenIn, amountIn);

		emit SwapAndForwardedERC20(tokenIn, amountIn, swapProtocol, middleToken, middleAmount, mayanProtocol, mayanData);
	}

	function replaceMiddleAmount(bytes calldata mayanData, uint256 middleAmount) internal pure returns(bytes memory) {
		require(mayanData.length >= 68, "Mayan data too short");
		bytes memory modifiedData = new bytes(mayanData.length);

		// Copy the function selector and token in
		for (uint i = 0; i < 36; i++) {
			modifiedData[i] = mayanData[i];
		}

		// Encode the amount and place it into the modified call data
		// Starting from byte 36 to byte 67 (32 bytes for uint256)
		bytes memory encodedAmount = abi.encode(middleAmount);
		for (uint i = 0; i < 32; i++) {
			modifiedData[i + 36] = encodedAmount[i];
		}

		// Copy the rest of the original data after the first argument
		for (uint i = 68; i < mayanData.length; i++) {
			modifiedData[i] = mayanData[i];
		}

		return modifiedData;
	}

	function maxApproveIfNeeded(address tokenAddr, address spender, uint256 amount) internal {
		IERC20 token = IERC20(tokenAddr);
		uint256 currentAllowance = token.allowance(address(this), spender);

		if (currentAllowance < amount) {
			token.safeApprove(spender, 0);
			token.safeApprove(spender, type(uint256).max);
		}
	}

	function execPermit(
		address token,
		address owner,
		PermitParams calldata permitParams
	) internal {
		IERC20Permit(token).permit(
			owner,
			address(this),
			permitParams.value,
			permitParams.deadline,
			permitParams.v,
			permitParams.r,
			permitParams.s
		);
	}

	function pullTokenIn(
		address tokenIn,
		uint256 amountIn,
		PermitParams calldata permitParams
	) internal {
		uint256 allowance = IERC20(tokenIn).allowance(msg.sender, address(this));
		if (allowance < amountIn) {
			execPermit(tokenIn, msg.sender, permitParams);
		}
		IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
	}

	function transferBackRemaining(address token, uint256 maxAmount) internal {
		uint256 remaining = IERC20(token).balanceOf(address(this));
		if (remaining > 0 && remaining <= maxAmount) {
			IERC20(token).safeTransfer(msg.sender, remaining);
		}
	}

	function rescueToken(address token, uint256 amount, address to) public {
		require(msg.sender == guardian, 'only guardian');
		IERC20(token).safeTransfer(to, amount);
	}

	function rescueEth(uint256 amount, address payable to) public {
		require(msg.sender == guardian, 'only guardian');
		require(to != address(0), 'transfer to the zero address');
		to.transfer(amount);
	}

	function changeGuardian(address newGuardian) public {
		require(msg.sender == guardian, 'only guardian');
		nextGuardian = newGuardian;
	}

	function claimGuardian() public {
		require(msg.sender == nextGuardian, 'only next guardian');
		guardian = nextGuardian;
	}

	function setSwapProtocol(address swapProtocol, bool enabled) public {
		require(msg.sender == guardian, 'only guardian');
		swapProtocols[swapProtocol] = enabled;
	}

	function setMayanProtocol(address mayanProtocol, bool enabled) public {
		require(msg.sender == guardian, 'only guardian');
		mayanProtocols[mayanProtocol] = enabled;
	}
}