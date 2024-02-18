import { ethers } from "hardhat";
// @ts-ignore
import { base58_to_binary } from "base58-js";
import { PublicKey } from "@solana/web3.js";

async function main(tokenMsgAddr: string, wormholeAddr: string, tokenBridgeAddr: string) {
	const tokenBridge = await ethers.getContractAt("ITokenBridge", tokenBridgeAddr);
	const finality = await tokenBridge.finality();

	const MayanCircle = await ethers.getContractFactory("MayanCircle");
	// constructor(address _wormhole, address _feeCollector, uint16 _auctionChainId, bytes32 _auctionAddr, bytes32 _solanaEmitter, uint8 _consistencyLevel) {
	const mayanCircle = await MayanCircle.deploy(tokenMsgAddr, wormholeAddr, getEmitterPda('FoypZ11ARJwZBC8i8H8p6L7BZN9jmssZ3n1JXub68NzT'), finality);

	const deployed = await mayanCircle.deployed();

	console.log(`Deployed MayanCircle at ${deployed.address} with Wormhole ${wormholeAddr}`);
}

function getEmitterPda(programAddr: string) {
	const [emitterSwift] = PublicKey.findProgramAddressSync([
		Buffer.from('emitter'),
	], new PublicKey(programAddr));
	return '0x' + emitterSwift.toBuffer().toString('hex');
}

if (!process.env.TOKEN_MSG) {
	console.log('variable TOKEN_MESSENGER is required');
	process.exit(1);
}

if (!process.env.WORMHOLE) {
	console.log('variable WORMHOLE is required');
	process.exit(1);
}

if (!process.env.TOKEN_BRIDGE) {
	console.log('variable TOKEN_BRIDGE is required');
	process.exit(1);
}

main(process.env.TOKEN_MSG, process.env.WORMHOLE, process.env.TOKEN_BRIDGE).catch((error) => {
	console.error(error);
	process.exitCode = 1;
});