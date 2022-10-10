// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import './IWormhole.sol';
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBridge {
    function wormhole() external view returns (IWormhole);
    function chainId() external view returns (uint16);
    function isWrappedAsset(address token) external view returns (bool);
    function transferTokens(address token, uint256 amount, uint16 recipientChain, bytes32 recipient, uint256 arbiterFee, uint32 nonce) external payable returns (uint64 sequence);
    function wrapAndTransferETH(uint16 recipientChain, bytes32 recipient, uint256 arbiterFee, uint32 nonce) external payable returns (uint64 sequence);
    function WETH() external view returns (IWETH);
    function finality() external view returns (uint8);
}

interface IWETH is IERC20 {
    function deposit() external payable;

    function withdraw(uint amount) external;
}