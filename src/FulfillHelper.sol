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

	event fulfilledWithEth();
	event fulfilledWithERC20();

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

	function fullfillWithEth(
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
		require(msg.value >= amountIn, 'Insufficient input value');
		uint256 fulfillAmount = IERC20(fulfillToken).balanceOf(address(this));
		(bool success, bytes memory returnedData) = swapProtocol.call{value: amountIn}(swapData);
		require(success, string(returnedData));
		fulfillAmount = IERC20(fulfillToken).balanceOf(address(this)) - fulfillAmount;

		maxApproveIfNeeded(fulfillToken, mayanProtocol, fulfillAmount);
		(success, returnedData) = mayanProtocol.call{value: msg.value - amountIn}(mayanData);
		require(success, string(returnedData));

		emit fulfilledWithEth();
	} 

	function fullfillWithERC20(
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
		require(fulfillToken != address(0), 'Invalid fulfill token');
		pullTokenIn(tokenIn, amountIn, permitParams);
		maxApproveIfNeeded(fulfillToken, swapProtocol, amountIn);

		uint256 fulfillAmount;
		if (fulfillToken == address(0)) {
			fulfillAmount = address(this).balance;
		} else {
			fulfillAmount = IERC20(fulfillToken).balanceOf(address(this));
		}

		(bool success, bytes memory returnedData) = swapProtocol.call(swapData);
		require(success, string(returnedData));

		transferBackRemaining(tokenIn, amountIn);

		if (fulfillToken == address(0)) {
			fulfillAmount = address(this).balance - fulfillAmount;
		} else {
			fulfillAmount = IERC20(fulfillToken).balanceOf(address(this)) - fulfillAmount;
		}

		if (fulfillToken == address(0)) {
			(success, returnedData) = mayanProtocol.call{value: msg.value + fulfillAmount}(mayanData);
			require(success, string(returnedData));
		} else {
			maxApproveIfNeeded(fulfillToken, mayanProtocol, fulfillAmount);
			(success, returnedData) = mayanProtocol.call{value: msg.value}(mayanData);
			require(success, string(returnedData));
		}

		emit fulfilledWithERC20();
	}

	function transferBackRemaining(address token, uint256 maxAmount) internal {
		uint256 remaining = IERC20(token).balanceOf(address(this));
		if (remaining > 0 && remaining <= maxAmount) {
			IERC20(token).safeTransfer(msg.sender, remaining);
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

	receive() external payable {}  
}