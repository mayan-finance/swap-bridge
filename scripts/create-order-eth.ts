import { ethers } from "hardhat";

async function main(swiftAddr: string, destAuth: string) {
	const Swift = await ethers.getContractFactory("MayanSwift");
	const swift = await Swift.attach(swiftAddr);

	const keypair = ethers.Wallet.createRandom();
	const random = ethers.utils.keccak256(keypair.publicKey);
	console.log({ random });
	// function createOrderWithEth(bytes32 tokenOut, uint64 minAmountOut, uint64 gasDrop, bytes32 dstAddr, uint8 dstChainId, bytes32 referrerAddr, bytes32 nonce, bytes32 dstAuthority)
	const [owner] = await ethers.getSigners();
	const tx = await swift.createOrderWithEth(HashZero, 425, 0, addressToBytes32(owner.address), 4, HashZero, random, addressToBytes32(destAuth), { value: 7369000000000 });
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