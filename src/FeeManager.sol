// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IFeeManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract FeeManager is IFeeManager {

	using SafeERC20 for IERC20;

	address public immutable protocol;
	address public immutable collector;
	uint8 public baseBps;

	mapping (bytes32 => uint256) public relayerFees;

	constructor(address _protocol, address _collector) {
		protocol = _protocol;
		collector = _collector;
	}
	
	function calcProtocolBps(
		uint64 amountIn,
		address tokenIn,
		bytes32 tokenOut,
		uint16 destChain,
		uint8 referrerBps
	) external override returns (uint8) {
		emit ProtocolFeeCalced(3);
		return 3;
	}

	 function calcSwiftProtocolBps(
		address tokenIn,
		uint256 amountIn,
		OrderParams memory params
	)  external override returns (uint8) {
		emit ProtocolFeeCalced(baseBps);
		return 3;
	}

	function calcFastMCTPProtocolBps(
        uint8 payloadType,
        address localToken,
        uint256 recievedAmount,
        address tokenOut,
        address referrerAddr,
        uint8 referrerBps
    ) external returns (uint8) {
		emit ProtocolFeeCalced(baseBps);
		return 3;
	}

	function depositFee(address owner, address token, uint256 amount) payable external override {
		require(msg.sender == protocol, 'only protocol');
		if (token == address(0)) {
			require(msg.value == amount, 'invalid amount');
		}
		bytes32 key = keccak256(abi.encodePacked(owner, token));
		relayerFees[key] += amount;
		emit FeeDeposited(owner, token, amount);
	}

	function withdrawFee(address token, uint256 amount) external override {
		bytes32 key = keccak256(abi.encodePacked(msg.sender, token));
		require(relayerFees[key] >= amount, 'insufficient balance');
		relayerFees[key] -= amount;
		if (token == address(0)) {
			payable(msg.sender).transfer(amount);
		} else {
			IERC20(token).safeTransfer(msg.sender, amount);
		}
		emit FeeWithdrawn(token, amount);
	}

	function feeCollector() external view override returns (address) {
		return collector;
	}

	function getRelayerFee(address relayer, address token) external view returns (uint256) {
		bytes32 key = keccak256(abi.encodePacked(relayer, token));
		return relayerFees[key];
	}

	receive() external payable {}
}