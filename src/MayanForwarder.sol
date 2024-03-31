// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";


contract MayanForwarder {

	using SafeERC20 for IERC20;

	bool public paused;
	address public guardian;
	address public nextGuardian;
	mapping(address => bool) public swapProtocols;
	mapping(address => bool) public mayanProtocols;

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
		uint256 amountIn,
		address swapProtocol,
		bytes calldata swapData,
		address middleToken,
		uint256 minMiddleAmount,
		address mayanProtocol,
		bytes calldata mayanData
	) external payable {
		require(middleToken != address(0), "MayanForwarder: middleToken must be different from address(0)");

		require(swapProtocols[swapProtocol], "MayanForwarder: unsupported protocol");
		require(amountIn >= msg.value, "MayanForwarder: insufficient amountIn");
		(bool success, bytes memory returnedData) = swapProtocol.call{value: amountIn}(swapData);
		require(success, string(returnedData));
		uint256 middleAmount = IERC20(middleToken).balanceOf(address(this));
		require(middleAmount >= minMiddleAmount, "MayanForwarder: insufficient middle token amount");

		require(mayanProtocols[mayanProtocol], "MayanForwarder: unsupported protocol");
		maxApproveIfNeeded(middleToken, mayanProtocol, middleAmount);
		(success, returnedData) = mayanProtocol.call{value: msg.value - amountIn}(mayanData);
		require(success, string(returnedData));
	}    

	function forwardERC20(
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
		require(tokenIn != middleToken, "MayanForwarder: tokenIn and tokenOut must be different");
		if (permitParams.value > 0) {
			execPermit(address(this), tokenIn, msg.sender, permitParams);
		}
		uint256 amount = IERC20(tokenIn).balanceOf(address(this));
		IERC20(tokenIn).safeTransferFrom(tokenIn, address(this), amountIn);
		amount = IERC20(tokenIn).balanceOf(address(this)) - amount;

		maxApproveIfNeeded(tokenIn, swapProtocol, amount);
		require(swapProtocols[swapProtocol], "MayanForwarder: unsupported protocol");
		(bool success, bytes memory returnedData) = swapProtocol.call{value: 0}(swapData);
		require(success, string(returnedData));
		uint256 middleAmount = IERC20(middleToken).balanceOf(address(this));
		require(middleAmount >= minMiddleAmount, "MayanForwarder: insufficient middle token amount");

		require(mayanProtocols[mayanProtocol], "MayanForwarder: unsupported protocol");
		maxApproveIfNeeded(middleToken, mayanProtocol, middleAmount);
		(success, returnedData) = mayanProtocol.call{value: msg.value}(mayanData);
		require(success, string(returnedData));
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
		address spender,
		PermitParams calldata permitParams
	) internal {
		IERC20Permit(token).permit(
			owner,
			spender,
			permitParams.value,
			permitParams.deadline,
			permitParams.v,
			permitParams.r,
			permitParams.s
		);
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

	function setSwapProtocol(address swapProtocol, bool enabled) public {
		require(msg.sender == guardian, 'only guardian');
		swapProtocols[swapProtocol] = enabled;
	}

	function setMayanProtocol(address mayanProtocol, bool enabled) public {
		require(msg.sender == guardian, 'only guardian');
		mayanProtocols[mayanProtocol] = enabled;
	}
}