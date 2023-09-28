import { ethers } from "hardhat";

async function main(swiftAddr: string, destAuth: string) {
	const Swift = await ethers.getContractFactory("MayanSwift");
	const swift = await Swift.attach(swiftAddr);

	const keypair = ethers.Wallet.createRandom();
	const random = ethers.utils.keccak256(keypair.publicKey);
	console.log({ random });

	const [owner] = await ethers.getSigners();

	const ERC20_ABI = [
		"function approve(address spender, uint256 value) public returns (bool)"
	];
	const usdc = "0x2791bca1f2de4661ed88a30c99a7a9449aa84174";
	const token = new ethers.Contract(usdc, ERC20_ABI, owner);
	const approveTx = await token.approve(swift.address, 736);
	await approveTx.wait();

	// function createOrderWithToken(bytes32 tokenOut, uint64 minAmountOut, uint64 gasDrop, bytes32 destAddr, uint16 destChainId, address tokenIn, uint256 amountIn, bytes32 referrerAddr, bytes32 random, bytes32 destAuthority) public returns (bytes32 keyHash) {
	const tx = await swift.createOrderWithToken(HashZero, 425, 0, addressToBytes32(owner.address), 4, usdc, 736, HashZero, random, addressToBytes32(destAuth));
	const receipt = await tx.wait();
	console.log({ receipt });
}

function addressToBytes32(address: string) {
	if (!/^0x[0-9a-fA-F]{40}$/.test(address)) {
		throw new Error('Invalid Ethereum address');
	}
	return '0x' + '000000000000000000000000' + address.substring(2);
}

main(process.env.SWIFT_ADDR, process.env.DEST_AUTH).catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
const HashZero = ethers.constants.HashZero;