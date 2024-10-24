import { ethers } from "hardhat";
import { PublicKey } from "@solana/web3.js";

async function main(cctpAddr: string, wormholeAddr: string, tokenBridgeAddr: string, feeManagerAddr: string) {
	const [operator] = await ethers.getSigners();
	const MayanCircle = await ethers.getContractFactory("MayanCircle");

	const tokenBridge = await ethers.getContractAt("ITokenBridge", tokenBridgeAddr);
	const finality = await tokenBridge.finality();

        /*
    	address _cctpTokenMessenger,
		address _wormhole,
		address _feeManager,
		uint16 _auctionChainId,
		bytes32 _auctionAddr,
		bytes32 _solanaEmitter,
		uint8 _consistencyLevel
    */
    const auctionAddr = getEmitterPda('7Ki28FBDKHoRwYXfUt4Cx8LcaQhGo27mLvNM9yx97kA');
	console.log(`Auction Address: ${auctionAddr}`);
	const solanaEmitter = getEmitterPda('V5KsUK1NNpZshF99PQr9QxRCcgAQ3YoWtDiLn9thj7V');
	console.log(`Solana Emitter: ${solanaEmitter}`);
    const mctp = await MayanCircle.deploy(cctpAddr, wormholeAddr, feeManagerAddr, 1, auctionAddr, solanaEmitter, finality);
    const deployed = await mctp.deployed();

	console.log(`Deployed MayanSwap at ${deployed.address}`);
}

function getEmitterPda(programAddr: string) {
	const [pda] = PublicKey.findProgramAddressSync([
		Buffer.from('emitter'),
	], new PublicKey(programAddr));
	return '0x' + Buffer.from(pda.toBytes()).toString('hex');
}

if (!process.env.CCTP) {
	console.log('variable CCTP is required');
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

if (!process.env.FEE_MANAGER) {
	console.log('variable FEE_MANAGER is required');
	process.exit(1);
}

main(process.env.CCTP, process.env.WORMHOLE, process.env.TOKEN_BRIDGE, process.env.FEE_MANAGER).catch((error) => {
	console.error(error);
	process.exitCode = 1;
});