// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract OnchainSwap {
	using SafeERC20 for IERC20;

	error Unauthorized();
	error InvalidReferrerBps();

	event TokenTransferred(address token, address to, uint256 amount);
	event EthTransferred(address to, uint256 amount);

	address public guardian;
	address public nextGuardian;

	address public immutable ForwarderAddress;
	uint8 public constant MAX_REFERRER_BPS = 100;

	constructor(address _forwarderAddress) {
		ForwarderAddress = _forwarderAddress;
		guardian = msg.sender;
	}

	modifier onlyForwarder() {
		if (msg.sender != ForwarderAddress) {
			revert Unauthorized();
		}
		_;
	}

	function transferToken(
		address token,
		uint256 amount,
		address to,
		address referrerAddr,
		uint8 referrerBps
	) external onlyForwarder {
		if (referrerBps > MAX_REFERRER_BPS) {
			revert InvalidReferrerBps();
		}
		IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
		uint256 referrerFee = (amount * referrerBps) / 10000;
		if (referrerFee > 0) {
			IERC20(token).safeTransfer(referrerAddr, referrerFee);
		}
		IERC20(token).safeTransfer(to, amount - referrerFee);
		emit TokenTransferred(token, to, amount - referrerFee);
	}

	function transferEth(
		address to,
		address referrerAddr,
		uint8 referrerBps
	) external payable onlyForwarder {
		if (referrerBps > MAX_REFERRER_BPS) {
			revert InvalidReferrerBps();
		}
		uint256 referrerFee = (msg.value * referrerBps) / 10000;
		if (referrerFee > 0) {
			payEth(referrerAddr, referrerFee);
		}
		payEth(to, msg.value - referrerFee);
		emit EthTransferred(to, msg.value - referrerFee);
	}

	function payEth(address to, uint256 amount) internal {
		(bool success, ) = payable(to).call{value: amount}("");
		require(success, "eth payment failed");
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

	function rescueETH(address to, uint256 amount) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		payEth(to, amount);
	}

	function rescueToken(address token, address to, uint256 amount) public {
		if (msg.sender != guardian) {
			revert Unauthorized();
		}
		IERC20(token).safeTransfer(to, amount);
	}

	receive() external payable {}
}
