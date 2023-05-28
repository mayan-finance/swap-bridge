import { ethers } from "hardhat";

async function main(tokenBridgeAddr: string) {
	const tokenBridge = await ethers.getContractAt("ITokenBridge", tokenBridgeAddr);

	const MayanSwap = await ethers.getContractFactory("MayanSwap");

	const weth = await tokenBridge.WETH();
	const mayanSwap = await MayanSwap.deploy(tokenBridgeAddr, weth);

	const deployed = await mayanSwap.deployed();

	console.log(`Deployed MayanSwap at ${deployed.address} with TokenBridge ${tokenBridgeAddr} and WETH ${weth}`);
}

if (!process.env.TOKEN_BRIDGE) {
	console.log('variable TOKEN_BRIDGE is required');
	process.exit(1);
}

main(process.env.TOKEN_BRIDGE).catch((error) => {
	console.error(error);
	process.exitCode = 1;
});