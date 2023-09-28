import { ethers } from "hardhat";

async function main(wormholeAddr: string, tokenBridgeAddr: string) {
	const tokenBridge = await ethers.getContractAt("ITokenBridge", tokenBridgeAddr);
	const finality = await tokenBridge.finality();

	const MayanSwift = await ethers.getContractFactory("MayanSwift");

	const mayanSwift = await MayanSwift.deploy(wormholeAddr, '0xeE1A58EafE1977A3D2ae59E2897Bb815054f6D58', 1, '0x09e0aaee6e67322c1aef6d40af84c78278da8cfd0ca27fbdb4078cd3d02cd79b', '0x574d150adeb6b99d918e0b8b19cc89c6cd27afb43b158186d590fb879d1f9252', finality);

	const deployed = await mayanSwift.deployed();

	console.log(`Deployed MayanSwap at ${deployed.address} with Wormhole ${wormholeAddr}`);
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