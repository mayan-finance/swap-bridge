// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IFeeManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract FeeManager is IFeeManager {

	using SafeERC20 for IERC20;

	address public operator;

	constructor(address _operator) {
		operator = _operator;
	}
	
	function calcProtocolBps(
		uint64 amountIn,
		address tokenIn,
		bytes32 tokenOut,
		uint16 destChain,
		uint8 referrerBps
	) external view override returns (uint8 protocolBps) {
		return 0;
	}

	function feeCollector() external view override returns (address) {
		return address(this);
	}

	function setOperator(address _operator) external {
		require(msg.sender == operator, 'only operator');
		operator = _operator;
	}

	function sweepToken(address token, uint256 amount, address to) public {
		require(msg.sender == operator, 'only operator');
		IERC20(token).safeTransfer(to, amount);
	}

	function sweepEth(uint256 amount, address payable to) public {
		require(msg.sender == operator, 'only operator');
		require(to != address(0), 'transfer to the zero address');
		to.transfer(amount);
	}

	receive() external payable {}
}