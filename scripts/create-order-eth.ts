import { ethers } from "hardhat";
// @ts-ignore
import { base58_to_binary } from "base58-js";
import { PublicKey } from "@solana/web3.js";

async function main(swiftAddr: string, destAuth: string) {
	const Swift = await ethers.getContractFactory("MayanSwift");
	const swift = await Swift.attach(swiftAddr);

	const keypair = ethers.Wallet.createRandom();
	const random = ethers.utils.keccak256(keypair.publicKey);
	console.log({ random });
	const [owner] = await ethers.getSigners();

	let destAuthority;
	if (!destAuth) {
		destAuthority = HashZero;
	} else {
		destAuthority = ethToBytes32(destAuth);
	}
	const tokenOut = await base58ToBytes32('G7ZhadccuZVi8r7u4FjEneJxY1G9fQPG882bRmkYs3ay');
	// function createOrderWithEth(bytes32 tokenOut, uint64 minAmountOut, uint64 gasDrop, bytes32 destAddr, uint8 destChainId, bytes32 referrerAddr, bytes32 random, bytes32 destEmitter)
	const tx = await swift.createOrderWithEth(base58ToBytes32('B5JAT9cFiwRmDfUmue2GyX2tQ6dLaL7KUr2g2PjxfDxA'), 1, 0, base58ToBytes32('35V85aqyssnda35TYsjgd45vTVuK8swuzsht59LNNuDU'), 1, base58ToBytes32("3f6rtWrGw6Vp3RLUw5hVfe6sG5ePzThpFB7Vi8LL54mD"), random, destAuthority, { value: 2059000000000 });
	const receipt = await tx.wait();
	console.log({ receipt });
}

function ethToBytes32(address: string) {
	if (!/^0x[0-9a-fA-F]{40}$/.test(address)) {
		throw new Error('Invalid Ethereum address');
	}
	return '0x' + '000000000000000000000000' + address.substring(2);
}

function base58ToBytes32(address: string) {
	return '0x' + Buffer.from(new PublicKey(address).toBytes()).toString('hex');
}

main(process.env.SWIFT_ADDR, process.env.DEST_AUTH).catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
const HashZero = ethers.constants.HashZero;