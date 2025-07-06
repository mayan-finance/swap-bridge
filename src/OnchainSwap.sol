// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./interfaces/IWETH.sol";

contract OnchainSwap is ReentrancyGuard {

	using SafeERC20 for IERC20;

	error Unauthorized();

	event ETHTransferred(address indexed to, uint256 amount);
	event TokenTransferred(address indexed token, address indexed to, uint256 amount);

	address public guardian;
	address public nextGuardian;

	address public immutable ForwarderAddress;
	IWETH public immutable WETH;

	constructor(address _forwarderAddress, address _weth) {
		ForwarderAddress = _forwarderAddress;
		WETH = IWETH(_weth);

		guardian = msg.sender;
	}

	modifier onlyForwarder() {
		if (msg.sender != ForwarderAddress) {
			revert Unauthorized();
		}
		_;
	}

	function transferToken(address token, uint256 amount, address to, bool unwrap) nonReentrant external onlyForwarder {
		if (unwrap) {
			WETH.withdraw(amount);
			payViaCall(to, amount);
		} else {
			IERC20(token).safeTransfer(to, amount);
		}
		emit TokenTransferred(token, to, amount);
	}

	function payViaCall(address to, uint256 amount) internal {
		(bool success, ) = payable(to).call{value: amount}('');
		require(success, 'payment failed');
	}

	receive() external payable {}
}