// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IFeeManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract FeeManager is IFeeManager {

	using SafeERC20 for IERC20;

	address public operator;
	address public nextOperator;
	uint8 public baseBps;
	address public treasury;

	constructor(address _operator, uint8 _baseBps) {
		operator = _operator;
		baseBps = _baseBps;
	}
	
	function calcProtocolBps(
		uint64 amountIn,
		address tokenIn,
		bytes32 tokenOut,
		uint16 destChain,
		uint8 referrerBps
	) external view override returns (uint8) {
		if (referrerBps > baseBps) {
			return referrerBps;
		} else {
			return baseBps;
		}
	}

	function feeCollector() external view override returns (address) {
		if (treasury != address(0)) {
			return treasury;
		} else {
			return address(this);
		}
	}

	function changeOperator(address _nextOperator) external {
		require(msg.sender == operator, 'only operator');
		nextOperator = _nextOperator;
	}	

	function claimOperator() external {
		require(msg.sender == nextOperator, 'only next operator');
		operator = nextOperator;
	}

	function sweepToken(address token, uint256 amount, address to) public {
		require(msg.sender == operator, 'only operator');
		IERC20(token).safeTransfer(to, amount);
	}

	function sweepEth(uint256 amount, address payable to) public {
		require(msg.sender == operator, 'only operator');
		require(to != address(0), 'transfer to the zero address');
		(bool success, ) = payable(to).call{value: amount}('');
		require(success, 'payment failed');
	}

	function setBaseBps(uint8 _baseBps) external {
		require(msg.sender == operator, 'only operator');
		baseBps = _baseBps;
	}

	function setTreasury(address _treasury) external {
		require(msg.sender == operator, 'only operator');
		treasury = _treasury;
	}

	receive() external payable {}
}