// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IFeeManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract FulfillHelper {

	using SafeERC20 for IERC20;

	address public guardian;
	address public nextGuardian;
	mapping(address => bool) public swapProtocols;
	mapping(address => bool) public mayanProtocols;

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

	function directFulfill(
		address tokenIn,
		uint256 amountIn,
		address mayanProtocol,
		bytes calldata mayanData,
		PermitParams calldata permitParams
	) external payable {
		if (!mayanProtocols[mayanProtocol]) {
			revert UnsupportedProtocol();
		}
		pullTokenIn(tokenIn, amountIn, permitParams);
		maxApproveIfNeeded(tokenIn, mayanProtocol, amountIn);

		(bool success, bytes memory returnedData) = mayanProtocol.call{value: msg.value}(mayanData);
		require(success, string(returnedData));
	}

	function fulfillWithEth(
		uint256 amountIn,
		address fulfillToken,
		address swapProtocol,
		bytes calldata swapData,
		address mayanProtocol,
		bytes calldata mayanData
	) external payable {
		if (!swapProtocols[swapProtocol] || !mayanProtocols[mayanProtocol]) {
			revert UnsupportedProtocol();
		}
		require(fulfillToken != address(0), 'Invalid fulfill token');
		require(msg.value >= amountIn, 'Insufficient input value');
		uint256 fulfillAmount = IERC20(fulfillToken).balanceOf(address(this));
		(bool success, bytes memory returnedData) = swapProtocol.call{value: amountIn}(swapData);
		require(success, string(returnedData));
		fulfillAmount = IERC20(fulfillToken).balanceOf(address(this)) - fulfillAmount;

		bytes memory modifiedData = replaceFulfillAmount(mayanData, fulfillAmount);
		maxApproveIfNeeded(fulfillToken, mayanProtocol, fulfillAmount);
		(success, returnedData) = mayanProtocol.call{value: msg.value - amountIn}(modifiedData);
		require(success, string(returnedData));
	} 

	function fulfillWithERC20(
		address tokenIn,
		uint256 amountIn,
		address fulfillToken,
		address swapProtocol,
		bytes calldata swapData,
		address mayanProtocol,
		bytes calldata mayanData,
		PermitParams calldata permitParams
	) external payable {
		if (!swapProtocols[swapProtocol] || !mayanProtocols[mayanProtocol]) {
			revert UnsupportedProtocol();
		}
		uint256 amountBefore = IERC20(tokenIn).balanceOf(address(this));
		pullTokenIn(tokenIn, amountIn, permitParams);
		maxApproveIfNeeded(tokenIn, swapProtocol, amountIn);

		uint256 fulfillAmount;
		if (fulfillToken == address(0)) {
			fulfillAmount = address(this).balance;
		} else {
			fulfillAmount = IERC20(fulfillToken).balanceOf(address(this));
		}

		(bool success, bytes memory returnedData) = swapProtocol.call(swapData);
		require(success, string(returnedData));

		transferBackRemaining(tokenIn, amountBefore);

		if (fulfillToken == address(0)) {
			fulfillAmount = address(this).balance - fulfillAmount;
		} else {
			fulfillAmount = IERC20(fulfillToken).balanceOf(address(this)) - fulfillAmount;
		}

		bytes memory modifiedData = replaceFulfillAmount(mayanData, fulfillAmount);
		if (fulfillToken == address(0)) {
			(success, returnedData) = mayanProtocol.call{value: msg.value + fulfillAmount}(modifiedData);
			require(success, string(returnedData));
		} else {
			maxApproveIfNeeded(fulfillToken, mayanProtocol, fulfillAmount);
			(success, returnedData) = mayanProtocol.call{value: msg.value}(modifiedData);
			require(success, string(returnedData));
		}
	}

	function replaceFulfillAmount(bytes calldata mayanData, uint256 fulfillAmount) internal pure returns(bytes memory) {
		require(mayanData.length >= 36, "Mayan data too short");
		bytes memory modifiedData = new bytes(mayanData.length);

		// Copy the function selector
		for (uint i = 0; i < 4; i++) {
			modifiedData[i] = mayanData[i];
		}

		// Encode the amount and place it into the modified call data
		// Starting from byte 4 to byte 35 (32 bytes for uint256)
		bytes memory encodedAmount = abi.encode(fulfillAmount);
		for (uint i = 0; i < 32; i++) {
			modifiedData[i + 4] = encodedAmount[i];
		}

		// Copy the rest of the original data after the first argument
		for (uint i = 36; i < mayanData.length; i++) {
			modifiedData[i] = mayanData[i];
		}

		return modifiedData;
	}	

	function transferBackRemaining(address token, uint256 amountBefore) internal {
		uint256 remaining = IERC20(token).balanceOf(address(this));
		if (remaining > amountBefore) {
			IERC20(token).safeTransfer(msg.sender, remaining - amountBefore);
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

	function rescueToken(address token, uint256 amount, address to) public {
		require(msg.sender == guardian, 'only guardian');
		IERC20(token).safeTransfer(to, amount);
	}

	function rescueEth(uint256 amount, address payable to) public {
		require(msg.sender == guardian, 'only guardian');
		require(to != address(0), 'transfer to the zero address');
		(bool success, ) = payable(to).call{value: amount}('');
		require(success, 'payment failed');
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

	receive() external payable {}  
}