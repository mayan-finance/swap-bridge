// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IFeeManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IFulfill.sol";

contract FulfillHelper {

	using SafeERC20 for IERC20;

	address public guardian;
	address public nextGuardian;
	mapping(address => bool) public swapProtocols;
	mapping(address => bool) public mayanProtocols;
	mapping(address => address) public referrersToSwap;

	struct FulfillParams {
		bytes encodedVm;
		OrderParams orderParams;
		ExtraParams extraParams;
		bytes32 recipient;
		bool batch;
	}

	error UnsupportedProtocol();

	constructor(address _guardian, address[] memory _swapProtocols, address[] memory _mayanProtocols) {
		guardian = _guardian;
		for (uint256 i = 0; i < _swapProtocols.length; i++) {
			swapProtocols[_swapProtocols[i]] = true;
		}
		for (uint256 i = 0; i < _mayanProtocols.length; i++) {
			mayanProtocols[_mayanProtocols[i]] = true;
		}
	}

	function fulfillWithEth(
		uint256 amountIn,
		address fulfillToken,
		address swapProtocol,
		bytes calldata swapData,
		address mayanProtocol,
		FulfillParams calldata params,
		bytes32 orderHash
	) external payable {
		if (!swapProtocols[swapProtocol] || !mayanProtocols[mayanProtocol]) {
			revert UnsupportedProtocol();
		}
		address referrerProtocol = referrersToSwap[swapProtocol];
		if (referrerProtocol != address(0)) {
			require(referrerProtocol == swapProtocol, 'Invalid swap protocol');
		}
		require(fulfillToken != address(0), 'Invalid fulfill token');
		require(msg.value >= amountIn, 'Insufficient input value');
		uint256 fulfillAmount = IERC20(fulfillToken).balanceOf(address(this));
		(bool success,) = swapProtocol.call{value: amountIn}(swapData);
		require(success, 'Swap call failed');
		fulfillAmount = IERC20(fulfillToken).balanceOf(address(this)) - fulfillAmount;

		maxApproveIfNeeded(fulfillToken, mayanProtocol, fulfillAmount);
		if (params.encodedVm.length > 0) {
			IFulfill(mayanProtocol).fulfillOrder{value: msg.value - amountIn} (
				fulfillAmount,
				params.encodedVm,
				params.orderParams,
				params.extraParams,
				params.recipient,
				params.batch,
				emptyPermit()
			);
		} else {
			IFulfill(mayanProtocol).fulfillSimple{value: msg.value - amountIn} (
				fulfillAmount,
				orderHash,
				params.orderParams,
				params.extraParams,
				params.recipient,
				params.batch,
				emptyPermit()
			);
		}
	} 

	function fulfillWithERC20(
		address tokenIn,
		uint256 amountIn,
		address fulfillToken,
		address swapProtocol,
		bytes calldata swapData,
		address mayanProtocol,
		FulfillParams calldata params,
		bytes32 orderHash,
		PermitParams calldata permitParams
	) external payable {
		if (!swapProtocols[swapProtocol] || !mayanProtocols[mayanProtocol]) {
			revert UnsupportedProtocol();
		}
		address referrerProtocol = referrersToSwap[swapProtocol];
		if (referrerProtocol != address(0)) {
			require(referrerProtocol == swapProtocol, 'Invalid swap protocol');
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

		(bool success,) = swapProtocol.call(swapData);
		require(success, 'Swap call failed');

		transferBackRemaining(tokenIn, amountBefore);

		if (fulfillToken == address(0)) {
			fulfillAmount = address(this).balance - fulfillAmount;
		} else {
			fulfillAmount = IERC20(fulfillToken).balanceOf(address(this)) - fulfillAmount;
		}

		if (fulfillToken == address(0)) {
			if (params.encodedVm.length > 0) {
				IFulfill(mayanProtocol).fulfillOrder{value: msg.value + fulfillAmount}(
					fulfillAmount,
					params.encodedVm,
					params.orderParams,
					params.extraParams,
					params.recipient,
					params.batch,
					emptyPermit()
				);
			} else {
				IFulfill(mayanProtocol).fulfillSimple{value: msg.value + fulfillAmount}(
					fulfillAmount,
					orderHash,
					params.orderParams,
					params.extraParams,
					params.recipient,
					params.batch,
					emptyPermit()
				);
			}
		} else {
			maxApproveIfNeeded(fulfillToken, mayanProtocol, fulfillAmount);
			if (params.encodedVm.length > 0) {
				IFulfill(mayanProtocol).fulfillOrder{value: msg.value}(
					fulfillAmount,
					params.encodedVm,
					params.orderParams,
					params.extraParams,
					params.recipient,
					params.batch,
					emptyPermit()
				);
			} else {
				IFulfill(mayanProtocol).fulfillSimple{value: msg.value}(
					fulfillAmount,
					orderHash,
					params.orderParams,
					params.extraParams,
					params.recipient,
					params.batch,
					emptyPermit()
				);
			}
		}
	}

	function emptyPermit() internal pure returns (PermitParams memory) {
		return PermitParams({
			value: 0,
			deadline: 0,
			v: 0,
			r: bytes32(0),
			s: bytes32(0)
		});
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

	function setReferrerToSwap(address referrer, address swapProtocol) public {
		require(msg.sender == guardian, 'only guardian');
		referrersToSwap[referrer] = swapProtocol;
	}

	receive() external payable {}  
}