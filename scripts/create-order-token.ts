import { ethers } from "hardhat";

async function main(swiftAddr: string, destAuth: string) {
	const Swift = await ethers.getContractFactory("MayanSwift");
	const swift = await Swift.attach(swiftAddr);

	const keypair = ethers.Wallet.createRandom();
	// const random = ethers.utils.keccak256(keypair.publicKey);
	const random = "0xddb9506b6a963cbbd731eb6d0042c36135128ceecb3d0c264002caadeb4200dd";
	console.log({ random });

	const [owner] = await ethers.getSigners();

	const ERC20_ABI = [
		"function approve(address spender, uint256 value) public returns (bool)"
	];
	const usdc = "0x2791bca1f2de4661ed88a30c99a7a9449aa84174";
	const token = new ethers.Contract(usdc, ERC20_ABI, owner);
	const approveTx = await token.approve(swift.address, 136);
	await approveTx.wait();

	let destAuthority;
	if (!destAuth) {
		destAuthority = HashZero;
	} else {
		destAuthority = addressToBytes32(destAuth);
	}

	// function createOrderWithToken(bytes32 tokenOut, uint64 minAmountOut, uint64 gasDrop, bytes32 destAddr, uint16 destChainId, address tokenIn, uint256 amountIn, bytes32 referrerAddr, bytes32 random, bytes32 destAuthority) public returns (bytes32 keyHash) {
	const tx = await swift.createOrderWithToken("0xc6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61", 5261, 0, "0xc81ba38362db3567aaf37cb0e8ff25e91c669c2f17fbf5c872f847c8c1a7bfbb", 1, usdc, 136, "0x1edd7eaaded0c1e6e51550c0b62492cdc604d08080f39f450e005e556d8a4f9b", random, destAuthority);
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