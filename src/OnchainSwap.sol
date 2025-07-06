// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract OnchainSwap is ReentrancyGuard {

	using SafeERC20 for IERC20;

	error Unauthorized();

	event ETHTransferred(address indexed to, uint256 amount);
	event TokenTransferred(address indexed token, address indexed to, uint256 amount);

	address public immutable ForwarderAddress;

	constructor(address _forwarderAddress) {
		ForwarderAddress = _forwarderAddress;
	}

	modifier onlyForwarder() {
		if (msg.sender != ForwarderAddress) {
			revert Unauthorized();
		}
		_;
	}

	function transferETH(address to) nonReentrant external onlyForwarder payable {
		payViaCall(to, msg.value);
		emit ETHTransferred(to, msg.value);
	}

	function transferToken(address token, address to, uint256 amount) nonReentrant external onlyForwarder {
		IERC20(token).safeTransfer(to, amount);
		emit TokenTransferred(token, to, amount);
	}

	function payViaCall(address to, uint256 amount) internal {
		(bool success, ) = payable(to).call{value: amount}('');
		require(success, 'payment failed');
	}

	receive() external payable {}
}