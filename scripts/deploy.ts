import { ethers } from "hardhat";

async function main(tokenBridge: string) {
	const MayanSwap = await ethers.getContractFactory("MayanSwap");
	const mayanSwap = await MayanSwap.deploy(tokenBridge);

	const deployed = await mayanSwap.deployed();

	console.log(`Deployed MayanSwap at ${deployed.address} with TokenBridge ${tokenBridge}`);
}

if (!process.env.TOKEN_BRIDGE) {
	console.log('variable TOKEN_BRIDGE is required');
	process.exit(1);
}

main(process.env.TOKEN_BRIDGE).catch((error) => {
	console.error(error);
	process.exitCode = 1;
});