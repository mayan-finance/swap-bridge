import { ethers } from "hardhat";
// @ts-ignore
import { base58_to_binary } from "base58-js";
import { PublicKey } from "@solana/web3.js";

async function main(wormholeAddr: string, tokenBridgeAddr: string) {
	const tokenBridge = await ethers.getContractAt("ITokenBridge", tokenBridgeAddr);
	const finality = await tokenBridge.finality();

	const MayanSwift = await ethers.getContractFactory("MayanSwift");
	// constructor(address _wormhole, address _feeCollector, uint16 _auctionChainId, bytes32 _auctionAddr, bytes32 _solanaEmitter, uint8 _consistencyLevel) {
	const mayanSwift = await MayanSwift.deploy(wormholeAddr, '0xeE1A58EafE1977A3D2ae59E2897Bb815054f6D58', 1, getEmitterPda('HgZHDPTnyCEhkxE5gx5GUrfYf3WU4ecp3Ky6i8YdtWFn'), getEmitterPda('7oJsHfUYjRNomVEM9uZtMWoiSJEPqrbHTejbpg1U23oS'), finality);

	const deployed = await mayanSwift.deployed();

	console.log(`Deployed MayanSwap at ${deployed.address} with Wormhole ${wormholeAddr}`);
}

function getEmitterPda(programAddr: string) {
	const [emitterSwift] = PublicKey.findProgramAddressSync([
		Buffer.from('emitter'),
	], new PublicKey(programAddr));
	return '0x' + Buffer.from(emitterSwift.toBytes()).toString('hex');
}

if (!process.env.WORMHOLE) {
	console.log('variable WORMHOLE is required');
	process.exit(1);
}

if (!process.env.TOKEN_BRIDGE) {
	console.log('variable TOKEN_BRIDGE is required');
	process.exit(1);
}

main(process.env.WORMHOLE, process.env.TOKEN_BRIDGE).catch((error) => {
	console.error(error);
	process.exitCode = 1;
});