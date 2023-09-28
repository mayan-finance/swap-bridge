import { ethers } from "hardhat";

async function main(swiftAddr: string, random: string) {
	const Swift = await ethers.getContractFactory("MayanSwift");
	const swift = await Swift.attach(swiftAddr);

	const HashZero = ethers.constants.HashZero;
	const [owner] = await ethers.getSigners();
	console.log({ inputRandom: random });

	// cancelOrder(bytes32 trader, uint16 srcChainId, bytes32 tokenIn, uint64 amountIn, bytes32 tokenOut, uint64 minAmountOut, uint64 gasDrop, bytes32 referrerAddr, bytes32 random)
	const tx = await swift.cancelOrder(addressToBytes32(owner.address), 5, HashZero, 736, HashZero, 425, 0, HashZero, random);
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