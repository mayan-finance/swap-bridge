import { ethers } from "hardhat";

async function main(swiftAddr: string, random: string) {
	const Swift = await ethers.getContractFactory("MayanSwift");
	const swift = await Swift.attach(swiftAddr);

	const HashZero = ethers.constants.HashZero;
	const [owner] = await ethers.getSigners();
	console.log({ inputRandom: random });

	// cancelOrder(bytes32 trader, uint16 srcChainId, bytes32 tokenIn, uint64 amountIn, bytes32 tokenOut, uint64 minAmountOut, uint64 gasDrop, bytes32 referrerAddr, bytes32 random)
	const tx = await swift.cancelOrder("0xc81ba38362db3567aaf37cb0e8ff25e91c669c2f17fbf5c872f847c8c1a7bfbb", 1, "0xc6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61", 555, addressToBytes32("0xe9e7cea3dedca5984780bafc599bd69add087d56"), 222, 15, HashZero, random, "0x6290f2ee62f3c4618531434626d4c723af5f0fa67069d49530ab83e536b734d0");
	const receipt = await tx.wait();
	console.log({ receipt });
}

function addressToBytes32(address: string) {
	if (!/^0x[0-9a-fA-F]{40}$/.test(address)) {
		throw new Error('Invalid Ethereum address');
	}
	return '0x' + '000000000000000000000000' + address.substring(2);
}

main(process.env.SWIFT_ADDR, process.env.RANDOM).catch((error) => {
	console.error(error);
	process.exitCode = 1;
});