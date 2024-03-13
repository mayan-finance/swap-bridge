import { ethers } from "hardhat";
// @ts-ignore
import { base58_to_binary } from "base58-js";

async function main(swiftAddr: string, destAuth: string) {
	const Swift = await ethers.getContractFactory("MayanSwift");
	const swift = await Swift.attach(swiftAddr);

	const keypair = ethers.Wallet.createRandom();
	const random = ethers.utils.keccak256(keypair.publicKey);
	console.log({ random });
	const [owner] = await ethers.getSigners();

	let destEmitter;
	if (!destAuth) {
		destEmitter = HashZero;
	} else {
		destEmitter = ethToBytes32(destAuth);
	}

	// function createOrderWithEth(bytes32 tokenOut, uint64 minAmountOut, uint64 gasDrop, bytes32 destAddr, uint8 destChainId, Criteria criteria, bytes32 random, bytes32 destEmitter)
	/*
	struct OrderParams {
		bytes32 tokenOut;
		uint64 minAmountOut;
		uint64 gasDrop;
		bytes32 destAddr;
		uint16 destChainId;
		bytes32 referrerAddr;
		uint8 referrerBps;
		uint8 auctionMode;
		bytes32 random;
		bytes32 destEmitter;
	} */
	const params = {
		tokenOut: base58ToBytes32('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'),
		minAmountOut: 2_000_000,
		gasDrop: 0,
		destAddr: base58ToBytes32('35V85aqyssnda35TYsjgd45vTVuK8swuzsht59LNNuDU'),
		destChainId: 1,
		referrerAddr: base58ToBytes32("3f6rtWrGw6Vp3RLUw5hVfe6sG5ePzThpFB7Vi8LL54mD"),
		referrerBps: 3,
		auctionMode: 2,
		random,
		destEmitter
	}

	const tx = await swift.createOrderWithEth(params, { value: "1500000000000000" });
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
	return '0x' + Buffer.from(base58_to_binary(address)).toString('hex');
}

main(process.env.SWIFT_ADDR, process.env.DEST_AUTH).catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
const HashZero = ethers.constants.HashZero;