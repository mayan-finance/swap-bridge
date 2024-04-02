// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "./libs/BytesLib.sol";


contract MayanForwarder is ReentrancyGuard {

	using SafeERC20 for IERC20;
	using BytesLib for bytes;

	event Forwarded(uint256 amount);

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
	) nonReentrant external payable {
		require(!paused, "MayanForwarder: paused");
		require(middleToken != address(0), "MayanForwarder: middleToken must be different from address(0)");

		require(swapProtocols[swapProtocol], "MayanForwarder: unsupported protocol");
		require(amountIn >= msg.value, "MayanForwarder: insufficient amountIn");
		(bool success, bytes memory returnedData) = swapProtocol.call{value: amountIn}(swapData);
		require(success, string(returnedData));
		uint256 middleAmount = IERC20(middleToken).balanceOf(address(this));
		require(middleAmount >= minMiddleAmount, "MayanForwarder: insufficient middle token amount");

		require(mayanProtocols[mayanProtocol], "MayanForwarder: unsupported protocol");
		maxApproveIfNeeded(middleToken, mayanProtocol, middleAmount);

        bytes memory modifiedData = replaceMiddleAmount(mayanData, middleAmount);
		(success, returnedData) = mayanProtocol.call{value: msg.value - amountIn}(modifiedData);
		require(success, string(returnedData));
		emit Forwarded(middleAmount);
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
	) nonReentrant external payable {
		require(!paused, "MayanForwarder: paused");
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

		bytes memory modifiedData = replaceMiddleAmount(mayanData, middleAmount);
		(success, returnedData) = mayanProtocol.call{value: msg.value}(modifiedData);
		require(success, string(returnedData));
		emit Forwarded(middleAmount);
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

	function rescueToken(address token, uint256 amount, address to) public {
		require(msg.sender == guardian, 'only guardian');
		IERC20(token).safeTransfer(to, amount);
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