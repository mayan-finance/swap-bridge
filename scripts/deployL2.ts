import { ethers } from "hardhat";

async function main(tokenBridge: string, weth: string) {
	const L2Swap = await ethers.getContractFactory("L2Swap");
	const l2Swap = await L2Swap.deploy(tokenBridge, weth);

	const deployed = await l2Swap.deployed();

	console.log(`Deployed L2Swap at ${deployed.address} with TokenBridge ${tokenBridge}`);
}

if (!process.env.TOKEN_BRIDGE) {
	console.log('variable TOKEN_BRIDGE is required');
	process.exit(1);
}

if (!process.env.WETH) {
	console.log('variable WETH is required');
	process.exit(1);
}


main(process.env.TOKEN_BRIDGE, process.env.WETH).catch((error) => {
	console.error(error);
	process.exitCode = 1;
});